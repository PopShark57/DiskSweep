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
