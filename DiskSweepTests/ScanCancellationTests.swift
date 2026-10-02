import Foundation
import XCTest
@testable import DiskSweep

final class ScanCancellationTests: XCTestCase {
    func testLargeFileScanCancellationPropagates() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("file.bin", data: Data(repeating: 1, count: 1_024))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true)
        let started = AnalyzerStartSignal()
        let task = Task {
            try await LargeFileAnalyzer().scan(
                context: context,
                progress: { update in
                    guard update.phase == .preparing else { return }
                    await started.signal()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            )
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled large-file scan must not return a completed result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testLargeFolderScanCancellationPropagates() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Folder/file.bin", data: Data(repeating: 1, count: 1_024))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true)
        let started = AnalyzerStartSignal()
        let task = Task {
            try await LargeFolderAnalyzer().scan(
                context: context,
                progress: { update in
                    guard update.phase == .preparing else { return }
                    await started.signal()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            )
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled large-folder scan must not return a completed result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testDuplicateScanCancellationPropagates() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("A.bin", data: Data(repeating: 1, count: 1_024))
        try temporary.file("B.bin", data: Data(repeating: 1, count: 1_024))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true)
        let started = AnalyzerStartSignal()
        let task = Task {
            try await DuplicateAnalyzer().scan(
                root: temporary.url,
                context: context,
                progress: { update in
                    guard update.phase == .preparing else { return }
                    await started.signal()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            )
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled duplicate scan must not return a completed result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
