import Foundation

/// The items a Review button covers: exactly what its screen's footer counted.
enum CleanupScope: Hashable, Sendable {
    /// Selected items from scan categories in these locations.
    case locations(Set<CleanupLocation>)
    /// Selected Downloads files that the Downloads filters and search currently show.
    case downloads

    static let applicationCacheLocations: Set<CleanupLocation> = [
        .userCaches, .applicationCaches, .browserCaches, .electronAppCaches
    ]

    static let developerLocations = Set(CleanupLocation.allCases.filter(\.isDeveloperCategory))

    static let allScanLocations = Set(CleanupLocation.allCases.filter { $0 != .downloads })
}
