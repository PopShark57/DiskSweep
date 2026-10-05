import Foundation
import XCTest
@testable import DiskSweep

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultsAreConservative() {
        let defaults = makeUserDefaults()
        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")

        XCTAssertTrue(store.general.confirmBeforeCleanup)
        XCTAssertTrue(store.general.preferMoveToTrash)
        XCTAssertFalse(store.general.showHiddenFiles)
        XCTAssertFalse(store.general.automaticallyScanOnLaunch)
        XCTAssertFalse(store.scan.includedLocations.contains(.downloads))
        XCTAssertTrue(store.exclusions.excludeVersionControlMetadata)
        XCTAssertTrue(store.exclusions.excludeNodeModulesFromDeepScans)
        XCTAssertTrue(store.developer.isEnabled)
        XCTAssertTrue(store.privacy.keepLocalCleanupHistory)
    }

    func testSettingsAndURLExclusionsRoundTripThroughUserDefaults() {
        let defaults = makeUserDefaults()
        let key = "settings"
        let exclusion = URL(fileURLWithPath: "/Users/example/Do Not Scan")

        let firstStore = SettingsStore(userDefaults: defaults, storageKey: key)
        firstStore.general.showHiddenFiles = true
        firstStore.general.automaticallyScanOnLaunch = true
        firstStore.setScanLocation(.downloads, isEnabled: true)
        firstStore.setDeveloperLocation(.xcodeArchives, isEnabled: false)
        firstStore.addExclusion(exclusion)
        firstStore.privacy.keepLocalCleanupHistory = false

        let reloadedStore = SettingsStore(userDefaults: defaults, storageKey: key)

        XCTAssertTrue(reloadedStore.general.showHiddenFiles)
        XCTAssertTrue(reloadedStore.general.automaticallyScanOnLaunch)
        XCTAssertTrue(reloadedStore.scan.includedLocations.contains(.downloads))
        XCTAssertFalse(reloadedStore.developer.includedLocations.contains(.xcodeArchives))
        XCTAssertEqual(reloadedStore.excludedURLs, [exclusion.standardizedFileURL])
        XCTAssertFalse(reloadedStore.privacy.keepLocalCleanupHistory)
    }

    func testDuplicateExclusionsAreNotStoredTwice() {
        let store = SettingsStore(
            userDefaults: makeUserDefaults(),
            storageKey: "settings"
        )
        let url = URL(fileURLWithPath: "/tmp/example/../example")

        store.addExclusion(url)
        store.addExclusion(url.standardizedFileURL)

        XCTAssertEqual(store.excludedURLs.count, 1)
    }

    func testUserFileDispositionTracksPreferMoveToTrashSetting() {
        let store = SettingsStore(
            userDefaults: makeUserDefaults(),
            storageKey: "settings"
        )
        let model = AppViewModel(
            homeDirectory: FileManager.default.temporaryDirectory,
            settings: store,
            history: CleanupHistoryStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("DiskSweepHistory-\(UUID().uuidString).json")
            )
        )

        XCTAssertEqual(model.preferredUserFileDisposition, .trash)
        store.general.preferMoveToTrash = false
        XCTAssertEqual(model.preferredUserFileDisposition, .permanent)
    }

    func testSettingsSavedBeforeProjectFoldersStillLoad() throws {
        let defaults = makeUserDefaults()
        let legacy = """
        {
          "version": 1,
          "general": {
            "confirmBeforeCleanup": true,
            "preferMoveToTrash": true,
            "showHiddenFiles": true,
            "automaticallyScanOnLaunch": false
          },
          "scan": { "includedLocations": ["userCaches", "xcodeDerivedData"] },
          "exclusions": {
            "customURLs": [],
            "excludeVersionControlMetadata": true,
            "excludeNodeModulesFromDeepScans": true,
            "excludeCloudPlaceholders": true,
            "excludePhotoLibraries": true,
            "excludeTimeMachineBackups": true,
            "excludePackageContents": true
          },
          "developer": { "isEnabled": true, "includedLocations": ["xcodeDerivedData"] },
          "privacy": { "keepLocalCleanupHistory": true }
        }
        """
        defaults.set(Data(legacy.utf8), forKey: "settings")

        let store = SettingsStore(userDefaults: defaults, storageKey: "settings")

        XCTAssertNil(store.lastPersistenceError)
        XCTAssertTrue(store.general.showHiddenFiles)
        XCTAssertEqual(store.developer.includedLocations, [.xcodeDerivedData])
        XCTAssertTrue(store.developer.projectFolders.isEmpty)
        XCTAssertEqual(store.developer.projectIdleDays, DeveloperSettings.defaultProjectIdleDays)
        XCTAssertFalse(store.isScanLocationEnabled(.projectArtifacts))

        store.addProjectFolder(URL(fileURLWithPath: "/Users/example/Developer"))

        XCTAssertTrue(store.isScanLocationEnabled(.projectArtifacts))
        XCTAssertTrue(store.isScanLocationEnabled(.xcodeDerivedData))
        XCTAssertFalse(store.isScanLocationEnabled(.userLogs))
    }

    func testProjectFoldersRoundTripWithoutDuplicates() {
        let defaults = makeUserDefaults()
        let folder = URL(fileURLWithPath: "/Users/example/Developer")

        let firstStore = SettingsStore(userDefaults: defaults, storageKey: "settings")
        firstStore.addProjectFolder(folder)
        firstStore.addProjectFolder(URL(fileURLWithPath: "/Users/example/./Developer"))
        firstStore.developer.projectIdleDays = 180

        let reloadedStore = SettingsStore(userDefaults: defaults, storageKey: "settings")
        XCTAssertEqual(reloadedStore.developer.projectFolders, [folder.standardizedFileURL])
        XCTAssertEqual(reloadedStore.developer.projectIdleDays, 180)
        XCTAssertEqual(reloadedStore.projectIdleInterval, 180 * 86_400)

        reloadedStore.removeProjectFolder(folder)
        XCTAssertTrue(reloadedStore.developer.projectFolders.isEmpty)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}
