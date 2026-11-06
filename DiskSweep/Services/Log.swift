import Foundation
import os

/// Unified logging categories. Paths are always logged with `privacy: .private`, so they are
/// redacted in sysdiagnose and in `log stream` unless a debugger is attached. Reasons,
/// categories, and counts are `.public`. File contents are never logged.
enum Log {
    static let subsystem = "com.disksweep.DiskSweep"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let performance = Logger(subsystem: subsystem, category: "perf")
    /// Intervals for Instruments' Points of Interest / os_signpost tracks: provider scans,
    /// analyses and their stages, and pre-delete validation.
    static let signposter = OSSignposter(logger: performance)

    /// A provider refused one of its approved roots before scanning it.
    static func rootRefused(_ root: URL, location: CleanupLocation, error: Error) {
        scan.error(
            "Refused \(location.rawValue, privacy: .public) root \(root.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
        )
    }

    /// The cleanup engine did not remove an item.
    static func cleanupRefused(_ item: CleanupItem, reason: String) {
        cleanup.error(
            "Did not clean \(item.location.rawValue, privacy: .public) item \(item.url.path, privacy: .private): \(reason, privacy: .private)"
        )
    }
}
