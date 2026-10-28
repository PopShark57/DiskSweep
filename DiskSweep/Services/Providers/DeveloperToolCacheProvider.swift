import Foundation

/// Download caches that package managers keep outside `~/Library/Caches`, usually in dotfolders.
/// Caches inside `~/Library/Caches` (Yarn 1, pip on some setups, CocoaPods, Go) are already
/// offered by the user cache provider, so they are not repeated here.
struct DeveloperToolCacheProvider: CleanupProvider {
    static let providerID = "developer-tool-caches"

    struct CacheDirectory: Sendable {
        let relativePath: String
        let tool: String
        /// Names the folder when one tool keeps several caches, such as Cargo's downloaded
        /// crates and their extracted sources.
        let label: String
        /// Some tool configurations can link installed environments to cache entries, so these
        /// caches are offered but never selected automatically.
        let needsReview: Bool

        init(
            _ relativePath: String,
            tool: String,
            label: String? = nil,
            needsReview: Bool = false
        ) {
            self.relativePath = relativePath
            self.tool = tool
            self.label = label ?? tool
            self.needsReview = needsReview
        }
    }

    /// Maven's `~/.m2/repository`, Go's module cache, and conda's package cache are left out on
    /// purpose: they can hold locally installed artifacts, read-only files, or hard links into
    /// environments, so removing them is not reliably harmless.
    static let cacheDirectories: [CacheDirectory] = [
        CacheDirectory(".npm/_cacache", tool: "npm"),
        CacheDirectory(".pnpm-store", tool: "pnpm"),
        CacheDirectory("Library/pnpm/store", tool: "pnpm"),
        CacheDirectory(".local/share/pnpm/store", tool: "pnpm"),
        CacheDirectory(".yarn/berry/cache", tool: "Yarn"),
        CacheDirectory(".bun/install/cache", tool: "Bun"),
        CacheDirectory(".cache/pip", tool: "pip"),
        // uv can be configured to symlink environments into its cache.
        CacheDirectory(".cache/uv", tool: "uv", needsReview: true),
        CacheDirectory(".cache/pre-commit", tool: "pre-commit"),
        CacheDirectory(".cargo/registry/cache", tool: "Cargo", label: "Cargo crates"),
        CacheDirectory(".cargo/registry/src", tool: "Cargo", label: "Cargo crate sources"),
        CacheDirectory(".cargo/git/checkouts", tool: "Cargo", label: "Cargo Git checkouts"),
        CacheDirectory(".gradle/caches", tool: "Gradle", label: "Gradle caches"),
        CacheDirectory(".gradle/wrapper/dists", tool: "Gradle", label: "Gradle distributions"),
        CacheDirectory(".cocoapods/repos", tool: "CocoaPods"),
        CacheDirectory(".composer/cache", tool: "Composer"),
        CacheDirectory(".cache/composer", tool: "Composer"),
        CacheDirectory(".node-gyp", tool: "node-gyp")
    ]

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .developerToolCaches }
    var allowedRoots: [URL] {
        Self.cacheDirectories.map {
            homeDirectory.appendingPathComponent($0.relativePath, isDirectory: true)
        }
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let result = await ProviderSupport.scanChildren(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress,
            // The marker that identifies a cache folder is not worth offering on its own.
            excludedChildNames: ["CACHEDIR.TAG"]
        )

        // Name each item after its tool. Item IDs are kept so scan snapshots still match.
        let items = result.items.map { item -> CleanupItem in
            guard let cache = cacheDirectory(containing: item.url) else { return item }
            return CleanupItem(
                id: item.id,
                providerID: item.providerID,
                location: item.location,
                name: "\(cache.label) — \(item.url.lastPathComponent)",
                url: item.url,
                size: item.size,
                fileCount: item.fileCount,
                kind: item.kind,
                modifiedAt: item.modifiedAt,
                risk: cache.needsReview ? .reviewRecommended : item.risk,
                explanation: item.explanation,
                detail: "\(cache.tool) downloads this again the next time it needs it.",
                isSelectedByDefault: cache.needsReview ? false : item.isSelectedByDefault,
                isDeletable: item.isDeletable
            )
        }
        return ProviderScanResult(location: location, items: items, issues: result.issues)
    }

    private func cacheDirectory(containing url: URL) -> CacheDirectory? {
        let parent = url.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return Self.cacheDirectories.first {
            homeDirectory.appendingPathComponent($0.relativePath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().pathComponents == parent
        }
    }
}
