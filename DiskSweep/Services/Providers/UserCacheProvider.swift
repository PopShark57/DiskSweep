import Foundation

struct UserCacheProvider: CleanupProvider {
    static let providerID = "user-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .userCaches }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)]
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
            excludedChildNames: [
                "com.apple.Safari", "Google", "Chromium", "Microsoft Edge",
                "BraveSoftware", "Firefox", "Mozilla", "Homebrew",
                "org.swift.swiftpm"
            ]
        )
    }
}
