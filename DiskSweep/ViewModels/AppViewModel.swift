import Foundation
import Observation

enum AnalysisActivity: String, Sendable {
    case downloads
    case largeFiles
    case folders
    case duplicates
}

@MainActor
@Observable
final class AppViewModel {
    var selection: SidebarDestination? = .overview
    var diskStatistics: DiskStatistics = .unavailable
    var categories: [CleanupCategory] = []
    var selectedCleanupItemIDs: Set<UUID> = []
    var cleanupScanProgress: ScanProgress?
    var lastScanDate: Date?
    var lastScanWasCancelled = false
    var isCleaning = false
    var showsCleanupReview = false
    var cleanupResult: CleanupResult?

    var downloadsAnalysis: DownloadsAnalysis?
    var selectedDownloadFileIDs: Set<UUID> = []
    var largeFiles: [FileItem] = []
    var largeFileThreshold: Int64 = LargeFileAnalyzer.defaultThreshold
    var selectedLargeFileID: UUID?
    var largeFolderRoot: DirectoryNode?
    var duplicateGroups: [DuplicateGroup] = []
    var selectedDuplicateFileIDs: Set<UUID> = []
    var analysisActivity: AnalysisActivity?
    var analysisProgress: ScanProgress?

    var errorMessage: String?

    let settings: SettingsStore
    let history: CleanupHistoryStore
    let permissions: PermissionManager

    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private let providers: [any CleanupProvider]
    @ObservationIgnored private let diskService: DiskService
    @ObservationIgnored private let cleanupEngine: CleanupEngine
    @ObservationIgnored private let finderService: FinderService
    @ObservationIgnored private var cleanupScanTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        settings: SettingsStore = SettingsStore(),
        history: CleanupHistoryStore = CleanupHistoryStore(),
        permissions: PermissionManager = PermissionManager(),
        diskService: DiskService = DiskService(),
        cleanupEngine: CleanupEngine = CleanupEngine(),
        finderService: FinderService = .shared
    ) {
        let home = homeDirectory.standardizedFileURL
        self.homeDirectory = home
        self.settings = settings
        self.history = history
        self.permissions = permissions
        self.diskService = diskService
        self.cleanupEngine = cleanupEngine
        self.finderService = finderService
        providers = StandardCleanupProviders.all(homeDirectory: home)
    }

    var isCleanupScanning: Bool { cleanupScanTask != nil }

    var preferredUserFileDisposition: CleanupDisposition {
        settings.general.preferMoveToTrash ? .trash : .permanent
    }

    var selectedCleanupItems: [CleanupItem] {
        let categoryItems = categories
            .flatMap(\.items)
            .filter { selectedCleanupItemIDs.contains($0.id) }

        guard let downloadsAnalysis,
              let provider = providers.first(where: { $0.id == DownloadsProvider.providerID })
                as? DownloadsProvider else {
            return categoryItems
        }

        let downloadItems = downloadsAnalysis.allFiles
            .filter { selectedDownloadFileIDs.contains($0.id) }
            .compactMap(provider.cleanupItem(for:))
        return categoryItems + downloadItems
    }

    var selectedCleanupSize: Int64 {
        selectedCleanupItems.reduce(0) { partial, item in
            addingClamped(partial, item.size)
        }
    }

    func startup() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refreshDiskStatistics()
        if settings.general.automaticallyScanOnLaunch {
            startCleanupScan()
        }
    }

    func startCleanupScan() {
        guard cleanupScanTask == nil, !isCleaning else { return }
        cancelAnalysis()
        lastScanWasCancelled = false
        cleanupScanProgress = ScanProgress(
            phase: .preparing,
            location: nil,
            currentPath: homeDirectory.path,
            filesAnalyzed: 0,
            bytesFound: 0,
            completedProviders: 0,
            totalProviders: 0
        )

        cleanupScanTask = Task { [weak self] in
            guard let self else { return }
            let enabledLocations = settings.effectiveScanLocations
            let scanProviders = providers.filter {
                enabledLocations.contains($0.location) && $0.location != .downloads
            }
            cleanupScanProgress?.totalProviders = scanProviders.count
            categories = []
            selectedCleanupItemIDs = []

            var completed = 0
            var accumulatedFiles = 0
            var accumulatedBytes: Int64 = 0

            for provider in scanProviders {
                if Task.isCancelled { break }
                let priorFiles = accumulatedFiles
                let priorBytes = accumulatedBytes
                let priorCompleted = completed
                let totalProviders = scanProviders.count

                let result = await provider.scan(context: makeScanContext()) { [weak self] update in
                    await self?.applyCleanupProgress(
                        update,
                        priorFiles: priorFiles,
                        priorBytes: priorBytes,
                        completedProviders: priorCompleted,
                        totalProviders: totalProviders
                    )
                }

                if Task.isCancelled { break }
                let filteredItems = removeProviderOverlaps(
                    result.items,
                    ownerProviderID: provider.id
                )
                let category = CleanupCategory(
                    location: result.location,
                    items: filteredItems,
                    issues: result.issues,
                    scannedAt: Date()
                )
                categories.append(category)
                categories.sort { locationOrder($0.location) < locationOrder($1.location) }

                for item in filteredItems where item.isSelectedByDefault && item.isDeletable {
                    selectedCleanupItemIDs.insert(item.id)
                }
                accumulatedFiles += category.fileCount
                accumulatedBytes = addingClamped(accumulatedBytes, category.totalSize)
                completed += 1
                cleanupScanProgress = ScanProgress(
                    phase: .enumerating,
                    location: provider.location,
                    currentPath: provider.allowedRoots.first?.path ?? "",
                    filesAnalyzed: accumulatedFiles,
                    bytesFound: accumulatedBytes,
                    completedProviders: completed,
                    totalProviders: scanProviders.count
                )
                await refreshDiskStatistics()
            }

            if !Task.isCancelled {
                lastScanDate = Date()
                lastScanWasCancelled = false
            } else {
                lastScanWasCancelled = true
            }
            cleanupScanProgress = nil
            cleanupScanTask = nil
            await refreshDiskStatistics()
        }
    }

    func cancelCleanupScan() {
        cleanupScanTask?.cancel()
        lastScanWasCancelled = true
        cleanupScanTask = nil
        cleanupScanProgress = nil
    }

    func requestCleanupReview() {
        let items = selectedCleanupItems
        guard !items.isEmpty else { return }
        let containsSensitiveItems = items.contains { $0.risk != .safe || $0.location == .trash }

        if settings.general.confirmBeforeCleanup || containsSensitiveItems {
            showsCleanupReview = true
        } else {
            performCleanup(disposition: nil)
        }
    }

    func performCleanup(disposition: CleanupDisposition?) {
        guard !isCleaning else { return }
        let items = selectedCleanupItems
        guard !items.isEmpty else { return }

        isCleaning = true
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            var preferredDisposition = disposition
            if preferredDisposition == nil,
               items.contains(where: { $0.risk == .userFiles }) {
                preferredDisposition = preferredUserFileDisposition
            }

            let result = await cleanupEngine.clean(
                items,
                providers: providers,
                disposition: preferredDisposition,
                exclusions: settings.excludedURLs
            )
            isCleaning = false
            showsCleanupReview = false
            cleanupResult = result
            selectedCleanupItemIDs.removeAll()
            selectedDownloadFileIDs.removeAll()
            cleanupTask = nil

            if settings.privacy.keepLocalCleanupHistory, !result.cleanedItems.isEmpty {
                do {
                    try history.record(result)
                } catch {
                    errorMessage = "Cleanup finished, but its history could not be saved: \(error.localizedDescription)"
                }
            }
            await refreshDiskStatistics()
        }
    }

    func dismissCleanupResult() {
        cleanupResult = nil
        downloadsAnalysis = nil
        startCleanupScan()
    }

    func startDownloadsAnalysis() {
        beginAnalysis(.downloads) { [weak self] context in
            guard let self else { return }
            let result = try await DownloadsAnalyzer().scan(
                context: context,
                progress: analysisProgressHandler()
            )
            downloadsAnalysis = result
            selectedDownloadFileIDs = result.defaultSelectedFileIDs
        }
    }

    func startLargeFileAnalysis() {
        let threshold = largeFileThreshold
        beginAnalysis(.largeFiles) { [weak self] context in
            guard let self else { return }
            let result = try await LargeFileAnalyzer().scan(
                threshold: threshold,
                context: context,
                progress: analysisProgressHandler()
            )
            largeFiles = result.files
            selectedLargeFileID = nil
        }
    }

    func startFolderAnalysis() {
        beginAnalysis(.folders) { [weak self] context in
            guard let self else { return }
            let result = try await LargeFolderAnalyzer().scan(
                minimumRetainedFolderSize: 5 * 1_024 * 1_024,
                context: context,
                progress: analysisProgressHandler()
            )
            largeFolderRoot = result.root
        }
    }

    func startDuplicateAnalysis() {
        beginAnalysis(.duplicates) { [weak self] context in
            guard let self else { return }
            let result = try await DuplicateAnalyzer().scan(
                minimumFileSize: 1 * 1_024 * 1_024,
                context: context,
                progress: analysisProgressHandler()
            )
            duplicateGroups = result.groups
            selectedDuplicateFileIDs = result.groups.reduce(into: Set<UUID>()) { selection, group in
                selection.formUnion(DuplicateSelection.defaultSelectedFileIDs(in: group))
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisActivity = nil
        analysisProgress = nil
    }

    func isAnalyzing(_ activity: AnalysisActivity) -> Bool {
        analysisActivity == activity
    }

    func revealInFinder(_ url: URL) {
        finderService.revealInFinder(url)
    }

    func quickLook(_ url: URL) {
        _ = finderService.quickLook(url)
    }

    func quickLookSelectedFile() {
        guard let url = commandFileURL else { return }
        quickLook(url)
    }

    func revealSelectedFile() {
        guard let url = commandFileURL else { return }
        revealInFinder(url)
    }

    func clearError() { errorMessage = nil }

    private func beginAnalysis(
        _ activity: AnalysisActivity,
        operation: @escaping @MainActor (ScanContext) async throws -> Void
    ) {
        cancelAnalysis()
        analysisActivity = activity
        analysisProgress = ScanProgress(
            phase: .preparing,
            location: nil,
            currentPath: homeDirectory.path,
            filesAnalyzed: 0,
            bytesFound: 0,
            completedProviders: 0,
            totalProviders: 0
        )

        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(makeScanContext())
            } catch is CancellationError {
                // Cancellation is an expected user action.
            } catch {
                errorMessage = error.localizedDescription
            }
            analysisTask = nil
            analysisActivity = nil
            analysisProgress = nil
        }
    }

    private func analysisProgressHandler() -> ScanProgressHandler {
        { [weak self] update in
            await MainActor.run {
                self?.analysisProgress = update
            }
        }
    }

    private func makeScanContext() -> ScanContext {
        var names: Set<String> = []
        if settings.exclusions.excludeVersionControlMetadata {
            names.formUnion([".git", ".svn"])
        }

        return ScanContext(
            homeDirectory: homeDirectory,
            exclusions: settings.excludedURLs,
            showHiddenFiles: settings.general.showHiddenFiles,
            excludedDirectoryNames: names,
            excludeNodeModulesFromDeepScans: settings.exclusions.excludeNodeModulesFromDeepScans,
            excludeCloudPlaceholders: settings.exclusions.excludeCloudPlaceholders,
            excludePhotoLibraries: settings.exclusions.excludePhotoLibraries,
            excludeTimeMachineBackups: settings.exclusions.excludeTimeMachineBackups,
            excludePackageContents: settings.exclusions.excludePackageContents
        )
    }

    private func applyCleanupProgress(
        _ update: ScanProgress,
        priorFiles: Int,
        priorBytes: Int64,
        completedProviders: Int,
        totalProviders: Int
    ) {
        guard cleanupScanTask != nil else { return }
        cleanupScanProgress = ScanProgress(
            phase: update.phase,
            location: update.location,
            currentPath: update.currentPath,
            filesAnalyzed: priorFiles + update.filesAnalyzed,
            bytesFound: addingClamped(priorBytes, update.bytesFound),
            completedProviders: completedProviders,
            totalProviders: totalProviders
        )
    }

    private func refreshDiskStatistics() async {
        let reclaimable = categories.reduce(Int64(0)) {
            addingClamped($0, $1.totalSize)
        }
        do {
            diskStatistics = try await diskService.statistics(reclaimable: reclaimable)
        } catch {
            if diskStatistics.capacity == 0 {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeProviderOverlaps(
        _ items: [CleanupItem],
        ownerProviderID: String
    ) -> [CleanupItem] {
        let otherRoots = providers
            .filter { $0.id != ownerProviderID }
            .flatMap(\.allowedRoots)
            .map(\.standardizedFileURL)

        return items.filter { item in
            let candidate = item.url.standardizedFileURL
            return !otherRoots.contains { root in
                candidate == root || isStrictAncestor(candidate, of: root)
            }
        }
    }

    private func isStrictAncestor(_ candidate: URL, of descendant: URL) -> Bool {
        let lhs = candidate.pathComponents
        let rhs = descendant.pathComponents
        guard lhs.count < rhs.count else { return false }
        return Array(rhs.prefix(lhs.count)) == lhs
    }

    private func locationOrder(_ location: CleanupLocation) -> Int {
        CleanupLocation.allCases.firstIndex(of: location) ?? Int.max
    }

    private func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(max(0, rhs))
        return overflow ? Int64.max : value
    }

    private var commandFileURL: URL? {
        if let selectedLargeFileID,
           let file = largeFiles.first(where: { $0.id == selectedLargeFileID }) {
            return file.url
        }
        if let id = selectedDownloadFileIDs.first,
           let file = downloadsAnalysis?.allFiles.first(where: { $0.id == id }) {
            return file.url
        }
        if let id = selectedDuplicateFileIDs.first,
           let file = duplicateGroups.flatMap(\.files).first(where: { $0.id == id }) {
            return file.url
        }
        if let item = selectedCleanupItems.first {
            return item.url
        }
        return nil
    }
}
