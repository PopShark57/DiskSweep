import Foundation
import XCTest
@testable import DiskSweep

final class TrashRestorerTests: XCTestCase {
    private let snapshots = CleanupSnapshotRegistry()
    private var root: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepRestoreTests-\(UUID().uuidString)", isDirectory: true)
        // A stand-in Trash inside the temporary directory; the real Trash is never used.
        trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func moveToTestTrash() -> CleanupEngine.TrashMover {
        let trash = trash!
        return { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager().moveItem(at: url, to: destination)
            return destination
        }
    }

    func testEngineRecordsWhereTrashedItemsWentAndRestorerPutsThemBack() async throws {
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("report.pdf")
        try Data("report".utf8).write(to: file)

        let provider = DownloadsProvider(homeDirectory: home)
        let analysis = try await DownloadsAnalyzer().scan(
            root: downloads,
            context: ScanContext(homeDirectory: home, showHiddenFiles: true, snapshots: snapshots)
        )
        let item = try XCTUnwrap(provider.cleanupItem(for: try XCTUnwrap(analysis.allFiles.first), registry: snapshots))
        let engine = CleanupEngine(
            safetyValidator: SafetyValidator(homeDirectory: home, temporaryDirectory: FileManager.default.temporaryDirectory),
            snapshots: snapshots,
            trashMover: moveToTestTrash()
        )

        let result = await engine.clean([item], providers: [provider], disposition: .trash)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        let trashed = try XCTUnwrap(result.trashedItems.first)
        XCTAssertEqual(trashed.originalPath, file.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let outcome = TrashRestorer().restore(result.trashedItems)
        XCTAssertEqual(outcome.restored, ["report.pdf"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "report")
    }

    func testPermanentDeletionsAreNotRecordedForPutBack() {
        let record = CleanedItemRecord(name: "x", location: .userCaches, bytes: 1, fileCount: 1, disposition: .permanent)
        XCTAssertNil(record.trashedItem)
    }

    /// Negative: Put Back never overwrites something that now has the original name.
    func testRestoreNeverOverwritesAnExistingItem() throws {
        let original = root.appendingPathComponent("Docs/notes.txt")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new version".utf8).write(to: original)
        let trashed = trash.appendingPathComponent("notes.txt")
        try Data("old version".utf8).write(to: trashed)

        let outcome = TrashRestorer().restore([
            TrashedItem(name: "notes.txt", originalPath: original.path, trashPath: trashed.path)
        ])

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertEqual(outcome.notRestored.map(\.name), ["notes.txt"])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new version")
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "old version")
    }

    /// Negative: a recorded "Trash" location outside any Trash folder is refused, so a
    /// tampered history file can't be used to move arbitrary files.
    func testRestoreRefusesSourcesOutsideATrashFolder() throws {
        let notTrash = root.appendingPathComponent("Elsewhere/secret.txt")
        try FileManager.default.createDirectory(at: notTrash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: notTrash)
        let destination = root.appendingPathComponent("Moved/secret.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let outcome = TrashRestorer().restore([
            TrashedItem(name: "secret.txt", originalPath: destination.path, trashPath: notTrash.path)
        ])

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notTrash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRestoreRefusesWhenTheOriginalFolderIsGone() throws {
        let trashed = trash.appendingPathComponent("photo.jpg")
        try Data("jpg".utf8).write(to: trashed)
        let outcome = TrashRestorer().restore([
            TrashedItem(name: "photo.jpg", originalPath: root.appendingPathComponent("Gone/photo.jpg").path, trashPath: trashed.path)
        ])
        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testHistoryEntryKeepsTrashedItemsAndOldEntriesDecodeWithoutThem() throws {
        let item = TrashedItem(name: "a", originalPath: "/x/a", trashPath: "/x/.Trash/a")
        let entry = CleanupHistoryEntry(
            date: Date(timeIntervalSince1970: 10), bytesRecovered: 0, bytesMovedToTrash: 5,
            fileCount: 1, categories: [.downloads], failureCount: 0, trashedItems: [item]
        )
        let decoded = try JSONDecoder().decode(CleanupHistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.trashedItems, [item])

        let legacy = """
        {"id": "\(UUID().uuidString)", "date": 10, "bytesRecovered": 0, "bytesMovedToTrash": 5,
         "fileCount": 1, "categories": ["downloads"], "failureCount": 0}
        """
        XCTAssertEqual(try JSONDecoder().decode(CleanupHistoryEntry.self, from: Data(legacy.utf8)).trashedItems, [])
    }
}
