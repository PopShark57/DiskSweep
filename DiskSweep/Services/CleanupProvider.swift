import Foundation

typealias ScanProgressHandler = @Sendable (ScanProgress) async -> Void

struct ProviderScanResult: Sendable {
    let location: CleanupLocation
    let items: [CleanupItem]
    let issues: [ScanIssue]

    var category: CleanupCategory {
        CleanupCategory(
            location: location,
            items: items,
            issues: issues,
            scannedAt: Date()
        )
    }
}

protocol CleanupProvider: Sendable {
    var id: String { get }
    var location: CleanupLocation { get }
    var allowedRoots: [URL] { get }

    /// Providers do synchronous filesystem work (listing roots, evaluating rules) inside
    /// `scan`. `@concurrent` guarantees it runs on the global concurrent executor even when
    /// called from the main actor, independent of the `NonisolatedNonsendingByDefault`
    /// build setting. Every implementation must keep the attribute.
    @concurrent
    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult
}

