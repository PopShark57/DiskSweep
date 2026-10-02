import Foundation

struct CleanupScanSnapshot: Sendable {
    let identity: FileIdentity
    let exclusionRoots: [URL]
}

final class CleanupSnapshotRegistry: @unchecked Sendable {
    static let shared = CleanupSnapshotRegistry()

    private let lock = NSLock()
    private var snapshotsByProvider: [String: [UUID: CleanupScanSnapshot]] = [:]

    private init() {}

    func replace(
        providerID: String,
        snapshots: [UUID: CleanupScanSnapshot]
    ) {
        lock.lock()
        snapshotsByProvider[providerID] = snapshots
        lock.unlock()
    }

    func record(
        providerID: String,
        itemID: UUID,
        identity: FileIdentity,
        exclusionRoots: [URL] = []
    ) {
        lock.lock()
        snapshotsByProvider[providerID, default: [:]][itemID] = CleanupScanSnapshot(
            identity: identity,
            exclusionRoots: exclusionRoots
        )
        lock.unlock()
    }

    func snapshot(providerID: String, itemID: UUID) -> CleanupScanSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotsByProvider[providerID]?[itemID]
    }

    func remove(providerID: String, itemID: UUID) {
        lock.lock()
        snapshotsByProvider[providerID]?[itemID] = nil
        if snapshotsByProvider[providerID]?.isEmpty == true {
            snapshotsByProvider[providerID] = nil
        }
        lock.unlock()
    }
}
