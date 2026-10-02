import Foundation

struct DiskStatistics: Codable, Hashable, Sendable {
    let volumeName: String
    let mountURL: URL
    let capacity: Int64
    let used: Int64
    let available: Int64
    var reclaimable: Int64

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

