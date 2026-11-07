import Foundation
import UserNotifications

/// Decides when to warn about low free space: once each time free space falls below the
/// threshold, not again until it has gone back above it.
struct LowSpaceMonitor: Sendable {
    /// How often the menu bar extra and the low-space check refresh disk statistics.
    static let pollInterval: Duration = .seconds(15 * 60)

    private(set) var isBelowThreshold = false

    /// Returns true when a notification should be posted for this reading.
    mutating func shouldNotify(available: Int64, thresholdBytes: Int64) -> Bool {
        guard available > 0, thresholdBytes > 0 else { return false }
        let isBelow = available < thresholdBytes
        defer { isBelowThreshold = isBelow }
        return isBelow && !isBelowThreshold
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    static func postLowSpaceNotification(available: Int64, volumeName: String) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Low disk space")
        content.body = String(localized: "\(volumeName) has \(FileSizeFormatter.string(fromByteCount: available)) free. Open DiskSweep to find space to reclaim.")
        let request = UNNotificationRequest(
            identifier: "com.disksweep.low-space",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
