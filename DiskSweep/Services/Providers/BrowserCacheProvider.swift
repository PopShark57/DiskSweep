import Foundation

struct BrowserCacheProvider: CleanupProvider {
    static let providerID = "browser-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .browserCaches }
    var allowedRoots: [URL] {
        ProviderPaths.browserCacheRoots(homeDirectory: homeDirectory)
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
