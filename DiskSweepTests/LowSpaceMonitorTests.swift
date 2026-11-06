import Foundation
import XCTest
@testable import DiskSweep

final class LowSpaceMonitorTests: XCTestCase {
    func testNotifiesOncePerDropBelowTheThreshold() {
        var monitor = LowSpaceMonitor()
        let threshold: Int64 = 20_000_000_000

        XCTAssertFalse(monitor.shouldNotify(available: 50_000_000_000, thresholdBytes: threshold))
        XCTAssertTrue(monitor.shouldNotify(available: 15_000_000_000, thresholdBytes: threshold))
        XCTAssertFalse(monitor.shouldNotify(available: 10_000_000_000, thresholdBytes: threshold), "Still low: no repeat")
        XCTAssertFalse(monitor.shouldNotify(available: 25_000_000_000, thresholdBytes: threshold))
        XCTAssertTrue(monitor.shouldNotify(available: 19_000_000_000, thresholdBytes: threshold), "Dropped again")
        XCTAssertFalse(monitor.shouldNotify(available: 0, thresholdBytes: threshold), "Unknown capacity never notifies")
    }
}
