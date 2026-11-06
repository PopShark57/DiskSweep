import Foundation
import XCTest
@testable import DiskSweep

@MainActor
final class AppViewModelTests: XCTestCase {
    private var sandbox: URL!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defaultsSuiteName = "DiskSweepTests-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        if let defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    func testScanWithFakeProvidersBuildsCategoriesAndPreselectsSafeItems() async {
        let model = makeModel(providers: [
            FakeCleanupProvider(
                id: "fake-caches",
                location: .userCaches,
                items: [.init(name: "a.cache", size: 100), .init(name: "b.cache", size: 50)]
            ),
            FakeCleanupProvider(
                id: "fake-archives",
                location: .xcodeArchives,
                items: [.init(name: "App.xcarchive", size: 1_000)]
            )
        ])

        model.startCleanupScan()
        await model.waitForScan()

        XCTAssertEqual(model.categories.count, 2)
        XCTAssertEqual(model.categories.map(\.location), [.userCaches, .xcodeArchives])
        let safeIDs = Set(model.categories[0].items.map(\.id))
        XCTAssertEqual(model.selectedCleanupItemIDs, safeIDs, "Only .safe items are preselected")
        XCTAssertFalse(model.isCleanupScanning)
        XCTAssertNil(model.cleanupScanProgress)
        XCTAssertFalse(model.lastScanWasCancelled)
        XCTAssertNotNil(model.lastScanDate)
    }

    // MARK: - Helpers

    func makeModel(
        providers: [any CleanupProvider],
        configure: (SettingsStore) -> Void = { _ in }
    ) -> AppViewModel {
        let settings = SettingsStore(userDefaults: UserDefaults(suiteName: defaultsSuiteName)!)
        // Project folders are added by Settings, never by these tests.
        settings.setDeveloperLocation(.projectArtifacts, isEnabled: false)
        configure(settings)
        let home = sandbox.appendingPathComponent("Home", isDirectory: true)
        let snapshots = CleanupSnapshotRegistry()
        return AppViewModel(
            homeDirectory: home,
            temporaryDirectory: sandbox,
            standardProviders: providers,
            settings: settings,
            history: CleanupHistoryStore(
                fileURL: sandbox.appendingPathComponent("history.json")
            ),
            permissions: PermissionManager(homeDirectory: home),
            snapshots: snapshots,
            cleanupEngine: CleanupEngine(
                safetyValidator: SafetyValidator(homeDirectory: home, temporaryDirectory: sandbox),
                snapshots: snapshots
            )
        )
    }
}
