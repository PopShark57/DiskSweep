import Foundation

enum CleanupDisposition: String, Codable, Hashable, Sendable {
    case permanent
    case trash
}

struct CleanupFailure: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let itemName: String
    let path: String
    let reason: String

    init(id: UUID = UUID(), itemName: String, path: String, reason: String) {
        self.id = id
        self.itemName = itemName
        self.path = path
        self.reason = reason
    }
}

struct CleanedItemRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let location: CleanupLocation
    let bytes: Int64
    let fileCount: Int
    let disposition: CleanupDisposition

    init(
        id: UUID = UUID(),
        name: String,
        location: CleanupLocation,
        bytes: Int64,
        fileCount: Int,
        disposition: CleanupDisposition
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.bytes = max(0, bytes)
        self.fileCount = max(0, fileCount)
        self.disposition = disposition
    }
}

struct CleanupResult: Codable, Hashable, Sendable {
    let startedAt: Date
    let finishedAt: Date
    /// Free space including purgeable space, as shown to the user.
    let availableBefore: Int64
    let availableAfter: Int64
    /// Free space excluding purgeable space, used to measure what the cleanup freed.
    /// `nil` when not measured; the values above are used instead.
    let availableBeforeExcludingPurgeable: Int64?
    let availableAfterExcludingPurgeable: Int64?
    let cleanedItems: [CleanedItemRecord]
    let failures: [CleanupFailure]

    init(
        startedAt: Date,
        finishedAt: Date,
        availableBefore: Int64,
        availableAfter: Int64,
        availableBeforeExcludingPurgeable: Int64? = nil,
        availableAfterExcludingPurgeable: Int64? = nil,
        cleanedItems: [CleanedItemRecord],
        failures: [CleanupFailure]
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.availableBefore = availableBefore
        self.availableAfter = availableAfter
        self.availableBeforeExcludingPurgeable = availableBeforeExcludingPurgeable
        self.availableAfterExcludingPurgeable = availableAfterExcludingPurgeable
        self.cleanedItems = cleanedItems
        self.failures = failures
    }

    var reportedBytesRemoved: Int64 {
        cleanedItems.reduce(0) { $0 + $1.bytes }
    }

    var reportedBytesPermanentlyRemoved: Int64 {
        cleanedItems
            .filter { $0.disposition == .permanent }
            .reduce(0) { $0 + $1.bytes }
    }

    var reportedBytesMovedToTrash: Int64 {
        cleanedItems
            .filter { $0.disposition == .trash }
            .reduce(0) { $0 + $1.bytes }
    }

    /// An estimate: the change in free space excluding purgeable space when it was measured,
    /// which background activity can still nudge. History entries recorded before this
    /// measurement changed (6.4) used the value that includes purgeable space, so old and new
    /// entries aren't strictly comparable.
    var measuredBytesRecovered: Int64 {
        if let before = availableBeforeExcludingPurgeable,
           let after = availableAfterExcludingPurgeable {
            return max(0, after - before)
        }
        return max(0, availableAfter - availableBefore)
    }

    /// True when much less space was measured than was permanently removed, which usually
    /// means local snapshots still hold the blocks or the volume is still freeing them.
    var measuredRecoveryLooksLow: Bool {
        let removed = reportedBytesPermanentlyRemoved
        return removed > 0 && measuredBytesRecovered * 2 < removed
    }

    /// A conservative presentation value. Moving an item to same-volume Trash does not
    /// reclaim capacity, so only a measured increase or permanently removed bytes count.
    var creditedBytesRecovered: Int64 {
        measuredBytesRecovered > 0
            ? measuredBytesRecovered
            : reportedBytesPermanentlyRemoved
    }

    var fileCount: Int {
        cleanedItems.reduce(0) { $0 + $1.fileCount }
    }
}

struct CleanupHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let bytesRecovered: Int64
    let bytesMovedToTrash: Int64
    let fileCount: Int
    let categories: [CleanupLocation]
    let failureCount: Int

    init(
        id: UUID = UUID(),
        date: Date,
        bytesRecovered: Int64,
        bytesMovedToTrash: Int64 = 0,
        fileCount: Int,
        categories: [CleanupLocation],
        failureCount: Int
    ) {
        self.id = id
        self.date = date
        self.bytesRecovered = max(0, bytesRecovered)
        self.bytesMovedToTrash = max(0, bytesMovedToTrash)
        self.fileCount = max(0, fileCount)
        self.categories = categories
        self.failureCount = max(0, failureCount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case bytesRecovered
        case bytesMovedToTrash
        case fileCount
        case categories
        case failureCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        let legacyRecovered = max(0, try container.decode(Int64.self, forKey: .bytesRecovered))
        fileCount = max(0, try container.decode(Int.self, forKey: .fileCount))
        categories = try container.decodeLossyLocations(forKey: .categories)
        failureCount = max(0, try container.decode(Int.self, forKey: .failureCount))

        if let recordedTrashBytes = try container.decodeIfPresent(
            Int64.self,
            forKey: .bytesMovedToTrash
        ) {
            bytesRecovered = legacyRecovered
            bytesMovedToTrash = max(0, recordedTrashBytes)
        } else if categories.contains(.downloads) {
            // Version 1 history could credit a same-volume Downloads-to-Trash move as
            // recovered space. The old schema cannot distinguish mixed dispositions, so
            // migrate conservatively and never preserve a possibly inflated recovery claim.
            bytesRecovered = 0
            bytesMovedToTrash = legacyRecovered
        } else {
            bytesRecovered = legacyRecovered
            bytesMovedToTrash = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(bytesRecovered, forKey: .bytesRecovered)
        try container.encode(bytesMovedToTrash, forKey: .bytesMovedToTrash)
        try container.encode(fileCount, forKey: .fileCount)
        try container.encode(categories, forKey: .categories)
        try container.encode(failureCount, forKey: .failureCount)
    }
}
