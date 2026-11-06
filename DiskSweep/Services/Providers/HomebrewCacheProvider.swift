import Foundation

struct HomebrewCacheProvider: CleanupProvider {
    static let providerID = "homebrew-cache"

    let homeDirectory: URL

    /// Only the standard `~/Library/Caches/Homebrew` cache is offered. `HOMEBREW_CACHE` is
    /// deliberately ignored: apps launched from Finder don't inherit shell variables, and an
    /// environment value must never be able to widen the allowlist. The parameter is kept so
    /// callers (and the safety test) can show that a value passed in changes nothing.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment _: [String: String] = [:]
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .homebrewCache }
    var allowedRoots: [URL] {
        [homeDirectory.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)]
    }

    @concurrent
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
