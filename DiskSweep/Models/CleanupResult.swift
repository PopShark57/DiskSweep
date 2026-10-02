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
    let availableBefore: Int64
    let availableAfter: Int64
    let cleanedItems: [CleanedItemRecord]
    let failures: [CleanupFailure]

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

    var measuredBytesRecovered: Int64 {
        max(0, availableAfter - availableBefore)
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
        categories = try container.decode([CleanupLocation].self, forKey: .categories)
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
