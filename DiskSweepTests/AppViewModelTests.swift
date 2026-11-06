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

    // MARK: - Scan and analysis lifecycle (D2, D8)

    func testCancelThenRescanKeepsNewScanStateUntilItFinishes() async {
        let events = FakeProviderEvents()
        let model = makeModel(providers: [
            FakeCleanupProvider(
                id: "slow",
                location: .userCaches,
                items: [.init(name: "a.cache", size: 10)],
                delay: .milliseconds(300),
                ignoresCancellation: true,
                events: events
            ),
            FakeCleanupProvider(
                id: "fast",
                location: .userLogs,
                items: [.init(name: "old.log", size: 5)],
                events: events
            )
        ])

        model.startCleanupScan()
        await events.wait(for: "start:slow")
        model.cancelCleanupScan()
        XCTAssertFalse(model.isCleanupScanning)
        XCTAssertTrue(model.lastScanWasCancelled)

        model.startCleanupScan()
        XCTAssertTrue(model.isCleanupScanning)
        XCTAssertNotNil(model.cleanupScanProgress)

        // The cancelled scan's provider finishes now. Its task must not clear the new scan.
        await events.wait(for: "finish:slow")
        await Task.yield()
        XCTAssertTrue(model.isCleanupScanning, "The old task cleared the new scan's handle")
        XCTAssertNotNil(model.cleanupScanProgress, "The old task cleared the new scan's progress")

        await model.waitForScan()
        XCTAssertFalse(model.isCleanupScanning)
        XCTAssertNil(model.cleanupScanProgress)
        XCTAssertEqual(model.categories.map(\.location), [.userCaches, .userLogs])
        XCTAssertEqual(Set(model.categories.map(\.location)).count, model.categories.count)
        XCTAssertFalse(model.lastScanWasCancelled)
        let startCount = await events.log.filter { $0 == "start:slow" }.count
        XCTAssertEqual(startCount, 2)
    }

    func testCancelWhileIdleDoesNotMarkCompletedScanPartial() async {
        let model = makeModel(providers: [
            FakeCleanupProvider(id: "a", location: .userCaches, items: [.init(name: "a", size: 1)])
        ])
        model.startCleanupScan()
        await model.waitForScan()
        XCTAssertFalse(model.lastScanWasCancelled)

        model.cancelCleanupScan()
        XCTAssertFalse(model.lastScanWasCancelled)
        XCTAssertEqual(model.categories.count, 1)
    }

    func testReplacedAnalysisNeverPublishesOrClearsTheNewOne() async {
        let model = makeModel(providers: [])
        let events = FakeProviderEvents()
        let gate = TestGate()
        var published: [String] = []

        model.beginAnalysis(.downloads) { _, _ in
            // Ignores cancellation, like an analyzer stuck in one filesystem call.
            await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value
            await events.finished("A")
            return { published.append("A") }
        }
        model.beginAnalysis(.largeFiles) { _, _ in
            await gate.wait()
            return { published.append("B") }
        }

        await events.wait(for: "finish:A")
        await Task.yield()
        XCTAssertEqual(model.analysisActivity, .largeFiles)
        XCTAssertNotNil(model.analysisProgress)

        await gate.open()
        await model.waitForAnalysis()
        XCTAssertEqual(published, ["B"])
        XCTAssertNil(model.analysisActivity)
        XCTAssertNil(model.analysisProgress)
    }

    // MARK: - Downloads bridge (D10)

    func testReadingSelectedDownloadsHasNoSideEffects() async throws {
        let home = sandbox.appendingPathComponent("Home", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in ["a.dmg", "b.zip", "c.pkg"] {
            try Data(repeating: 1, count: 64).write(to: downloads.appendingPathComponent(name))
        }
        let model = makeModel(providers: [DownloadsProvider(homeDirectory: home)]) { settings in
            settings.general.showHiddenFiles = true
        }

        model.startDownloadsAnalysis()
        await model.waitForAnalysis()
        let analysis = try XCTUnwrap(model.downloadsAnalysis)
        XCTAssertEqual(analysis.allFiles.count, 3)
        model.selectedDownloadFileIDs = Set(analysis.allFiles.map(\.id))

        let first = model.selectedCleanupItems.map(\.id)
        for _ in 0..<100 { _ = model.selectedCleanupItems }
        XCTAssertEqual(Set(model.selectedCleanupItems.map(\.id)), Set(first))
        XCTAssertEqual(Set(first), Set(analysis.allFiles.map(\.id)), "Items reuse the file IDs")
        XCTAssertEqual(model.snapshots.count(providerID: DownloadsProvider.providerID), 3)
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
