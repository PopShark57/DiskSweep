import Foundation
import XCTest
@testable import DiskSweep

final class ScanIssueMappingTests: XCTestCase {
    func testErrorKindMappingTable() {
        let url = URL(fileURLWithPath: "/tmp/example")
        let cases: [(Error, ScanIssue.Kind)] = [
            (CocoaError(.fileReadNoPermission), .permissionDenied),
            (CocoaError(.fileWriteNoPermission), .permissionDenied),
            (CocoaError(.fileNoSuchFile), .disappeared),
            (CocoaError(.fileReadNoSuchFile), .disappeared),
            (CocoaError(.fileReadUnknown), .inputOutput),
            (CocoaError(.fileReadCorruptFile), .inputOutput),
            (CocoaError(.fileReadInapplicableStringEncoding), .inputOutput),
            (CocoaError(.fileWriteOutOfSpace), .inaccessible),
            (POSIXError(.EACCES), .permissionDenied),
            (POSIXError(.EPERM), .permissionDenied),
            (POSIXError(.ENOENT), .disappeared),
            (POSIXError(.EIO), .inputOutput),
            (POSIXError(.ELOOP), .inaccessible),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .permissionDenied),
            (SafetyValidationError.cannotInspect("/tmp/example"), .inaccessible),
            (SafetyValidationError.targetDoesNotExist("/tmp/example"), .inaccessible),
            (FileSystemScannerError.rootDoesNotExist("/tmp/example"), .unknown),
            (NSError(domain: "Other", code: 1), .unknown)
        ]

        for (error, expected) in cases {
            let issue = ScanIssue(error: error, at: url)
            XCTAssertEqual(issue.kind, expected, "\(error)")
            XCTAssertEqual(issue.path, url.path)
            XCTAssertEqual(issue.message, error.localizedDescription)
        }
    }
}
