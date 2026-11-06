import Foundation
import XCTest
@testable import DiskSweep

final class CleanupSnapshotRegistryTests: XCTestCase {
    private let identity = FileIdentity(
        device: 1,
        inode: 2,
        byteSize: 3,
        allocatedByteSize: 4096,
        modificationTime: 5,
        modificationNanoseconds: 0,
        changeTime: 6,
        changeNanoseconds: 0,
        kind: .file
    )

    func testConcurrentRecordSnapshotAndRemoveLoseNoWrites() async {
        let registry = CleanupSnapshotRegistry()
        let ids = (0..<1_000).map { _ in UUID() }
        let identity = identity

        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    let provider = "provider-\(index % 7)"
                    registry.record(providerID: provider, itemID: id, identity: identity)
                    _ = registry.snapshot(providerID: provider, itemID: id)
                }
            }
        }

        let total = (0..<7).reduce(0) { $0 + registry.count(providerID: "provider-\($1)") }
        XCTAssertEqual(total, 1_000)
        for (index, id) in ids.enumerated() {
            XCTAssertNotNil(registry.snapshot(providerID: "provider-\(index % 7)", itemID: id))
        }

        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() where index.isMultiple(of: 2) {
                group.addTask {
                    registry.remove(providerID: "provider-\(index % 7)", itemID: id)
                }
            }
        }
        let remaining = (0..<7).reduce(0) { $0 + registry.count(providerID: "provider-\($1)") }
        XCTAssertEqual(remaining, 500)
    }

    func testRemoveDeletesEmptyProviderBucket() {
        let registry = CleanupSnapshotRegistry()
        let id = UUID()
        registry.record(providerID: "p", itemID: id, identity: identity)
        XCTAssertTrue(registry.hasBucket(providerID: "p"))

        registry.remove(providerID: "p", itemID: id)
        XCTAssertFalse(registry.hasBucket(providerID: "p"))
        XCTAssertNil(registry.snapshot(providerID: "p", itemID: id))
    }

    func testSeparateRegistriesDoNotShareSnapshots() {
        let first = CleanupSnapshotRegistry()
        let second = CleanupSnapshotRegistry()
        let id = UUID()
        first.record(providerID: "p", itemID: id, identity: identity)
        XCTAssertNil(second.snapshot(providerID: "p", itemID: id))
    }
}
