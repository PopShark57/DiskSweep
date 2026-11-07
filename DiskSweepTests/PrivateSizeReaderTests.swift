import Darwin
import Foundation
import XCTest
@testable import DiskSweep

final class PrivateSizeReaderTests: XCTestCase {
    func testClonesShareTheirBlocksAndPlainFilesDoNot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepPrivateSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.bin")
        try Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: original)

        let plain = try XCTUnwrap(PrivateSizeReader.privateSize(of: original), "The test volume must be APFS")
        XCTAssertGreaterThanOrEqual(plain, 1_048_576)

        let clone = directory.appendingPathComponent("clone.bin")
        let status = original.withUnsafeFileSystemRepresentation { source in
            clone.withUnsafeFileSystemRepresentation { destination in
                clonefile(source!, destination!, 0)
            }
        }
        XCTAssertEqual(status, 0)
        XCTAssertLessThan(try XCTUnwrap(PrivateSizeReader.privateSize(of: clone)), 4_096)
        XCTAssertLessThan(try XCTUnwrap(PrivateSizeReader.privateSize(of: original)), 4_096)

        XCTAssertNil(PrivateSizeReader.privateSize(of: directory.appendingPathComponent("missing")))
    }
}
