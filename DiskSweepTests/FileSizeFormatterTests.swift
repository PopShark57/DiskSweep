import Foundation
import XCTest
@testable import DiskSweep

final class FileSizeFormatterTests: XCTestCase {
    /// The formatter used before 5.5, kept to pin the output.
    private func legacyString(_ byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: byteCount)
    }

    func testOutputMatchesLegacyFormatter() {
        var values: [Int64] = [
            0, -5, 1, 999, 1_000, 1_001, 1_499, 1_500, 1_500_000, 999_999,
            104_857_600, 100_000_000, 1_000_000_000, 1_234_567_890, 5_000_000_000_000,
            Int64.max
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            values.append(Int64.random(in: 1...20_000_000_000_000, using: &generator))
        }

        for value in values {
            XCTAssertEqual(FileSizeFormatter.string(fromByteCount: value), legacyString(value), "\(value)")
        }
    }

    func testZeroAndNegativeShowZeroKB() {
        XCTAssertEqual(FileSizeFormatter.string(fromByteCount: 0), "0 KB")
        XCTAssertEqual(FileSizeFormatter.string(fromByteCount: -1), "0 KB")
    }
}
