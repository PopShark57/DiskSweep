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

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult
}

