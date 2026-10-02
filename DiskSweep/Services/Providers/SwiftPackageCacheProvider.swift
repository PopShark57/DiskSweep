import Foundation

struct SwiftPackageCacheProvider: CleanupProvider {
    static let providerID = "swift-package-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .swiftPackageCaches }
    var allowedRoots: [URL] {
        [
            homeDirectory.appendingPathComponent(
                "Library/Caches/org.swift.swiftpm",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(".swiftpm/cache", isDirectory: true),
            homeDirectory.appendingPathComponent(
                ".cache/org.swift.swiftpm",
                isDirectory: true
            )
        ]
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
