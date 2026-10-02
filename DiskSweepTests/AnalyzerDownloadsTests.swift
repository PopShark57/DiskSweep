import Foundation
import XCTest
@testable import DiskSweep

final class AnalyzerDownloadsTests: XCTestCase {
    func testDownloadsAreGroupedByTypeAndNeverPreselected() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = referenceDate.addingTimeInterval(-24 * 60 * 60)

        try temporary.file("macOS.dmg", data: Data([1]), modifiedAt: recent)
        try temporary.file("source.zip", data: Data([2]), modifiedAt: recent)
        try temporary.file("tool.pkg", data: Data([3]), modifiedAt: recent)
        try temporary.file("clip.mov", data: Data([4]), modifiedAt: recent)
        try temporary.file("photo.heic", data: Data([5]), modifiedAt: recent)
        try temporary.file("notes.pdf", data: Data([6]), modifiedAt: recent)
        try temporary.file("unknown.data", data: Data([7]), modifiedAt: recent)

        let context = ScanContext(
            homeDirectory: temporary.url,
            showHiddenFiles: true,
            now: referenceDate
        )
        let result = try await DownloadsAnalyzer(progressBatchSize: 1).scan(
            root: temporary.url,
            context: context
        )

        XCTAssertEqual(result.allFiles.count, 7)
        XCTAssertEqual(result[.diskImages]?.files.map(\.name), ["macOS.dmg"])
        XCTAssertEqual(result[.archives]?.files.map(\.name), ["source.zip"])
        XCTAssertEqual(result[.installers]?.files.map(\.name), ["tool.pkg"])
        XCTAssertEqual(result[.videos]?.files.map(\.name), ["clip.mov"])
        XCTAssertEqual(result[.images]?.files.map(\.name), ["photo.heic"])
        XCTAssertEqual(result[.documents]?.files.map(\.name), ["notes.pdf"])
        XCTAssertEqual(result[.other]?.files.map(\.name), ["unknown.data"])
        XCTAssertTrue(result.defaultSelectedFileIDs.isEmpty)
    }

    func testDownloadsAgeAndSizeFiltersCanBeCombinedAndReapplied() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)
        let old = referenceDate.addingTimeInterval(-100 * 24 * 60 * 60)
        let recent = referenceDate.addingTimeInterval(-2 * 24 * 60 * 60)
        let largeSize = UInt64(100 * 1_024 * 1_024 + 1)

        try temporary.sparseFile("old-large.dmg", logicalSize: largeSize, modifiedAt: old)
        try temporary.file("old-small.zip", data: Data(repeating: 1, count: 20), modifiedAt: old)
        try temporary.sparseFile("recent-large.iso", logicalSize: largeSize, modifiedAt: recent)
        try temporary.file("recent-small.txt", data: Data(repeating: 2, count: 30), modifiedAt: recent)

        let context = ScanContext(
            homeDirectory: temporary.url,
            showHiddenFiles: true,
            now: referenceDate
        )
        let unfiltered = try await DownloadsAnalyzer().scan(
            root: temporary.url,
            context: context
        )

        let oldOnly = unfiltered.applying(.olderThan90Days)
        XCTAssertEqual(Set(oldOnly.filteredFiles.map(\.name)), Set(["old-large.dmg", "old-small.zip"]))

        let largeOnly = unfiltered.applying(.largerThan100MB)
        XCTAssertEqual(Set(largeOnly.filteredFiles.map(\.name)), Set(["old-large.dmg", "recent-large.iso"]))

        let combined = unfiltered.applying(
            DownloadsFilter(
                olderThan: 90 * 24 * 60 * 60,
                largerThan: 100 * 1_024 * 1_024
            )
        )
        XCTAssertEqual(combined.filteredFiles.map(\.name), ["old-large.dmg"])
        XCTAssertEqual(combined.allFiles.count, 4)
    }

    func testDownloadsHiddenAndCustomExclusionsAreHonored() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("visible.zip", data: Data([1]))
        try temporary.file(".hidden.zip", data: Data([2]))
        let excluded = try temporary.directory("DoNotScan")
        try temporary.file("DoNotScan/excluded.zip", data: Data([3]))
        let context = ScanContext(
            homeDirectory: temporary.url,
            exclusions: [excluded],
            showHiddenFiles: false
        )

        let result = try await DownloadsAnalyzer().scan(
            root: temporary.url,
            context: context
        )

        XCTAssertEqual(result.allFiles.map(\.name), ["visible.zip"])
    }
}
