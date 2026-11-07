import Foundation

struct DiskStatistics: Codable, Hashable, Sendable {
    let volumeName: String
    let mountURL: URL
    let capacity: Int64
    let used: Int64
    let available: Int64
    var reclaimable: Int64
    /// Free space without purgeable space (`volumeAvailableCapacityKey`). The system can
    /// reclaim purgeable space at any moment, so this is the steadier value for measuring
    /// what a cleanup freed. `available` (which includes purgeable space) stays the
    /// user-facing figure.
    let availableExcludingPurgeable: Int64

    init(
        volumeName: String,
        mountURL: URL,
        capacity: Int64,
        used: Int64,
        available: Int64,
        reclaimable: Int64,
        availableExcludingPurgeable: Int64? = nil
    ) {
        self.volumeName = volumeName
        self.mountURL = mountURL
        self.capacity = capacity
        self.used = used
        self.available = available
        self.reclaimable = reclaimable
        self.availableExcludingPurgeable = availableExcludingPurgeable ?? available
    }

    static let unavailable = DiskStatistics(
        volumeName: "Macintosh HD",
        mountURL: URL(fileURLWithPath: "/"),
        capacity: 0,
        used: 0,
        available: 0,
        reclaimable: 0
    )

    var usedFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(capacity)))
    }

    var reclaimableFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(reclaimable) / Double(capacity)))
    }
}

