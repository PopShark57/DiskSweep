import Foundation
import Observation

/// A bounded, local-only cleanup history persisted under Application Support.
@MainActor
@Observable
final class CleanupHistoryStore {
    static let defaultMaximumEntries = 100

    private(set) var entries: [CleanupHistoryEntry] = []
    private(set) var lastPersistenceError: String?

    let fileURL: URL
    let maximumEntries: Int

    @ObservationIgnored private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEntries: Int = CleanupHistoryStore.defaultMaximumEntries
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.maximumEntries = max(1, maximumEntries)
        loadWithoutThrowing()
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("DiskSweep", isDirectory: true)
            .appendingPathComponent("cleanup-history.json", isDirectory: false)
    }

    @discardableResult
    func record(_ result: CleanupResult) throws -> CleanupHistoryEntry {
        var seenLocations = Set<CleanupLocation>()
        let categories = result.cleanedItems.compactMap { item -> CleanupLocation? in
            seenLocations.insert(item.location).inserted ? item.location : nil
        }

        let entry = CleanupHistoryEntry(
            date: result.finishedAt,
            bytesRecovered: result.creditedBytesRecovered,
            bytesMovedToTrash: result.reportedBytesMovedToTrash,
            fileCount: result.fileCount,
            categories: categories,
            failureCount: result.failures.count
        )

        try add(entry)
        return entry
    }

    func add(_ entry: CleanupHistoryEntry) throws {
        let previousEntries = entries
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        normalizeEntries()

        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    func remove(id: CleanupHistoryEntry.ID) throws {
        let previousEntries = entries
        entries.removeAll { $0.id == id }
        guard entries != previousEntries else { return }

        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    func clear() throws {
        let previousEntries = entries
        entries = []

        do {
            try persist()
        } catch {
            entries = previousEntries
            throw error
        }
    }

    func reload() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = []
            lastPersistenceError = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([CleanupHistoryEntry].self, from: data)
            normalizeEntries()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Cleanup history could not be read: \(error.localizedDescription)"
            throw error
        }
    }

    private func loadWithoutThrowing() {
        do {
            try reload()
        } catch {
            entries = []
        }
    }

    private func normalizeEntries() {
        entries.sort { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.date > rhs.date
        }

        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Cleanup history could not be saved: \(error.localizedDescription)"
            throw error
        }
    }
}
