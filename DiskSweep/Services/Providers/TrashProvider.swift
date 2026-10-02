import Foundation

struct TrashProvider: CleanupProvider {
    static let providerID = "trash"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .trash }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent(".Trash", isDirectory: true)]
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
