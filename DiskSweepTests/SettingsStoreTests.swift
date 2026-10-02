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

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }
}
