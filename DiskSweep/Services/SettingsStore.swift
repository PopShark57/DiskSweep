import Foundation
import Observation

struct GeneralSettings: Codable, Hashable, Sendable {
    var confirmBeforeCleanup: Bool
    var preferMoveToTrash: Bool
    var showHiddenFiles: Bool
    var automaticallyScanOnLaunch: Bool

    static let defaults = GeneralSettings(
        confirmBeforeCleanup: true,
        preferMoveToTrash: true,
        showHiddenFiles: false,
        automaticallyScanOnLaunch: false
    )
}

struct ScanSettings: Codable, Hashable, Sendable {
    var includedLocations: Set<CleanupLocation>

    static let defaults = ScanSettings(
        includedLocations: Set(CleanupLocation.allCases.filter { $0 != .downloads })
    )
}

struct ExclusionSettings: Codable, Hashable, Sendable {
    var customURLs: [URL]
    var excludeVersionControlMetadata: Bool
    var excludeNodeModulesFromDeepScans: Bool
    var excludeCloudPlaceholders: Bool
    var excludePhotoLibraries: Bool
    var excludeTimeMachineBackups: Bool
    var excludePackageContents: Bool

    static let defaults = ExclusionSettings(
        customURLs: [],
        excludeVersionControlMetadata: true,
        excludeNodeModulesFromDeepScans: true,
        excludeCloudPlaceholders: true,
        excludePhotoLibraries: true,
        excludeTimeMachineBackups: true,
        excludePackageContents: true
    )

    static let defaultExcludedDirectoryNames: Set<String> = [
        ".git",
        ".svn",
        "node_modules"
    ]
}

struct DeveloperSettings: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var includedLocations: Set<CleanupLocation>

    static let defaults = DeveloperSettings(
        isEnabled: true,
        includedLocations: Set(CleanupLocation.allCases.filter(\.isDeveloperCategory))
    )
}

struct PrivacySettings: Codable, Hashable, Sendable {
    /// Cleanup history is a local JSON file. DiskSweep never syncs it or sends it over a network.
    var keepLocalCleanupHistory: Bool

    static let defaults = PrivacySettings(keepLocalCleanupHistory: true)

    static let localOnlyNotice =
        "DiskSweep analyzes files locally on your Mac. File names, paths, contents, and cleanup history are never uploaded anywhere."
}

/// Observable application preferences, persisted as one versioned value in `UserDefaults`.
///
/// Keeping the settings in one Codable snapshot makes URL exclusions portable across launches
/// without scattering path strings across unrelated defaults keys.
@MainActor
@Observable
final class SettingsStore {
    static let defaultStorageKey = "com.disksweep.settings.v1"

    var general: GeneralSettings {
        didSet { saveUnlessRestoring() }
    }

    var scan: ScanSettings {
        didSet { saveUnlessRestoring() }
    }

    var exclusions: ExclusionSettings {
        didSet { saveUnlessRestoring() }
    }

    var developer: DeveloperSettings {
        didSet { saveUnlessRestoring() }
    }

    var privacy: PrivacySettings {
        didSet { saveUnlessRestoring() }
    }

    private(set) var lastPersistenceError: String?

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private var isRestoring = false

    private struct Snapshot: Codable {
        let version: Int
        var general: GeneralSettings
        var scan: ScanSettings
        var exclusions: ExclusionSettings
        var developer: DeveloperSettings
        var privacy: PrivacySettings

        static let defaults = Snapshot(
            version: 1,
            general: .defaults,
            scan: .defaults,
            exclusions: .defaults,
            developer: .defaults,
            privacy: .defaults
        )
    }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = SettingsStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        let loaded: Snapshot
        if let data = userDefaults.data(forKey: storageKey) {
            do {
                loaded = try JSONDecoder().decode(Snapshot.self, from: data)
                lastPersistenceError = nil
            } catch {
                loaded = .defaults
                lastPersistenceError = "Settings could not be read and defaults were restored: \(error.localizedDescription)"
            }
        } else {
            loaded = .defaults
            lastPersistenceError = nil
        }

        general = loaded.general
        scan = loaded.scan
        exclusions = loaded.exclusions
        developer = loaded.developer
        privacy = loaded.privacy
    }

    var effectiveScanLocations: Set<CleanupLocation> {
        scan.includedLocations.filter { location in
            !location.isDeveloperCategory
                || (developer.isEnabled && developer.includedLocations.contains(location))
        }
    }

    var excludedURLs: [URL] { exclusions.customURLs }

    func isScanLocationEnabled(_ location: CleanupLocation) -> Bool {
        effectiveScanLocations.contains(location)
    }

    func setScanLocation(_ location: CleanupLocation, isEnabled: Bool) {
        if isEnabled {
            scan.includedLocations.insert(location)
        } else {
            scan.includedLocations.remove(location)
        }
    }

    func setDeveloperLocation(_ location: CleanupLocation, isEnabled: Bool) {
        guard location.isDeveloperCategory else { return }

        if isEnabled {
            developer.includedLocations.insert(location)
        } else {
            developer.includedLocations.remove(location)
        }
    }

    func addExclusion(_ url: URL) {
        guard url.isFileURL else { return }

        let standardizedURL = url.standardizedFileURL
        guard !exclusions.customURLs.contains(where: {
            $0.standardizedFileURL.path == standardizedURL.path
        }) else {
            return
        }

        exclusions.customURLs.append(standardizedURL)
    }

    func removeExclusion(_ url: URL) {
        let path = url.standardizedFileURL.path
        exclusions.customURLs.removeAll { $0.standardizedFileURL.path == path }
    }

    func resetToDefaults() {
        restore(.defaults)
        userDefaults.removeObject(forKey: storageKey)
        lastPersistenceError = nil
    }

    func reload() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            restore(.defaults)
            lastPersistenceError = nil
            return
        }

        do {
            restore(try JSONDecoder().decode(Snapshot.self, from: data))
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Settings could not be reloaded: \(error.localizedDescription)"
        }
    }

    private func restore(_ snapshot: Snapshot) {
        isRestoring = true
        general = snapshot.general
        scan = snapshot.scan
        exclusions = snapshot.exclusions
        developer = snapshot.developer
        privacy = snapshot.privacy
        isRestoring = false
    }

    private func saveUnlessRestoring() {
        guard !isRestoring else { return }

        let snapshot = Snapshot(
            version: 1,
            general: general,
            scan: scan,
            exclusions: exclusions,
            developer: developer,
            privacy: privacy
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            userDefaults.set(try encoder.encode(snapshot), forKey: storageKey)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Settings could not be saved: \(error.localizedDescription)"
        }
    }
}
