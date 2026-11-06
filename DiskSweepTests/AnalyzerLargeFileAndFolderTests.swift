import Foundation
import XCTest
@testable import DiskSweep

final class AnalyzerLargeFileAndFolderTests: XCTestCase {
    private let snapshots = CleanupSnapshotRegistry()
    func testLargeFileScanHonorsThresholdHiddenFilesAndExclusions() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("visible-large.bin", data: Data(repeating: 1, count: 220))
        try temporary.file("small.bin", data: Data(repeating: 2, count: 20))
        try temporary.file(".hidden-large.bin", data: Data(repeating: 3, count: 240))
        let excluded = try temporary.directory("Excluded")
        try temporary.file("Excluded/not-visible.bin", data: Data(repeating: 4, count: 260))
        try temporary.file(".git/object", data: Data(repeating: 5, count: 280))
        try temporary.file("Pictures.photoslibrary/original", data: Data(repeating: 6, count: 300))

        let hiddenOff = ScanContext(
            homeDirectory: temporary.url,
            exclusions: [excluded],
            showHiddenFiles: false,
            snapshots: snapshots
        )
        let analyzer = LargeFileAnalyzer(progressBatchSize: 1)
        let firstResult = try await analyzer.scan(
            root: temporary.url,
            threshold: 100,
            context: hiddenOff
        )

        XCTAssertEqual(firstResult.files.map(\.name), ["visible-large.bin"])
        XCTAssertEqual(firstResult.matchedBytes, 220)

        let hiddenOn = ScanContext(
            homeDirectory: temporary.url,
            exclusions: [excluded],
            showHiddenFiles: true,
            snapshots: snapshots
        )
        let secondResult = try await analyzer.scan(
            root: temporary.url,
            threshold: 100,
            context: hiddenOn
        )

