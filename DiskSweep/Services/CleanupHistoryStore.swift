import Foundation
import Observation

enum CleanupHistoryStoreError: Error, LocalizedError, Sendable {
    case readOnly

    var errorDescription: String? {
        "Cleanup history is read-only because an unreadable history file couldn't be set aside. DiskSweep won't overwrite it."
    }
}

/// A bounded, local-only cleanup history persisted under Application Support.
@MainActor
@Observable
final class CleanupHistoryStore {
    static let defaultMaximumEntries = 100

    private(set) var entries: [CleanupHistoryEntry] = []
    private(set) var lastPersistenceError: String?
    /// Set when the history file couldn't be read and couldn't be moved aside either. Nothing
    /// is written in this state, so the original file is never overwritten.
    private(set) var isReadOnly = false
    /// Where an unreadable history file was moved, if that happened at launch.
    private(set) var unreadableFileBackupURL: URL?

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

    /// Removes the history file itself, for example when the person turns history off.
    /// Files set aside as unreadable are left alone.
    func deleteHistoryFile() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                lastPersistenceError = "Cleanup history could not be deleted: \(error.localizedDescription)"
                throw error
            }
        }
        entries = []
        isReadOnly = false
        lastPersistenceError = nil
    }

    var hasHistoryFile: Bool { fileManager.fileExists(atPath: fileURL.path) }

    func reload() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = []
            lastPersistenceError = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            // Entries are decoded one by one, so a single damaged entry is dropped instead of
            // the whole history.
            entries = try JSONDecoder()
                .decode([LossyDecodable<CleanupHistoryEntry>].self, from: data)
                .compactMap(\.value)
            normalizeEntries()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Cleanup history could not be read: \(error.localizedDescription)"
            Log.persistence.error(
                "Cleanup history could not be read: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private func loadWithoutThrowing() {
        do {
            try reload()
        } catch {
            entries = []
            setAsideUnreadableFile()
        }
    }

    /// Moves an unreadable history file next to itself before anything can be written over
    /// it. If that fails, the store becomes read-only.
    private func setAsideUnreadableFile() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(
            "cleanup-history.unreadable-\(timestamp).json",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: fileURL, to: backup)
            unreadableFileBackupURL = backup
            lastPersistenceError = "Cleanup history couldn't be read, so DiskSweep started a new history. The unreadable file was kept as \(backup.lastPathComponent)."
            Log.persistence.error(
                "Moved unreadable cleanup history aside to \(backup.path, privacy: .private)"
            )
        } catch {
            isReadOnly = true
            lastPersistenceError = "Cleanup history couldn't be read or set aside, so DiskSweep won't record new cleanups until it can. \(error.localizedDescription)"
            Log.persistence.error(
                "Cleanup history is read-only: \(error.localizedDescription, privacy: .private)"
            )
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
        guard !isReadOnly else {
            throw CleanupHistoryStoreError.readOnly
        }
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
            Log.persistence.error(
                "Cleanup history could not be saved: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }
}
