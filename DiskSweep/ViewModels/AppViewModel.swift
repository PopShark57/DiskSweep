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
    /// What the open review sheet covers, and what Clean will remove.
    var pendingReviewScope: CleanupScope = .locations([])
    var cleanupResult: CleanupResult?

    var downloadsAnalysis: DownloadsAnalysis? {
        didSet { rebuildDownloadCleanupItems() }
    }
    var selectedDownloadFileIDs: Set<UUID> = []
    /// The Downloads files the Downloads screen's filters and search currently show, as
    /// reported by that screen. `nil` until it reports, which means no filter is applied.
    var downloadsVisibleFileIDs: Set<UUID>?
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

    @ObservationIgnored let homeDirectory: URL
    @ObservationIgnored private let standardProviders: [any CleanupProvider]
    @ObservationIgnored private let diskService: DiskService
    @ObservationIgnored private let cleanupEngine: any CleanupPerforming
    /// Shared by every scan context and the cleanup engine, so cleanup finds the identities
    /// the scan recorded.
    @ObservationIgnored let snapshots: CleanupSnapshotRegistry
    @ObservationIgnored private let finderService: FinderService
    @ObservationIgnored private var cleanupScanTask: Task<Void, Never>?
    /// A cancelled scan that may still be finishing its current provider. The next scan waits
    /// for it, so the two never run providers at the same time.
    @ObservationIgnored private var retiredScanTask: Task<Void, Never>?
    /// Incremented whenever a scan starts or is cancelled. A scan task only changes state
    /// while its generation is current, so a cancelled scan can't touch a newer one.
    @ObservationIgnored private var scanGeneration = 0
    /// How many providers scan at the same time. Set to 1 to scan one after another, for
    /// example on spinning or network disks.
    static let maximumConcurrentProviderScans = 3
    @ObservationIgnored private var completedProviderCount = 0
    @ObservationIgnored private var accumulatedScanFiles = 0
    @ObservationIgnored private var accumulatedScanBytes: Int64 = 0
    /// The latest progress of each provider still scanning, summed into the scan's progress.
    @ObservationIgnored private var inFlightProgress: [String: ScanProgress] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var retiredAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var analysisGeneration = 0
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    /// Cleanup items for the current Downloads analysis, keyed by file ID. Built once per
    /// analysis, so reading the selection never records new registry snapshots.
    @ObservationIgnored private var downloadCleanupItems: [UUID: CleanupItem] = [:]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        standardProviders: [any CleanupProvider]? = nil,
        settings: SettingsStore = SettingsStore(),
        history: CleanupHistoryStore = CleanupHistoryStore(),
        permissions: PermissionManager = PermissionManager(),
        diskService: DiskService = DiskService(),
        snapshots: CleanupSnapshotRegistry = CleanupSnapshotRegistry(),
        cleanupEngine: (any CleanupPerforming)? = nil,
        finderService: FinderService = .shared
    ) {
        let home = homeDirectory.standardizedFileURL
        self.homeDirectory = home
        self.settings = settings
        self.history = history
        self.permissions = permissions
        self.diskService = diskService
        self.snapshots = snapshots
        // An injected engine must be built with the same registry.
        self.cleanupEngine = cleanupEngine ?? CleanupEngine(
            diskService: diskService,
            snapshots: snapshots
        )
        self.finderService = finderService
        self.standardProviders = standardProviders ?? StandardCleanupProviders.all(
            homeDirectory: home,
            temporaryDirectory: temporaryDirectory
        )
    }

    /// The fixed cleanup locations plus the project folders currently chosen in Settings.
    /// Cleanup authorizations are built from this at cleanup time, so removing a project
    /// folder also revokes cleanup of anything previously found inside it.
    private var providers: [any CleanupProvider] {
        standardProviders + [
            ProjectArtifactsProvider(
                projectFolders: settings.developer.projectFolders,
                minimumAge: settings.projectIdleInterval,
                homeDirectory: homeDirectory
            )
        ]
    }

    var isCleanupScanning: Bool { cleanupScanTask != nil }

    var preferredUserFileDisposition: CleanupDisposition {
        settings.general.preferMoveToTrash ? .trash : .permanent
    }

    var selectedCleanupItems: [CleanupItem] {
        let categoryItems = categories
            .flatMap(\.items)
            .filter { selectedCleanupItemIDs.contains($0.id) }

        guard let downloadsAnalysis else { return categoryItems }
        let downloadItems = downloadsAnalysis.allFiles
            .filter { selectedDownloadFileIDs.contains($0.id) }
            .compactMap { downloadCleanupItems[$0.id] }
        return categoryItems + downloadItems
    }

    /// The selected items a review of `scope` would clean.
    func cleanupItems(in scope: CleanupScope) -> [CleanupItem] {
        switch scope {
        case let .locations(locations):
            return categories
                .filter { locations.contains($0.location) }
                .flatMap(\.items)
                .filter { selectedCleanupItemIDs.contains($0.id) }
        case .downloads:
            guard let downloadsAnalysis else { return [] }
            // Selected files that filters or search hide are never reviewed or cleaned.
            let reviewable = downloadsVisibleFileIDs.map { selectedDownloadFileIDs.intersection($0) }
                ?? selectedDownloadFileIDs
            return downloadsAnalysis.allFiles
                .filter { reviewable.contains($0.id) }
                .compactMap { downloadCleanupItems[$0.id] }
        }
    }

    /// Selected Downloads files that the current filters or search hide.
    var hiddenSelectedDownloadCount: Int {
        guard let downloadsVisibleFileIDs else { return 0 }
        return selectedDownloadFileIDs.subtracting(downloadsVisibleFileIDs).count
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
        scanGeneration += 1
        let generation = scanGeneration
        let previousScan = retiredScanTask
        retiredScanTask = nil
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
            // A cancelled scan may still be inside a provider. Let it finish first, so its
            // cancellation cleanup can't erase snapshots this scan records.
            await previousScan?.value
            guard let self, generation == scanGeneration else { return }

            let enabledLocations = settings.effectiveScanLocations
            let allProviders = providers
            let scanProviders = allProviders.filter {
                enabledLocations.contains($0.location) && $0.location != .downloads
            }
            // Several providers list folders to find their roots. Do that once per scan, off
            // the main actor. The plan only filters what's displayed; cleanup re-derives roots
            // inside the engine, so a project folder removed in the meantime is still refused.
            let plan = await Self.makeScanPlan(for: allProviders)
            guard generation == scanGeneration else { return }
            cleanupScanProgress?.totalProviders = scanProviders.count
            categories = []
            selectedCleanupItemIDs = []

            completedProviderCount = 0
            accumulatedScanFiles = 0
            accumulatedScanBytes = 0
            inFlightProgress = [:]
            let totalProviders = scanProviders.count
            let context = makeScanContext()

            // A few providers run at once; most walk separate folder trees, so this mostly
            // overlaps I/O waits. Results are inserted in category order as they finish.
            await withTaskGroup(
                of: (provider: any CleanupProvider, result: ProviderScanResult).self
            ) { group in
                var pending = scanProviders[...]

                func startNext() {
                    guard let provider = pending.popFirst() else { return }
                    let providerID = provider.id
                    let progress: ScanProgressHandler = { [weak self] update in
                        await self?.applyCleanupProgress(
                            update,
                            providerID: providerID,
                            generation: generation,
                            totalProviders: totalProviders
                        )
                    }
                    group.addTask {
                        let signpost = Log.signposter.beginInterval(
                            "Provider scan",
                            id: Log.signposter.makeSignpostID(),
                            "\(providerID, privacy: .public)"
                        )
                        let result = await provider.scan(context: context, progress: progress)
                        Log.signposter.endInterval("Provider scan", signpost)
                        return (provider, result)
                    }
                }

                for _ in 0..<Self.maximumConcurrentProviderScans { startNext() }

                for await (provider, result) in group {
                    // Every await is a point where this scan may have been cancelled or replaced.
                    guard generation == scanGeneration, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    publish(result, from: provider, plan: plan, totalProviders: totalProviders)
                    startNext()
                    await refreshDiskStatistics()
                }
            }
            guard generation == scanGeneration else { return }
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

    /// Cancels a running scan. Does nothing when no scan is running, so a completed scan is
    /// never relabeled as partial.
    func cancelCleanupScan() {
        guard let task = cleanupScanTask else { return }
        task.cancel()
        scanGeneration += 1
        retiredScanTask = task
        cleanupScanTask = nil
        cleanupScanProgress = nil
        lastScanWasCancelled = true
    }

    /// Opens the review sheet for exactly the items `scope` covers. Without confirmation and
    /// with only safe items, it cleans that same scope directly.
    func requestCleanupReview(scope: CleanupScope) {
        let items = cleanupItems(in: scope)
        guard !items.isEmpty else { return }
        pendingReviewScope = scope
        let containsSensitiveItems = items.contains { $0.risk != .safe || $0.location == .trash }

        if settings.general.confirmBeforeCleanup || containsSensitiveItems {
            showsCleanupReview = true
        } else {
            performCleanup(disposition: nil)
        }
    }

    /// Cleans the items in `pendingReviewScope`, the same items the review sheet lists.
    func performCleanup(disposition: CleanupDisposition?) {
        guard !isCleaning else { return }
        let scope = pendingReviewScope
        let items = cleanupItems(in: scope)
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
            clearSelection(in: scope)
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

    /// Clears only the selections a cleanup covered; other screens keep theirs.
    private func clearSelection(in scope: CleanupScope) {
        switch scope {
        case let .locations(locations):
            let covered = Set(
                categories.filter { locations.contains($0.location) }.flatMap(\.items).map(\.id)
            )
            selectedCleanupItemIDs.subtract(covered)
        case .downloads:
            selectedDownloadFileIDs.removeAll()
        }
    }

    func dismissCleanupResult() {
        cleanupResult = nil
        downloadsAnalysis = nil
        startCleanupScan()
    }

    func startDownloadsAnalysis() {
        beginAnalysis(.downloads) { [weak self] context, progress in
            let result = try await DownloadsAnalyzer().scan(context: context, progress: progress)
            return {
                self?.downloadsAnalysis = result
                self?.selectedDownloadFileIDs = result.defaultSelectedFileIDs
            }
        }
    }

    func startLargeFileAnalysis() {
        let threshold = largeFileThreshold
        beginAnalysis(.largeFiles) { [weak self] context, progress in
            let result = try await LargeFileAnalyzer().scan(
                threshold: threshold,
                context: context,
                progress: progress
            )
            return {
                self?.largeFiles = result.files
                self?.selectedLargeFileID = nil
            }
        }
    }

    func startFolderAnalysis() {
        beginAnalysis(.folders) { [weak self] context, progress in
            let result = try await LargeFolderAnalyzer().scan(
                minimumRetainedFolderSize: 5 * 1_024 * 1_024,
                context: context,
                progress: progress
            )
            return { self?.largeFolderRoot = result.root }
        }
    }

    func startDuplicateAnalysis() {
        beginAnalysis(.duplicates) { [weak self] context, progress in
            let result = try await DuplicateAnalyzer().scan(
                minimumFileSize: 1 * 1_024 * 1_024,
                context: context,
                progress: progress
            )
            return {
                self?.duplicateGroups = result.groups
                self?.selectedDuplicateFileIDs = result.groups.reduce(into: Set<UUID>()) { selection, group in
                    selection.formUnion(DuplicateSelection.defaultSelectedFileIDs(in: group))
                }
            }
        }
    }

    func cancelAnalysis() {
        analysisGeneration += 1
        if let task = analysisTask {
            task.cancel()
            retiredAnalysisTask = task
        }
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

    // MARK: - Test support

    /// Waits for the current cleanup scan to finish. Used by tests.
    func waitForScan() async {
        await retiredScanTask?.value
        await cleanupScanTask?.value
    }

    /// Waits for the current analysis, and any cancelled one, to finish. Used by tests.
    func waitForAnalysis() async {
        await retiredAnalysisTask?.value
        await analysisTask?.value
    }

    /// Waits for the current cleanup to finish. Used by tests.
    func waitForCleanup() async {
        await cleanupTask?.value
    }

    /// Runs one analysis at a time. `operation` returns a closure that publishes its results;
    /// it only runs if this analysis is still the current one, so a cancelled or replaced
    /// analysis never overwrites newer results.
    func beginAnalysis(
        _ activity: AnalysisActivity,
        operation: @escaping @MainActor (ScanContext, @escaping ScanProgressHandler) async throws
            -> (@MainActor () -> Void)
    ) {
        cancelAnalysis()
        let generation = analysisGeneration
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

        let progress = analysisProgressHandler(generation: generation)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            let signpost = Log.signposter.beginInterval(
                "Analysis",
                id: Log.signposter.makeSignpostID(),
                "\(activity.rawValue, privacy: .public)"
            )
            defer { Log.signposter.endInterval("Analysis", signpost) }
            do {
                let publish = try await operation(makeScanContext(), progress)
                guard generation == analysisGeneration else { return }
                publish()
            } catch is CancellationError {
                // Cancellation is an expected user action.
            } catch {
                guard generation == analysisGeneration else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == analysisGeneration else { return }
            analysisTask = nil
            analysisActivity = nil
            analysisProgress = nil
        }
    }

    private func analysisProgressHandler(generation: Int) -> ScanProgressHandler {
        { [weak self] update in
            await MainActor.run {
                guard let self, generation == self.analysisGeneration else { return }
                self.analysisProgress = update
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
            excludePackageContents: settings.exclusions.excludePackageContents,
            snapshots: snapshots
        )
    }

    private func applyCleanupProgress(
        _ update: ScanProgress,
        providerID: String,
        generation: Int,
        totalProviders: Int
    ) {
        guard generation == scanGeneration, cleanupScanTask != nil else { return }
        inFlightProgress[providerID] = update
        cleanupScanProgress = ScanProgress(
            phase: update.phase,
            location: update.location,
            currentPath: update.currentPath,
            filesAnalyzed: accumulatedScanFiles
                + inFlightProgress.values.reduce(0) { $0 + $1.filesAnalyzed },
            bytesFound: inFlightProgress.values.reduce(accumulatedScanBytes) {
                addingClamped($0, $1.bytesFound)
            },
            completedProviders: completedProviderCount,
            totalProviders: totalProviders
        )
    }

    /// Adds one provider's finished result to the scan, in category order.
    private func publish(
        _ result: ProviderScanResult,
        from provider: any CleanupProvider,
        plan: ScanPlan,
        totalProviders: Int
    ) {
        inFlightProgress[provider.id] = nil
        let filteredItems = Self.removeProviderOverlaps(
            result.items,
            ownerProviderID: provider.id,
            plan: plan
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
        accumulatedScanFiles += category.fileCount
        accumulatedScanBytes = addingClamped(accumulatedScanBytes, category.totalSize)
        completedProviderCount += 1
        cleanupScanProgress = ScanProgress(
            phase: .enumerating,
            location: provider.location,
            currentPath: plan.roots(of: provider.id).first?.path ?? "",
            filesAnalyzed: accumulatedScanFiles
                + inFlightProgress.values.reduce(0) { $0 + $1.filesAnalyzed },
            bytesFound: inFlightProgress.values.reduce(accumulatedScanBytes) {
                addingClamped($0, $1.bytesFound)
            },
            completedProviders: completedProviderCount,
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

    /// Each provider's roots, evaluated once per scan.
    struct ScanPlan: Sendable {
        let rootsByProvider: [String: [URL]]

        func roots(of providerID: String) -> [URL] {
            rootsByProvider[providerID] ?? []
        }
    }

    nonisolated static func makeScanPlan(for providers: [any CleanupProvider]) async -> ScanPlan {
        await Task.detached(priority: .utility) {
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            var roots: [String: [URL]] = [:]
            for provider in providers {
                roots[provider.id, default: []]
                    .append(contentsOf: provider.allowedRoots.map(\.standardizedFileURL))
            }
            return ScanPlan(rootsByProvider: roots)
        }.value
    }

    /// Drops items that are another provider's root, or that contain one, so the same data is
    /// never listed by two categories.
    static func removeProviderOverlaps(
        _ items: [CleanupItem],
        ownerProviderID: String,
        plan: ScanPlan
    ) -> [CleanupItem] {
        let otherRoots = plan.rootsByProvider
            .filter { $0.key != ownerProviderID }
            .flatMap(\.value)

        return items.filter { item in
            let candidate = item.url.standardizedFileURL
            return !otherRoots.contains { root in
                candidate == root || root.isStrictDescendant(of: candidate)
            }
        }
    }

    private func rebuildDownloadCleanupItems() {
        snapshots.replace(providerID: DownloadsProvider.providerID, snapshots: [:])
        downloadCleanupItems = [:]
        downloadsVisibleFileIDs = nil
        guard let downloadsAnalysis,
              let provider = providers.first(where: { $0.id == DownloadsProvider.providerID })
                as? DownloadsProvider else {
            return
        }
        for file in downloadsAnalysis.allFiles {
            if let item = provider.cleanupItem(for: file, registry: snapshots) {
                downloadCleanupItems[file.id] = item
            }
        }
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
