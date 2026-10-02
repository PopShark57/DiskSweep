import Foundation

struct DownloadsProvider: CleanupProvider {
    static let providerID = "downloads"
    static let analysisSnapshotProviderID = "downloads.analysis"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .downloads }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent("Downloads", isDirectory: true)]
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

    func cleanupItem(for file: FileItem) -> CleanupItem? {
        let downloads = allowedRoots[0].standardizedFileURL
        let candidate = file.url.standardizedFileURL
        let rootComponents = downloads.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents,
              file.kind == .file else {
            return nil
        }

        let item = CleanupItem(
            providerID: id,
            location: location,
            name: file.name,
            url: candidate,
            size: file.size,
            fileCount: file.kind == .directory ? 0 : 1,
            kind: file.kind,
            modifiedAt: file.modifiedAt,
            risk: .userFiles,
            explanation: "A file from Downloads. DiskSweep will move it to Trash unless permanent deletion is explicitly requested.",
            isSelectedByDefault: false,
            isDeletable: true
        )
        guard let scanSnapshot = CleanupSnapshotRegistry.shared.snapshot(
            providerID: Self.analysisSnapshotProviderID,
            itemID: file.id
        ) else {
            return nil
        }
        CleanupSnapshotRegistry.shared.record(
            providerID: id,
            itemID: item.id,
            identity: scanSnapshot.identity,
            exclusionRoots: scanSnapshot.exclusionRoots
        )
        return item
    }
}
