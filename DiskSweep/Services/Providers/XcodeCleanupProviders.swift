import Foundation

struct XcodeDerivedDataProvider: CleanupProvider {
    static let providerID = "xcode-derived-data"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .xcodeDerivedData }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData",
            isDirectory: true
        )]
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        await ProviderSupport.scanChildren(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress
        )
    }
}

struct XcodeArchivesProvider: CleanupProvider {
    static let providerID = "xcode-archives"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .xcodeArchives }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent(
            "Library/Developer/Xcode/Archives",
            isDirectory: true
        )]
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
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
        let options = FileSystemScanOptions(
            recursive: true,
            includeFiles: false,
            includeDirectories: true,
            includeSymbolicLinks: false,
            includeHiddenFiles: context.showHiddenFiles,
            skipPackages: true,
            skipCloudPlaceholders: context.excludeCloudPlaceholders,
            collectItems: true,
            batchSize: 256,
            exclusionURLs: context.exclusions,
            excludedNames: excludedNames
        )

        do {
            let candidates = try await FileSystemScanner().scan(
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
            issues.append(contentsOf: candidates.issues)

            let archives = candidates.items.filter {
                $0.kind == .directory
                    && $0.url.pathExtension.lowercased() == "xcarchive"
            }
            var items: [CleanupItem] = []
            var snapshots: [UUID: CleanupScanSnapshot] = [:]
            var inspectedFiles = 0
            var inspectedBytes: Int64 = 0
            items.reserveCapacity(archives.count)
            snapshots.reserveCapacity(archives.count)

            for archive in archives {
                try Task.checkCancellation()
                var isDeletable = true
                var explanation = "One archived Xcode build. Archives may be needed for distribution or symbolication, so DiskSweep never selects them automatically."
                var byteCount: Int64 = 0
                var fileCount = 0
                let baselineFiles = inspectedFiles
                let baselineBytes = inspectedBytes

                do {
                    let measured = try await DirectorySizer().size(
                        of: archive.url,
                        exclusions: context.exclusions,
                        includeHiddenFiles: true,
                        skipPackages: false,
                        batchSize: 256
                    ) { update in
                        await progress(ScanProgress(
                            phase: .enumerating,
                            location: location,
                            currentPath: update.currentURL.path,
                            filesAnalyzed: baselineFiles + update.filesAnalyzed,
                            bytesFound: baselineBytes + update.bytesFound,
                            completedProviders: 0,
                            totalProviders: 1
                        ))
                    }
                    byteCount = measured.byteCount
                    fileCount = measured.fileCount
                    issues.append(contentsOf: measured.issues)
                    if !measured.excludedURLs.isEmpty || !measured.issues.isEmpty {
                        isDeletable = false
                        explanation += " It contains excluded or uninspected content, so it cannot be removed as a unit."
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    issues.append(FileSystemScanner.issue(for: error, at: archive.url))
                    isDeletable = false
                    explanation += " DiskSweep could not inspect every descendant, so this archive cannot be removed."
                }

                inspectedFiles += max(0, fileCount)
                inspectedBytes += max(0, byteCount)

                let identity = try? SafetyValidator.captureIdentity(at: archive.url)
                if identity == nil {
                    isDeletable = false
                    issues.append(ScanIssue(
                        kind: .disappeared,
                        path: archive.url.path,
                        message: "The archive changed or disappeared before its cleanup identity could be recorded."
                    ))
                }

                let item = CleanupItem(
                    providerID: id,
                    location: location,
                    name: archive.name,
                    url: archive.url,
                    size: byteCount,
                    fileCount: fileCount,
                    kind: .directory,
                    modifiedAt: archive.modifiedAt,
                    risk: .reviewRecommended,
                    explanation: explanation,
                    isSelectedByDefault: false,
                    isDeletable: isDeletable
                )
                items.append(item)
                if let identity {
                    snapshots[item.id] = CleanupScanSnapshot(
                        identity: identity,
                        exclusionRoots: context.exclusions
                    )
                }
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
            filesAnalyzed: items.reduce(0) { $0 + $1.fileCount },
            bytesFound: items.reduce(0) { $0 + $1.size },
            completedProviders: 1,
            totalProviders: 1
        ))
    }
}

struct XcodeSimulatorDataProvider: CleanupProvider {
    static let providerID = "xcode-simulator-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .xcodeSimulatorData }
    var allowedRoots: [URL] {
        ProviderPaths.simulatorCacheRoots(homeDirectory: homeDirectory)
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        // Only simulator cache directories are exposed. Device app data is never allowlisted.
        await ProviderSupport.scanChildren(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress,
            forceDefaultSelection: false
        )
    }
}

struct XcodeDeviceSupportProvider: CleanupProvider {
    static let providerID = "xcode-device-support"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .xcodeDeviceSupport }
    var allowedRoots: [URL] {
        let xcode = homeDirectory.appendingPathComponent(
            "Library/Developer/Xcode",
            isDirectory: true
        )
        return [
            "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
            "visionOS DeviceSupport"
        ].map { xcode.appendingPathComponent($0, isDirectory: true) }
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        await ProviderSupport.scanChildren(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress,
            forceDefaultSelection: false
        )
    }
}