        XCTAssertEqual(
            Set(secondResult.files.map(\.name)),
            Set(["visible-large.bin", ".hidden-large.bin"])
        )
        XCTAssertFalse(secondResult.files.contains { $0.url.path.contains(".git") })
        XCTAssertFalse(secondResult.files.contains { $0.url.path.contains("photoslibrary") })
    }

    func testLargeFolderScanBuildsAccurateHierarchicalTree() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("A/one.bin", data: Data(repeating: 1, count: 10))
        try temporary.file("A/two.bin", data: Data(repeating: 2, count: 20))
        try temporary.file("B/Nested/three.bin", data: Data(repeating: 3, count: 5))
        try temporary.file(".git/ignored.bin", data: Data(repeating: 4, count: 100))
        let target = try temporary.file("symlink-target.bin", data: Data(repeating: 5, count: 7))
        try FileManager.default.createSymbolicLink(
            at: temporary.url.appendingPathComponent("B/link.bin"),
            withDestinationURL: target
        )

        let context = ScanContext(
            homeDirectory: temporary.url,
            showHiddenFiles: true,
            snapshots: snapshots
        )
        let result = try await LargeFolderAnalyzer(progressBatchSize: 1).scan(
            root: temporary.url,
            context: context
        )

        XCTAssertEqual(result.root.size, 42)
        XCTAssertEqual(result.root.fileCount, 4)
        XCTAssertEqual(result.filesAnalyzed, 4)
        XCTAssertEqual(result.root.children.map(\.name), ["A", "B"])

        let folderA = try XCTUnwrap(result.root.children.first { $0.name == "A" })
        XCTAssertEqual(folderA.size, 30)
        XCTAssertEqual(folderA.fileCount, 2)

        let folderB = try XCTUnwrap(result.root.children.first { $0.name == "B" })
        XCTAssertEqual(folderB.size, 5)
        XCTAssertEqual(folderB.fileCount, 1)
        XCTAssertEqual(folderB.children.first?.name, "Nested")

        let largest = result.largestFolders(limit: 2)
        XCTAssertEqual(largest.map(\.name), ["A", "B"])
    }

    func testLargeFolderMinimumRetainedSizePrunesTreeWithoutChangingTotals() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Large/file.bin", data: Data(repeating: 1, count: 40))
        try temporary.file("Small/file.bin", data: Data(repeating: 2, count: 5))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await LargeFolderAnalyzer().scan(
            minimumRetainedFolderSize: 10,
            context: context
        )

        XCTAssertEqual(result.root.size, 45)
        XCTAssertEqual(result.root.fileCount, 2)
        XCTAssertEqual(result.root.children.map(\.name), ["Large"])
    }

    func testDiskUsageAnalyzerAnchorsTreeAtHomeDirectory() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Documents/file.txt", data: Data(repeating: 7, count: 12))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DiskUsageAnalyzer().scanHomeDirectory(context: context)

        XCTAssertEqual(result.root.url.standardizedFileURL, temporary.url.standardizedFileURL)
        XCTAssertEqual(result.root.size, 12)
        XCTAssertEqual(result.root.children.first?.name, "Documents")
    }

    /// D11: the default threshold must be one of the presets, so the picker starts with a
    /// valid selection and no custom stepper.
    func testDefaultThresholdIsADecimalPreset() {
        XCTAssertEqual(LargeFileAnalyzer.defaultThreshold, 100_000_000)
        XCTAssertTrue(
            LargeFileAnalyzer.thresholdPresets.contains { $0.bytes == LargeFileAnalyzer.defaultThreshold }
        )
    }

    // MARK: - Packages as opaque items (D3)

    func testPackageCountsTowardFolderTotalAsOneLeaf() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Media/Show.fcpbundle/Original Media/clip.mov", data: Data(repeating: 7, count: 5_000_000))
        try temporary.file("Media/loose.bin", data: Data(repeating: 1, count: 10_000))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await LargeFolderAnalyzer().scan(root: temporary.url, context: context)

        XCTAssertGreaterThanOrEqual(result.root.size, 5_000_000)
        let media = try XCTUnwrap(result.root.children.first { $0.name == "Media" })
        XCTAssertGreaterThanOrEqual(media.size, 5_010_000)
        let bundle = try XCTUnwrap(media.children.first { $0.name == "Show.fcpbundle" })
        XCTAssertTrue(bundle.isPackage)
        XCTAssertTrue(bundle.children.isEmpty, "A package is a leaf")
        XCTAssertGreaterThanOrEqual(bundle.size, 5_000_000)
    }

    func testLargeFilesListsPackageAsOneItemNotItsContents() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Apps/Tool.app/Contents/Resources/big.dat", data: Data(repeating: 3, count: 2_000_000))
        try temporary.file("Pictures.photoslibrary/original.jpg", data: Data(repeating: 6, count: 2_000_000))
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await LargeFileAnalyzer().scan(
            root: temporary.url,
            threshold: 1_000_000,
            context: context
        )

        XCTAssertEqual(result.files.map(\.name), ["Tool.app"])
        let item = try XCTUnwrap(result.files.first)
        XCTAssertTrue(item.isPackage)
        XCTAssertEqual(item.kind, .directory)
        XCTAssertGreaterThanOrEqual(item.size, 2_000_000)
    }

    func testPackagesAreListedFileByFileWhenTheSettingIsOff() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        try temporary.file("Apps/Tool.app/Contents/Resources/big.dat", data: Data(repeating: 3, count: 2_000_000))
        let context = ScanContext(
            homeDirectory: temporary.url,
            showHiddenFiles: true,
            excludePackageContents: false,
            snapshots: snapshots
        )

        let result = try await LargeFileAnalyzer().scan(root: temporary.url, threshold: 1_000_000, context: context)
        XCTAssertEqual(result.files.map(\.name), ["big.dat"])
    }

    func testDuplicatesStillSkipPackages() async throws {
        let temporary = try AnalyzerTemporaryDirectory()
        let data = Data(repeating: 9, count: 8_192)
        try temporary.file("A/Tool.app/Contents/Resources/x.dat", data: data)
        try temporary.file("B/Tool.app/Contents/Resources/x.dat", data: data)
        let context = ScanContext(homeDirectory: temporary.url, showHiddenFiles: true, snapshots: snapshots)

        let result = try await DuplicateAnalyzer().scan(root: temporary.url, context: context)
        XCTAssertTrue(result.groups.isEmpty)
    }

    /// M5: the "Files in this folder" row makes the rows add up to the folder's total.
    func testUnlistedSizeMakesRowsAddUpToTheFolderTotal() {
        let child = DirectoryNode(url: URL(fileURLWithPath: "/x/a"), size: 600, fileCount: 2)
        let other = DirectoryNode(url: URL(fileURLWithPath: "/x/b"), size: 300, fileCount: 1)
        let folder = DirectoryNode(url: URL(fileURLWithPath: "/x"), size: 1_000, fileCount: 5, children: [child, other])
        XCTAssertEqual(folder.unlistedSize, 100)
        XCTAssertEqual(folder.children.reduce(0) { $0 + $1.size } + folder.unlistedSize, folder.size)
        XCTAssertEqual(DirectoryNode(url: URL(fileURLWithPath: "/y"), size: 5, fileCount: 1).unlistedSize, 5)
    }
}
