import Foundation

struct TemporaryFilesProvider: CleanupProvider {
    static let providerID = "temporary-files"
    static let defaultMinimumAge: TimeInterval = 14 * 24 * 60 * 60

    let temporaryDirectory: URL
    let minimumAge: TimeInterval

    init(
        temporaryDirectory requestedDirectory: URL = FileManager.default.temporaryDirectory,
        minimumAge: TimeInterval = Self.defaultMinimumAge
    ) {
        let systemTemporaryDirectory = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let requested = requestedDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = systemTemporaryDirectory.pathComponents
        let candidateComponents = requested.pathComponents
        let isCurrentUserTemporaryDirectory = candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents

        self.temporaryDirectory = isCurrentUserTemporaryDirectory
            ? requested
            : systemTemporaryDirectory
        self.minimumAge = max(24 * 60 * 60, minimumAge)
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .temporaryFiles }
    var allowedRoots: [URL] { [temporaryDirectory] }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let cutoff = context.now.addingTimeInterval(-minimumAge)
        let scanner = FileSystemScanner()
        let options = FileSystemScanOptions(
            recursive: true,
            includeFiles: true,
            includeDirectories: false,
            includeSymbolicLinks: false,
            includeHiddenFiles: false,
            skipPackages: true,
            skipCloudPlaceholders: true,
            collectItems: true,
            batchSize: 256,
            exclusionURLs: context.exclusions,
            excludedNames: [
                ".git", ".svn", "node_modules", ".TemporaryItems"
            ],
            excludedExtensions: [
                "photoslibrary", "photolibrary", "backupdb", "lock", "pid",
                "sock", "socket"
            ],
            modifiedBefore: cutoff
        )

        do {
            _ = try SafetyValidator(
                homeDirectory: context.homeDirectory
            ).preflightApprovedRoot(
                temporaryDirectory,
                location: location
            )
            try Task.checkCancellation()

            let result = try await scanner.scan(
                root: temporaryDirectory,
                options: options
            ) { batch in
                await progress(ScanProgress(
                    phase: .enumerating,
                    location: location,
                    currentPath: batch.currentURL.path,
                    filesAnalyzed: batch.filesAnalyzed,
                    bytesFound: batch.bytesAnalyzed,
                    completedProviders: 0,
                    totalProviders: 1
                ))
            }
            // The scanner can finish immediately after its final progress callback.
            // Re-check the parent task before doing potentially large postprocessing.
            try Task.checkCancellation()

            var snapshots: [UUID: CleanupScanSnapshot] = [:]
            var items: [CleanupItem] = []
            items.reserveCapacity(result.items.count)
            snapshots.reserveCapacity(result.items.count)

            for file in result.items {
                try Task.checkCancellation()
                guard file.kind == .file,
                      let identity = try? SafetyValidator.captureIdentity(at: file.url),
                      identity.kind == .file else {
                    continue
                }
                let snapshotModifiedAt = identity.modificationDate
                guard snapshotModifiedAt < cutoff else { continue }
                let item = CleanupItem(
                    providerID: id,
                    location: location,
                    name: file.name,
                    url: file.url,
                    size: identity.displayByteSize,
                    fileCount: 1,
                    kind: .file,
                    modifiedAt: snapshotModifiedAt,
                    risk: .reviewRecommended,
                    explanation: "A current-user temporary file that has not changed for at least \(Int(minimumAge / 86_400)) days.",
                    isSelectedByDefault: false
                )
                snapshots[item.id] = CleanupScanSnapshot(
                    identity: identity,
                    exclusionRoots: context.exclusions
                )
                items.append(item)
            }

            try Task.checkCancellation()
            items.sort { $0.size > $1.size }
            try Task.checkCancellation()
            CleanupSnapshotRegistry.shared.replace(
                providerID: id,
                snapshots: snapshots
            )

            // Do not publish a completed scan after cancellation was requested.
            try Task.checkCancellation()
            await progress(ScanProgress(
                phase: .completed,
                location: location,
                currentPath: temporaryDirectory.path,
                filesAnalyzed: items.count,
                bytesFound: items.reduce(0) { $0 + $1.size },
                completedProviders: 1,
                totalProviders: 1
            ))

            return ProviderScanResult(
                location: location,
                items: items,
                issues: result.issues
            )
        } catch is CancellationError {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            return ProviderScanResult(
                location: location,
                items: [],
                issues: [ScanIssue(
                    kind: .cancelled,
                    path: temporaryDirectory.path,
                    message: "Scanning was cancelled."
                )]
            )
        } catch {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            return ProviderScanResult(
                location: location,
                items: [],
                issues: [FileSystemScanner.issue(for: error, at: temporaryDirectory)]
            )
        }
    }
}
