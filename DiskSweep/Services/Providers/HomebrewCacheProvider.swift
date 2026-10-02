import Foundation

struct HomebrewCacheProvider: CleanupProvider {
    static let providerID = "homebrew-cache"

    let homeDirectory: URL
    private let environmentCache: URL?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.environmentCache = Self.validEnvironmentCache(
            environment["HOMEBREW_CACHE"],
            homeDirectory: self.homeDirectory
        )
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .homebrewCache }
    var allowedRoots: [URL] {
        let standard = homeDirectory.appendingPathComponent(
            "Library/Caches/Homebrew",
            isDirectory: true
        )
        if let environmentCache, environmentCache != standard {
            return [standard, environmentCache]
        }
        return [standard]
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

    private static func validEnvironmentCache(
        _ path: String?,
        homeDirectory: URL
    ) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let standardCache = homeDirectory
            .appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
            .resolvingSymlinksInPath()
        return candidate == standardCache ? candidate : nil
    }
}
