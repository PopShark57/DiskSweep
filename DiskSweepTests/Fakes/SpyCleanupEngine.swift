import Foundation
@testable import DiskSweep

/// Records what the view model asks to clean and reports every item as cleaned, without
/// touching the filesystem.
actor SpyCleanupEngine: CleanupPerforming {
    private(set) var calls: [(items: [CleanupItem], disposition: CleanupDisposition?)] = []

    func clean(
        _ items: [CleanupItem],
        providers: [any CleanupProvider],
        disposition: CleanupDisposition?,
        exclusions: [URL]
    ) async -> CleanupResult {
        calls.append((items, disposition))
        return CleanupResult(
            startedAt: Date(),
            finishedAt: Date(),
            availableBefore: 0,
            availableAfter: 0,
            cleanedItems: items.map {
                CleanedItemRecord(
                    name: $0.name,
                    location: $0.location,
                    bytes: $0.size,
                    fileCount: $0.fileCount,
                    disposition: disposition ?? .permanent
                )
            },
            failures: []
        )
    }

    var cleanedIDs: [[UUID]] { calls.map { $0.items.map(\.id) } }
}
