import Foundation
import XCTest
@testable import DiskSweep

final class DuplicateAnalyzerTests: XCTestCase {
    private let snapshots = CleanupSnapshotRegistry()
    func testDuplicateDetectionUsesStagedComparisonAndFindsExactCopies() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let duplicateData = Data(repeating: 0x2A, count: 256 * 1_024)
        let sameSizeDifferentSample = Data(repeating: 0x2B, count: duplicateData.count)
        try temporary.file("A/original.bin", data: duplicateData)
        try temporary.file("B/copy.bin", data: duplicateData)
        try temporary.file("C/different.bin", data: sameSizeDifferentSample)
        try temporary.file("unique.bin", data: Data(repeating: 0x2A, count: 127))

        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)
        let analyzer = DuplicateAnalyzer(
            sampleByteCount: 1_024,
            readChunkByteCount: 4_096,
            progressBatchSize: 1
        )
        let result = try await analyzer.scan(root: temporary.url, context: context)

        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(Set(group.files.map(\.name)), Set(["original.bin", "copy.bin"]))
        XCTAssertEqual(group.fileSize, Int64(duplicateData.count))
        XCTAssertEqual(group.reclaimableSize, Int64(duplicateData.count))
        XCTAssertEqual(result.reclaimableSize, Int64(duplicateData.count))
        XCTAssertEqual(result.diagnostics.sizeCandidateFiles, 3)
        XCTAssertEqual(result.diagnostics.sampledFiles, 3)
        // 5.4: a sample-matched pair is compared byte for byte without hashing first.
        XCTAssertEqual(result.diagnostics.cryptographicallyHashedFiles, 0)
        XCTAssertEqual(result.diagnostics.byteForByteComparisons, 1)
    }

    /// 5.4: groups of three or more still hash before the byte-for-byte check, and a pair
    /// whose bytes differ after matching samples is not reported.
    func testTriplesStillHashAndPairsAreStillConfirmedByBytes() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let data = Data(repeating: 0x33, count: 64 * 1_024)
        try temporary.file("One/a.bin", data: data)
        try temporary.file("Two/b.bin", data: data)
        try temporary.file("Three/c.bin", data: data)
        // Same size and same sampled bytes (start, middle, end), different in between.
        var nearCopy = Data(repeating: 0x44, count: 48 * 1_024)
        let nearCopyOriginal = nearCopy
        nearCopy[20_000] = 0x45
        try temporary.file("Four/d.bin", data: nearCopyOriginal)
        try temporary.file("Five/e.bin", data: nearCopy)
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer(sampleByteCount: 512).scan(
            root: temporary.url,
            context: context
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.name)), ["a.bin", "b.bin", "c.bin"])
        XCTAssertEqual(result.diagnostics.cryptographicallyHashedFiles, 3)
        XCTAssertEqual(result.diagnostics.byteForByteComparisons, 2 + 1)
    }

    func testMatchingNamesAndSizesAreNotEnough() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("A/report.dat", data: Data(repeating: 1, count: 4_096))
        try temporary.file("B/report.dat", data: Data(repeating: 2, count: 4_096))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer(sampleByteCount: 128).scan(
            root: temporary.url,
            context: context
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.diagnostics.sizeCandidateFiles, 2)
        XCTAssertEqual(result.diagnostics.sampledFiles, 2)
        XCTAssertEqual(result.diagnostics.cryptographicallyHashedFiles, 0)
    }

    func testDuplicateScanSkipsGitNodeModulesPhotosAndSymlinks() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let data = Data(repeating: 8, count: 2_048)
        let visible = try temporary.file("visible.bin", data: data)
        try temporary.file("node_modules/copy.bin", data: data)
        try temporary.file(".git/copy.bin", data: data)
        try temporary.file("Library.photoslibrary/copy.bin", data: data)
        try FileManager.default.createSymbolicLink(
            at: temporary.url.appendingPathComponent("link.bin"),
            withDestinationURL: visible
        )
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer().scan(root: temporary.url, context: context)

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.filesAnalyzed, 1)
    }

    func testHardLinkAliasesAreNotReportedAsReclaimableDuplicates() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let data = Data(repeating: 9, count: 8_192)
        let original = try temporary.file("original.bin", data: data)
        try FileManager.default.linkItem(
            at: original,
            to: temporary.url.appendingPathComponent("alias.bin")
        )
        try temporary.file("independent-copy.bin", data: data)
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer().scan(root: temporary.url, context: context)

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.diagnostics.hardLinkAliasesIgnored, 2)
    }

    func testSelectionHelpersAlwaysPreserveAtLeastOneCopy() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let data = Data(repeating: 4, count: 4_096)
        try temporary.file("A.bin", data: data)
        try temporary.file("B.bin", data: data)
        try temporary.file("C.bin", data: data)
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)
        let analyzer = DuplicateAnalyzer()
        let result = try await analyzer.scan(root: temporary.url, context: context)
        let group = try XCTUnwrap(result.groups.first)

        XCTAssertTrue(analyzer.defaultSelection(in: group).isEmpty)
        XCTAssertEqual(analyzer.suggestedSelection(in: group).count, 2)

        let everyID = Set(group.files.map(\.id))
        let validated = analyzer.selectionPreservingOneCopy(everyID, in: group)
        XCTAssertEqual(validated.count, 2)
        XCTAssertTrue(validated.isSubset(of: everyID))
    }

    func testOverlappingRootsDoNotEnumerateFilesTwice() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let nested = try temporary.directory("Nested")
        try temporary.file("Nested/only.bin", data: Data(repeating: 1, count: 1_024))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer().scan(
            roots: [temporary.url, nested],
            context: context
        )

        XCTAssertEqual(result.filesAnalyzed, 1)
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// F4: clones are still duplicates, but each reports almost no unique size.
    func testClonedCopiesReportTheirUniqueSize() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let original = try temporary.file("A/original.bin", data: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }))
        let clone = temporary.url.appendingPathComponent("B/clone.bin")
        try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = original.withUnsafeFileSystemRepresentation { source in
            clone.withUnsafeFileSystemRepresentation { clonefile(source!, $0!, 0) }
        }
        XCTAssertEqual(status, 0)
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer().scan(root: temporary.url, context: context)

        let files = try XCTUnwrap(result.groups.first?.files)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { ($0.uniqueSize ?? .max) < 4_096 })
        XCTAssertTrue(files.allSatisfy(\.isMostlyShared))
    }
}
