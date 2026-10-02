import Foundation

struct LogProvider: CleanupProvider {
    static let providerID = "user-logs"
    static let defaultMinimumAge: TimeInterval = 30 * 24 * 60 * 60

    let homeDirectory: URL
    let minimumAge: TimeInterval

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        minimumAge: TimeInterval = Self.defaultMinimumAge
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.minimumAge = max(24 * 60 * 60, minimumAge)
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .userLogs }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true)]
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let cutoff = context.now.addingTimeInterval(-minimumAge)
        let validator = SafetyValidator(homeDirectory: context.homeDirectory)
        var issues: [ScanIssue] = []

        guard let root = ProviderSupport.existingDirectories(allowedRoots).first else {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            await reportCompletion(items: [], progress: progress)
            return ProviderScanResult(location: location, items: [], issues: [])
        }

        do {
            _ = try validator.preflightApprovedRoot(root, location: location)
        } catch {
            issues.append(ScanIssue(
                kind: .inaccessible,
                path: root.path,
                message: error.localizedDescription
            ))
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            await reportCompletion(items: [], progress: progress)
            return ProviderScanResult(location: location, items: [], issues: issues)
        }

        var excludedNames = FileSystemSafetyPolicy.excludedNames
        excludedNames.formUnion(context.excludedDirectoryNames.map { $0.lowercased() })
        if context.excludeNodeModulesFromDeepScans {
            excludedNames.insert("node_modules")
        }

        let options = FileSystemScanOptions(
            recursive: true,
            includeFiles: true,
            includeDirectories: false,
            includeSymbolicLinks: false,
            includeHiddenFiles: context.showHiddenFiles,
            skipPackages: true,
            skipCloudPlaceholders: context.excludeCloudPlaceholders,
            collectItems: true,
            batchSize: 256,
            exclusionURLs: context.exclusions,
            excludedNames: excludedNames,
            modifiedBefore: cutoff
        )

        do {
            let result = try await FileSystemScanner().scan(
                root: root,
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
            try Task.checkCancellation()

            issues.append(contentsOf: result.issues)
            var items: [CleanupItem] = []
            var snapshots: [UUID: CleanupScanSnapshot] = [:]
            items.reserveCapacity(result.items.count)
            snapshots.reserveCapacity(result.items.count)

            for file in result.items {
                try Task.checkCancellation()
                guard file.kind == .file else {
                    continue
                }

                let identity: FileIdentity
                do {
                    identity = try SafetyValidator.captureIdentity(at: file.url)
                } catch {
                    issues.append(FileSystemScanner.issue(for: error, at: file.url))
                    continue
                }
                let snapshotModifiedAt = identity.modificationDate
                guard identity.kind == .file,
                      snapshotModifiedAt < cutoff else {
                    continue
                }

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
                    explanation: "An individual user log file that has not changed for at least \(Int(minimumAge / 86_400)) days.",
                    isSelectedByDefault: false
                )
                items.append(item)
                snapshots[item.id] = CleanupScanSnapshot(
                    identity: identity,
                    exclusionRoots: context.exclusions
                )
            }

            try Task.checkCancellation()
            items.sort { $0.size > $1.size }
            try Task.checkCancellation()

            CleanupSnapshotRegistry.shared.replace(
                providerID: id,
                snapshots: snapshots
            )
            await reportCompletion(items: items, progress: progress)

            return ProviderScanResult(
                location: location,
                items: items,
                issues: issues
            )
        } catch is CancellationError {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            return ProviderScanResult(
                location: location,
                items: [],
                issues: [ScanIssue(
                    kind: .cancelled,
                    path: root.path,
                    message: "Scanning was cancelled."
                )]
            )
        } catch {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            return ProviderScanResult(
                location: location,
                items: [],
                issues: [FileSystemScanner.issue(for: error, at: root)]
            )
        }
    }

    private func reportCompletion(
        items: [CleanupItem],
        progress: @escaping ScanProgressHandler
    ) async {
        await progress(ScanProgress(
            phase: .completed,
            location: location,
            currentPath: allowedRoots.first?.path ?? "",
            filesAnalyzed: items.count,
            bytesFound: items.reduce(0) { $0 + $1.size },
            completedProviders: 1,
            totalProviders: 1
        ))
    }
}
