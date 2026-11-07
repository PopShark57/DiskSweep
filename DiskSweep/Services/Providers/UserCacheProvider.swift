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
            progress: progress,
            excludedChildNames: Self.excludedChildNames
        )
    }

    /// Children of `~/Library/Caches` that other providers handle, or that hold more than
    /// downloads. Poetry keeps its virtual environments in `pypoetry/virtualenvs` by default,
    /// so `pypoetry` is never offered as one item; Package Manager Caches offers only its
    /// `cache` and `artifacts` folders.
    static let excludedChildNames: Set<String> = [
        "com.apple.Safari", "Google", "Chromium", "Microsoft Edge",
        "BraveSoftware", "Firefox", "Mozilla", "Homebrew",
        "org.swift.swiftpm", "pypoetry"
    ]
}
