import Foundation

struct ApplicationCacheProvider: CleanupProvider {
    static let providerID = "application-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .applicationCaches }
    var allowedRoots: [URL] {
        ProviderPaths.applicationCacheRoots(homeDirectory: homeDirectory)
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
