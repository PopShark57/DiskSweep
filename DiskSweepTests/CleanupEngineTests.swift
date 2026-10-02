import Foundation
import XCTest
@testable import DiskSweep

final class CleanupEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testPermanentlyRemovesAllowedFile() async throws {
        let file = try makeFile(name: "allowed.cache")
        let result = await engine.clean(
            [item(for: file)],
            authorizations: [authorization],
            disposition: .permanent
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.cleanedItems.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.cleanedItems.first?.disposition, .permanent)
    }

    func testUserFilePreferenceDoesNotMoveCacheItemsToTrash() async throws {
        let file = try makeFile(name: "cache-stays-cache.cache")
        let result = await engine.clean(
            [item(for: file)],
            authorizations: [authorization],
            disposition: .trash
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.cleanedItems.first?.disposition, .permanent)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testRejectsOutsideFileAndLeavesItUntouched() async throws {
        let outsideRoot = root.deletingLastPathComponent()
            .appendingPathComponent("DiskSweepOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outside = outsideRoot.appendingPathComponent("important.txt")
        try Data("keep".utf8).write(to: outside)

        let result = await engine.clean(
            [item(for: outside)],
            authorizations: [authorization],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testNeverRemovesApprovedRootItself() async {
        let rootItem = CleanupItem(
            providerID: "test-cache",
            location: .temporaryFiles,
            name: "root",
            url: root,
            size: 0,
            fileCount: 0,
            kind: .directory,
            risk: .safe,
            explanation: "test"
        )

        let result = await engine.clean(
            [rootItem],
            authorizations: [authorization],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testRejectsSymlinkAndPreservesDestination() async throws {
        let destination = try makeFile(name: "destination.cache")
        let link = root.appendingPathComponent("link.cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let linkItem = CleanupItem(
            providerID: "test-cache",
            location: .temporaryFiles,
            name: "link.cache",
            url: link,
            size: 0,
            kind: .symbolicLink,
            risk: .safe,
            explanation: "test",
            isDeletable: true
        )

        let result = await engine.clean(
            [linkItem],
            authorizations: [authorization],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.cleanedItems.isEmpty)
    }

    func testProviderCategoryMismatchIsRejected() async throws {
        let file = try makeFile(name: "mismatch.cache")
        let mismatched = CleanupItem(
            providerID: "test-cache",
            location: .userLogs,
            name: file.lastPathComponent,
            url: file,
            size: 4,
            kind: .file,
            risk: .safe,
            explanation: "test"
        )

        let result = await engine.clean(
            [mismatched],
            authorizations: [authorization],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.failures.count, 1)
    }

    func testExcludedDescendantPreventsRecursiveDirectoryRemoval() async throws {
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let excluded = parent.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: excluded.appendingPathComponent("important.txt"))
        try Data("cache".utf8).write(to: parent.appendingPathComponent("disposable.cache"))

        let provider = TestDirectoryProvider(root: root)
        let scan = await provider.scan(
            context: ScanContext(exclusions: [excluded])
        ) { _ in }
        let scannedItem = try XCTUnwrap(scan.items.first { $0.url == parent })
        XCTAssertFalse(scannedItem.isDeletable)

        let result = await engine.clean(
            [scannedItem],
            providers: [provider],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: excluded.path))
        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testDirectoryReplacementAfterProviderScanIsRejected() async throws {
        let directory = root.appendingPathComponent("ReplaceMe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: directory.appendingPathComponent("old.cache"))
        let provider = TestDirectoryProvider(root: root)
        let scan = await provider.scan(context: ScanContext()) { _ in }
        let scannedItem = try XCTUnwrap(scan.items.first { $0.url == directory })

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replacement = directory.appendingPathComponent("replacement.txt")
        try Data("user data".utf8).write(to: replacement)

        let result = await engine.clean(
            [scannedItem],
            providers: [provider],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testDownloadsBridgeNeverPreselectsUserFiles() async throws {
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("installer.dmg")
        try Data(repeating: 1, count: 16).write(to: file)
        let provider = DownloadsProvider(homeDirectory: home)
        let analysis = try await DownloadsAnalyzer().scan(
            root: downloads,
            context: ScanContext(homeDirectory: home, showHiddenFiles: true)
        )
        let fileItem = try XCTUnwrap(analysis.allFiles.first)

        let cleanupItem = try XCTUnwrap(provider.cleanupItem(for: fileItem))
        XCTAssertEqual(cleanupItem.providerID, DownloadsProvider.providerID)
        XCTAssertEqual(cleanupItem.risk, .userFiles)
        XCTAssertFalse(cleanupItem.isSelectedByDefault)
        XCTAssertEqual(provider.allowedRoots, [downloads])
    }

    func testDownloadsReplacementAfterAnalysisIsRejected() async throws {
        let home = root.appendingPathComponent("ReplacementHome", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let original = downloads.appendingPathComponent("archive.zip")
        let originalDate = Date(timeIntervalSince1970: 2_000_000_000)
        try Data("original".utf8).write(to: original)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: original.path
        )

        let provider = DownloadsProvider(homeDirectory: home)
        let analysis = try await DownloadsAnalyzer().scan(
            root: downloads,
            context: ScanContext(homeDirectory: home, showHiddenFiles: true)
        )
        let fileItem = try XCTUnwrap(analysis.allFiles.first)
        let scannedIdentity = try XCTUnwrap(
            CleanupSnapshotRegistry.shared.snapshot(
                providerID: DownloadsProvider.analysisSnapshotProviderID,
                itemID: fileItem.id
            )?.identity
        )

        let stagedReplacement = home.appendingPathComponent("staged-replacement.zip")
        try Data("replaced".utf8).write(to: stagedReplacement)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: stagedReplacement.path
        )
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: stagedReplacement, to: original)
        XCTAssertNotEqual(scannedIdentity, try SafetyValidator.captureIdentity(at: original))

        let cleanupItem = try XCTUnwrap(provider.cleanupItem(for: fileItem))
        let downloadsEngine = CleanupEngine(
            safetyValidator: SafetyValidator(
                homeDirectory: home,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
        )
        let result = await downloadsEngine.clean(
            [cleanupItem],
            providers: [provider],
            disposition: .permanent
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testHomebrewEnvironmentCannotBroadenItsAllowlist() throws {
        let home = root.appendingPathComponent("HomebrewHome", isDirectory: true)
        let unsafe = home.appendingPathComponent("Downloads/ImportantCache", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        let provider = HomebrewCacheProvider(
            homeDirectory: home,
            environment: ["HOMEBREW_CACHE": unsafe.path]
        )

        XCTAssertEqual(provider.allowedRoots, [
            home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        ])
    }

    func testCleanupCategoryTotalsExcludeNondeletablePartialItems() {
        let deletable = CleanupItem(
            providerID: "test",
            location: .userCaches,
            name: "Deletable",
            url: URL(fileURLWithPath: "/tmp/deletable"),
            size: 100,
            fileCount: 2,
            kind: .directory,
            risk: .safe,
            explanation: "test"
        )
        let partial = CleanupItem(
            providerID: "test",
            location: .userCaches,
            name: "Partial",
            url: URL(fileURLWithPath: "/tmp/partial"),
            size: 900,
            fileCount: 9,
            kind: .directory,
            risk: .safe,
            explanation: "test",
            isDeletable: false
        )
        let category = CleanupCategory(
            location: .userCaches,
            items: [deletable, partial],
            issues: [],
            scannedAt: Date()
        )

        XCTAssertEqual(category.inspectedSize, 1_000)
        XCTAssertEqual(category.totalSize, 100)
        XCTAssertEqual(category.fileCount, 2)
    }

    private var engine: CleanupEngine {
        CleanupEngine(
            safetyValidator: SafetyValidator(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
        )
    }

    private var authorization: CleanupAuthorization {
        CleanupAuthorization(
            providerID: "test-cache",
            location: .temporaryFiles,
            allowedRoots: [root]
        )
    }

    private func makeFile(name: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data("test".utf8).write(to: file)
        return file
    }

    private func item(for file: URL) -> CleanupItem {
        CleanupItem(
            providerID: "test-cache",
            location: .temporaryFiles,
            name: file.lastPathComponent,
            url: file,
            size: 4,
            kind: .file,
            risk: .safe,
            explanation: "test"
        )
    }
}

private struct TestDirectoryProvider: CleanupProvider {
    let root: URL

    var id: String { "test-directory-provider" }
    var location: CleanupLocation { .temporaryFiles }
    var allowedRoots: [URL] { [root] }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        await ProviderSupport.scanChildren(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress,
            forceDefaultSelection: false
        )
    }
}
