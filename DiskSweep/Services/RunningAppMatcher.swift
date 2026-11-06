import AppKit
import Foundation
import SwiftUI

/// An app that is running now.
struct RunningApp: Hashable, Sendable {
    let bundleID: String
    let name: String
}

/// Finds cache items that probably belong to an app that is running now. Cleaning an active
/// cache is safe but the app may recreate it at once, so such items are deselected and
/// marked "In use". Matching is by name, so it only ever warns and never blocks cleanup.
enum RunningAppMatcher {
    static let cacheLocations: Set<CleanupLocation> = [
        .userCaches, .applicationCaches, .browserCaches, .electronAppCaches
    ]

    /// Item ID → the name of the running app it appears to belong to.
    static func inUseItems(
        in categories: [CleanupCategory],
        running: [RunningApp]
    ) -> [UUID: String] {
        guard !running.isEmpty else { return [:] }
        let byBundleID = Dictionary(
            running.map { ($0.bundleID.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let byName = Dictionary(
            running.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [UUID: String] = [:]
        for category in categories where cacheLocations.contains(category.location) {
            for item in category.items {
                let components = item.url.standardizedFileURL.pathComponents.map { $0.lowercased() }
                if let name = components.lazy.compactMap({ byBundleID[$0] }).first {
                    result[item.id] = name
                } else if category.location == .electronAppCaches || category.location == .browserCaches,
                          let name = components.lazy.compactMap({ byName[$0] }).first {
                    result[item.id] = name
                }
            }
        }
        return result
    }

    @MainActor
    static func systemRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }
}

extension EnvironmentValues {
    /// Cache items that appear to belong to a running app, keyed by item ID.
    @Entry var inUseItemNames: [UUID: String] = [:]
}
