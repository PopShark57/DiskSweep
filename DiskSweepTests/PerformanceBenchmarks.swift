import Foundation
import XCTest
@testable import DiskSweep

/// Phase 5 timings against the large fixture from `scripts/make-fixture-home.sh --large`.
///
/// Skipped unless `DISKSWEEP_BENCHMARK_FIXTURE` names that fixture, for example:
///
///     TEST_RUNNER_DISKSWEEP_BENCHMARK_FIXTURE=<path> xcodebuild … test \
///         -only-testing:DiskSweepTests/PerformanceBenchmarks
///
/// Everything here only reads the fixture. Nothing is cleaned. Each benchmark prints
/// `BENCH <name>: <median> ms (runs …)`.
@MainActor
final class PerformanceBenchmarks: XCTestCase {
    private var home: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["DISKSWEEP_BENCHMARK_FIXTURE"],
              !path.isEmpty else {
            throw XCTSkip("Set DISKSWEEP_BENCHMARK_FIXTURE to run benchmarks.")
        }
        home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let marker = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/BigApp-perfperfperf"
        )
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("The benchmark fixture must be built with --large.")
        }
    }

    private var bigDerivedData: URL {
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData/BigApp-perfperfperf")
    }

    private func measure(
        _ name: String,
        runs: Int = 5,
        _ body: () async throws -> Void
    ) async rethrows {
        var samples: [Double] = []
        for _ in 0..<runs {
            let clock = ContinuousClock()
            let start = clock.now
            try await body()
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1_000)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let list = samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        print("BENCH \(name): \(String(format: "%.1f", median)) ms (runs \(list))")
    }

    /// P1: the scanner's hot loop, sizing 100k files.
    func testBenchScannerSizing() async throws {
        let target = bigDerivedData
        let exclusion = home.appendingPathComponent("Media", isDirectory: true)
        try await measure("P1 sizer, no exclusions") {
            let result = try await DirectorySizer().size(of: target, includeHiddenFiles: true, skipPackages: false)
            XCTAssertEqual(result.fileCount, 100_000)
        }
        try await measure("P1 sizer, one exclusion") {
            let result = try await DirectorySizer().size(
                of: target,
                exclusions: [exclusion],
                includeHiddenFiles: true,
                skipPackages: false
            )
            XCTAssertEqual(result.fileCount, 100_000)
        }
    }

    /// P2: the pre-delete descendant walk over 100k entries (read-only).
    func testBenchValidateDirectoryContents() async throws {
        let validator = SafetyValidator(homeDirectory: home)
        let root = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let validated = try validator.validate(
            bigDerivedData,
            location: .xcodeDerivedData,
            allowedRoots: [root]
        )
        try await measure("P2 validateDirectoryContents") {
            try validator.validateDirectoryContents(
                validated,
                exclusionRoots: [],
                permittedNestedNames: CleanupLocation.xcodeDerivedData.permittedNestedNames
            )
        }
    }

    /// P3: confirming 500 duplicate pairs of 1.1 MB files.
    func testBenchDuplicates() async throws {
        let pairs = home.appendingPathComponent("Media/Pairs", isDirectory: true)
        let context = ScanContext(homeDirectory: home, snapshots: CleanupSnapshotRegistry())
        try await measure("P3 duplicates (500 pairs)", runs: 3) {
            let result = try await DuplicateAnalyzer().scan(
                root: pairs,
                minimumFileSize: 1_000_000,
                context: context
            )
            XCTAssertEqual(result.groups.count, 500)
        }
    }

    /// P5: formatting 200k size labels.
    func testBenchFormatter() async {
        await measure("P5 formatter x200k") {
            var total = 0
            for value in 0..<200_000 {
                total &+= FileSizeFormatter.string(fromByteCount: Int64(value) * 4_099).count
            }
            XCTAssertGreaterThan(total, 0)
        }
    }

    /// D7: the provider root evaluation that the overlap filter used to repeat on the main
    /// actor once per provider (18 times per scan).
    func testBenchProviderRootEvaluation() async {
        let providers = StandardCleanupProviders.all(homeDirectory: home)
        await measure("D7 allowedRoots of all providers, x1") {
            _ = providers.flatMap(\.allowedRoots)
        }
        await measure("D7 allowedRoots of all providers, x\(providers.count) (old per-scan main-actor cost)") {
            for _ in providers { _ = providers.flatMap(\.allowedRoots) }
        }
    }

    /// P4/5.6: the Downloads screen's per-render filter and regroup of 20k files.
    func testBenchDownloadsFilter() async throws {
        let context = ScanContext(homeDirectory: home, snapshots: CleanupSnapshotRegistry())
        let analysis = try await DownloadsAnalyzer().scan(context: context)
        XCTAssertGreaterThanOrEqual(analysis.allFiles.count, 20_000)
        await measure("P4 Downloads filter+regroup (one body evaluation)") {
            let filtered = analysis.applying(DownloadsFilter(olderThan: nil, largerThan: nil))
            let groups = filtered.groups.map { group in
                group.files.filter { _ in true }
            }
            XCTAssertFalse(groups.isEmpty)
        }
    }

    /// P6: a full cleanup scan of the fixture with every standard provider.
    func testBenchFullScan() async throws {
        let suite = "DiskSweepBenchmarks-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: UserDefaults(suiteName: suite)!)
        settings.setDeveloperLocation(.projectArtifacts, isEnabled: false)
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let model = AppViewModel(
            homeDirectory: home,
            temporaryDirectory: home.appendingPathComponent("tmp", isDirectory: true),
            settings: settings,
            history: CleanupHistoryStore(fileURL: sandbox.appendingPathComponent("h.json")),
            permissions: PermissionManager(homeDirectory: home)
        )
        await measure("P6 full scan", runs: 3) {
            model.startCleanupScan()
            await model.waitForScan()
            XCTAssertFalse(model.categories.isEmpty)
        }
    }
}
