import Foundation
import Synchronization

struct CleanupScanSnapshot: Sendable {
    let identity: FileIdentity
    let exclusionRoots: [URL]
}

/// Hands scan-time file identities from providers and analyzers to the cleanup engine.
///
/// A scan and the cleanup that follows must use the same instance: the engine refuses any
/// item whose snapshot it can't find. `AppViewModel` creates one registry and passes it to
/// both its scan contexts and its engine. Tests create their own, so they never share state.
final class CleanupSnapshotRegistry: Sendable {
    /// The default instance used when no registry is injected.
    static let shared = CleanupSnapshotRegistry()

    private let state = Mutex<[String: [UUID: CleanupScanSnapshot]]>([:])

    init() {}

    func replace(
        providerID: String,
        snapshots: [UUID: CleanupScanSnapshot]
    ) {
        state.withLock { $0[providerID] = snapshots }
    }

    func record(
        providerID: String,
        itemID: UUID,
        identity: FileIdentity,
        exclusionRoots: [URL] = []
    ) {
        let snapshot = CleanupScanSnapshot(identity: identity, exclusionRoots: exclusionRoots)
        state.withLock { $0[providerID, default: [:]][itemID] = snapshot }
    }

    func snapshot(providerID: String, itemID: UUID) -> CleanupScanSnapshot? {
        state.withLock { $0[providerID]?[itemID] }
    }

    func remove(providerID: String, itemID: UUID) {
        state.withLock { snapshots in
            snapshots[providerID]?[itemID] = nil
            if snapshots[providerID]?.isEmpty == true {
                snapshots[providerID] = nil
            }
        }
    }

    /// The number of snapshots recorded for a provider. Used by tests.
    func count(providerID: String) -> Int {
        state.withLock { $0[providerID]?.count ?? 0 }
    }

    /// Whether any snapshots are recorded for a provider. Used by tests.
    func hasBucket(providerID: String) -> Bool {
        state.withLock { $0[providerID] != nil }
    }
}
