import Foundation
import XCTest
@testable import DiskSweep

@MainActor
final class CleanupHistoryStoreTests: XCTestCase {
    func testEntriesPersistAsJSONAndReloadNewestFirst() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let older = makeEntry(date: Date(timeIntervalSince1970: 100), bytes: 10)
        let newer = makeEntry(date: Date(timeIntervalSince1970: 200), bytes: 20)

        let firstStore = CleanupHistoryStore(fileURL: fileURL)
        try firstStore.add(older)
        try firstStore.add(newer)

        let rawJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        XCTAssertTrue(rawJSON is [Any])

        let reloadedStore = CleanupHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloadedStore.entries.map(\.id), [newer.id, older.id])
    }

    func testHistoryIsCappedToConfiguredMaximum() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleanupHistoryStore(
            fileURL: directory.appendingPathComponent("history.json"),
            maximumEntries: 2
        )

        try store.add(makeEntry(date: Date(timeIntervalSince1970: 100), bytes: 1))
        let middle = makeEntry(date: Date(timeIntervalSince1970: 200), bytes: 2)
        let newest = makeEntry(date: Date(timeIntervalSince1970: 300), bytes: 3)
        try store.add(middle)
        try store.add(newest)

        XCTAssertEqual(store.entries.map(\.id), [newest.id, middle.id])
    }

    func testCleanupResultCreatesAHistoryEntry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleanupHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        let result = CleanupResult(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            availableBefore: 1_000,
            availableAfter: 1_300,
            cleanedItems: [
                CleanedItemRecord(
                    name: "Cache A",
                    location: .userCaches,
                    bytes: 200,
                    fileCount: 2,
                    disposition: .permanent
                ),
                CleanedItemRecord(
                    name: "Cache B",
                    location: .userCaches,
                    bytes: 100,
                    fileCount: 1,
                    disposition: .permanent
                )
            ],
            failures: [CleanupFailure(itemName: "Busy", path: "/tmp/busy", reason: "In use")]
        )

        let entry = try store.record(result)

        XCTAssertEqual(entry.date, result.finishedAt)
        XCTAssertEqual(entry.bytesRecovered, 300)
        XCTAssertEqual(entry.bytesMovedToTrash, 0)
        XCTAssertEqual(entry.fileCount, 3)
        XCTAssertEqual(entry.categories, [.userCaches])
        XCTAssertEqual(entry.failureCount, 1)
        XCTAssertEqual(store.entries, [entry])
    }

    func testTrashMoveIsNotReportedAsRecoveredCapacity() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CleanupHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        let result = CleanupResult(
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            availableBefore: 1_000,
            availableAfter: 1_000,
            cleanedItems: [
                CleanedItemRecord(
                    name: "Download",
                    location: .downloads,
                    bytes: 400,
                    fileCount: 1,
                    disposition: .trash
                )
            ],
            failures: []
        )

        let entry = try store.record(result)

        XCTAssertEqual(result.creditedBytesRecovered, 0)
        XCTAssertEqual(entry.bytesRecovered, 0)
        XCTAssertEqual(entry.bytesMovedToTrash, 400)
    }

    func testLegacyDownloadsHistoryMigratesConservatively() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let legacy = LegacyHistoryEntry(
            id: UUID(),
            date: Date(timeIntervalSince1970: 200),
            bytesRecovered: 750,
            fileCount: 1,
            categories: [.downloads],
            failureCount: 0
        )
        try JSONEncoder().encode([legacy]).write(to: fileURL, options: .atomic)

        let store = CleanupHistoryStore(fileURL: fileURL)
        let migrated = try XCTUnwrap(store.entries.first)

        XCTAssertEqual(migrated.bytesRecovered, 0)
        XCTAssertEqual(migrated.bytesMovedToTrash, 750)
    }

    func testFailedWriteRollsBackInMemoryMutation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let store = CleanupHistoryStore(
            fileURL: blocker.appendingPathComponent("history.json")
        )

        XCTAssertThrowsError(try store.add(makeEntry(date: Date(), bytes: 1)))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.lastPersistenceError)
    }

    // MARK: - History management (F8)

    func testEntriesCanBeDeletedClearedAndTheFileRemoved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let backup = directory.appendingPathComponent("cleanup-history.unreadable-old.json")
        try Data("keep".utf8).write(to: backup)
        let store = CleanupHistoryStore(fileURL: fileURL)
        let first = makeEntry(date: Date(timeIntervalSince1970: 100), bytes: 1)
        let second = makeEntry(date: Date(timeIntervalSince1970: 200), bytes: 2)
        try store.add(first)
        try store.add(second)

        try store.remove(id: first.id)
        XCTAssertEqual(CleanupHistoryStore(fileURL: fileURL).entries.map(\.id), [second.id])

        try store.clear()
        XCTAssertTrue(CleanupHistoryStore(fileURL: fileURL).entries.isEmpty)
        XCTAssertTrue(store.hasHistoryFile)

        try store.deleteHistoryFile()
        XCTAssertFalse(store.hasHistoryFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "Set-aside files are left alone")
    }

    // MARK: - Recovered-space measurement (L3)

    func testMeasuredRecoveryPrefersValuesWithoutPurgeableSpace() {
        let record = CleanedItemRecord(name: "Cache", location: .userCaches, bytes: 1_000, fileCount: 1, disposition: .permanent)
        let result = CleanupResult(
            startedAt: Date(), finishedAt: Date(),
            availableBefore: 10_000, availableAfter: 30_000,
            availableBeforeExcludingPurgeable: 5_000, availableAfterExcludingPurgeable: 5_900,
            cleanedItems: [record], failures: []
        )
        XCTAssertEqual(result.measuredBytesRecovered, 900)
        XCTAssertEqual(result.creditedBytesRecovered, 900)
        XCTAssertFalse(result.measuredRecoveryLooksLow)

        let legacy = CleanupResult(
            startedAt: Date(), finishedAt: Date(),
            availableBefore: 10_000, availableAfter: 10_400,
            cleanedItems: [record], failures: []
        )
        XCTAssertEqual(legacy.measuredBytesRecovered, 400)
        XCTAssertTrue(legacy.measuredRecoveryLooksLow, "400 of 1,000 bytes is less than half")
    }

    func testNoMeasuredChangeFallsBackToRemovedBytesAndFlagsIt() {
        let record = CleanedItemRecord(name: "Cache", location: .userCaches, bytes: 2_000, fileCount: 1, disposition: .permanent)
        let result = CleanupResult(
            startedAt: Date(), finishedAt: Date(),
            availableBefore: 1_000, availableAfter: 1_000,
            availableBeforeExcludingPurgeable: 800, availableAfterExcludingPurgeable: 700,
            cleanedItems: [record], failures: []
        )
        XCTAssertEqual(result.measuredBytesRecovered, 0)
        XCTAssertEqual(result.creditedBytesRecovered, 2_000)
        XCTAssertTrue(result.measuredRecoveryLooksLow)
    }

    // MARK: - Tolerant, non-destructive loading (D5)

    func testUnknownCategoryAndDamagedEntryAreDroppedButValidEntriesLoad() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let validID = UUID()
        let mixedID = UUID()
        let json = """
        [
          {"id": "\(validID.uuidString)", "date": 100, "bytesRecovered": 10,
           "bytesMovedToTrash": 0, "fileCount": 1, "categories": ["userCaches"], "failureCount": 0},
          {"id": "\(mixedID.uuidString)", "date": 200, "bytesRecovered": 20,
           "bytesMovedToTrash": 0, "fileCount": 2,
           "categories": ["userLogs", "categoryFromTheFuture"], "failureCount": 0},
          {"id": "not-a-uuid", "date": "yesterday"}
        ]
        """
        try Data(json.utf8).write(to: fileURL)

        let store = CleanupHistoryStore(fileURL: fileURL)

        XCTAssertNil(store.lastPersistenceError)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(Set(store.entries.map(\.id)), [validID, mixedID])
        XCTAssertEqual(store.entries.first { $0.id == mixedID }?.categories, [.userLogs])
    }

    func testInvalidJSONIsSetAsideBeforeAnyWrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("cleanup-history.json")
        let original = Data("{ this is not JSON".utf8)
        try original.write(to: fileURL)

        let store = CleanupHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertNotNil(store.lastPersistenceError)
        let backup = try XCTUnwrap(store.unreadableFileBackupURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("cleanup-history.unreadable-"))
        XCTAssertEqual(try Data(contentsOf: backup), original)

        try store.add(makeEntry(date: Date(), bytes: 5))
        XCTAssertEqual(try Data(contentsOf: backup), original, "The backup must keep the original bytes")
        XCTAssertEqual(CleanupHistoryStore(fileURL: fileURL).entries.count, 1)
    }

    func testUnreadableFileThatCannotBeSetAsideMakesStoreReadOnly() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("cleanup-history.json")
        let original = Data("garbage".utf8)
        try original.write(to: fileURL)
        // A read-only folder: the file can't be renamed or replaced.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let store = CleanupHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertThrowsError(try store.add(makeEntry(date: Date(), bytes: 5)))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    private func makeEntry(date: Date, bytes: Int64) -> CleanupHistoryEntry {
        CleanupHistoryEntry(
            date: date,
            bytesRecovered: bytes,
            fileCount: 1,
            categories: [.userCaches],
            failureCount: 0
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private struct LegacyHistoryEntry: Encodable {
        let id: UUID
        let date: Date
        let bytesRecovered: Int64
        let fileCount: Int
        let categories: [CleanupLocation]
        let failureCount: Int
    }
}
