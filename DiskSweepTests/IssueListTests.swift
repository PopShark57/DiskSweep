import Foundation
import XCTest
@testable import DiskSweep

final class IssueListTests: XCTestCase {
    func testIssuesAreGroupedByKindInActionableOrder() {
        let issues = [
            ScanIssue(kind: .disappeared, path: "/b", message: "gone"),
            ScanIssue(kind: .permissionDenied, path: "/z", message: "denied"),
            ScanIssue(kind: .permissionDenied, path: "/a", message: "denied"),
            ScanIssue(kind: .cancelled, path: "/c", message: "cancelled")
        ]

        let grouped = IssueList.grouped(issues)

        XCTAssertEqual(grouped.map(\.kind), [.permissionDenied, .disappeared, .cancelled])
        XCTAssertEqual(grouped.first?.issues.map(\.path), ["/a", "/z"])
        XCTAssertEqual(grouped.reduce(0) { $0 + $1.issues.count }, issues.count)
    }
}
