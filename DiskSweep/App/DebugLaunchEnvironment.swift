#if DEBUG
import Foundation

/// Debug-only support for manual QA against a fake home folder.
///
/// Launch a Debug build with `-DiskSweepHomeOverride <path>` (Scheme > Run > Arguments) to
/// point every provider, analyzer, the safety validator, settings, and history at a fixture
/// home such as the one `scripts/make-fixture-home.sh` creates. Release builds compile none
/// of this, so the argument has no effect there.
///
/// The fixture home must be inside this account's temporary directory, because the safety
/// validator treats the rest of `/private` as protected. Temporary Files then scans the
/// fixture's own `tmp` folder instead of the real one.
enum DebugLaunchEnvironment {
    static let homeOverrideArgument = "-DiskSweepHomeOverride"

    static func homeOverride(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        guard let index = arguments.firstIndex(of: homeOverrideArgument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        let path = (arguments[index + 1] as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    @MainActor
    static func makeFixtureModel(home: URL) -> AppViewModel {
        let suiteName = "com.disksweep.DiskSweep.fixture"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let support = home.appendingPathComponent(
            "Library/Application Support/DiskSweep",
            isDirectory: true
        )
        let snapshots = CleanupSnapshotRegistry()
        return AppViewModel(
            homeDirectory: home,
            temporaryDirectory: home.appendingPathComponent("tmp", isDirectory: true),
            settings: SettingsStore(userDefaults: defaults),
            history: CleanupHistoryStore(
                fileURL: support.appendingPathComponent("cleanup-history.json")
            ),
            permissions: PermissionManager(homeDirectory: home),
            snapshots: snapshots,
            cleanupEngine: CleanupEngine(
                safetyValidator: SafetyValidator(homeDirectory: home),
                snapshots: snapshots
            )
        )
    }
}
#endif
