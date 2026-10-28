import Foundation
import XCTest
@testable import DiskSweep

final class DeveloperCleanupProvidersTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepDeveloperTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Old IDE versions

    func testIDEVersionParsingAndReplacement() {
        let jetBrains = home.appendingPathComponent("Library/Application Support/JetBrains")
        let google = home.appendingPathComponent("Library/Application Support/Google")
        func parse(_ name: String, in root: URL) -> StaleIDEVersionRules.VersionedFolder? {
            StaleIDEVersionRules.parse(root.appendingPathComponent(name), inRoot: root)
        }

        XCTAssertEqual(parse("PyCharm2025.2", in: jetBrains)?.family, "PyCharm")
        XCTAssertEqual(parse("PyCharm2025.2-backup", in: jetBrains)?.isBackup, true)
        XCTAssertEqual(parse("AndroidStudio4.2", in: google)?.version, [4, 2])
        XCTAssertNil(parse("Daemon", in: jetBrains))
        XCTAssertNil(parse("PyCharm2025", in: jetBrains))
        XCTAssertNil(parse("PyCharm2025.x", in: jetBrains))
        XCTAssertNil(parse("Chrome", in: google))
        XCTAssertNil(parse("Chrome2025.1", in: google))

        let folders = ["PyCharm2025.2", "PyCharm2026.2", "PyCharmCE2025.2", "PyCharm2025.2-backup",
                       "WebStorm2024.1", "PyCharm2027.1-backup"]
            .compactMap { parse($0, in: jetBrains) }
        func replacement(_ name: String) -> String? {
            let folder = folders.first { $0.url.lastPathComponent == name }!
            return StaleIDEVersionRules.replacement(for: folder, among: folders)?.url.lastPathComponent
        }

        XCTAssertEqual(replacement("PyCharm2025.2"), "PyCharm2026.2")
        XCTAssertEqual(replacement("PyCharmCE2025.2"), "PyCharm2026.2")
        XCTAssertEqual(replacement("PyCharm2025.2-backup"), "PyCharm2026.2")
        // A backup is never a replacement, and the only WebStorm version is current.
        XCTAssertNil(replacement("PyCharm2026.2"))
        XCTAssertNil(replacement("WebStorm2024.1"))
    }

    func testFindsOnlySupersededIdleIDEVersions() async throws {
        try makeIDEFolder("JetBrains/PyCharm2025.2", lastUsedDaysAgo: 200, pluginBytes: 256)
        try makeIDEFolder("JetBrains/PyCharm2026.1", lastUsedDaysAgo: 5)
        try makeIDEFolder("JetBrains/PyCharm2026.2", lastUsedDaysAgo: 1)
        try makeIDEFolder("JetBrains/WebStorm2024.1", lastUsedDaysAgo: 400)
        try makeIDEFolder("Google/AndroidStudio4.1", lastUsedDaysAgo: 900)
        try makeIDEFolder("Google/AndroidStudio2024.1", lastUsedDaysAgo: 100)
        try write("Library/Application Support/Google/Chrome/Default/History")

        let result = await StaleIDEVersionsProvider(homeDirectory: home)
            .scan(context: context) { _ in }

        XCTAssertEqual(
            Set(result.items.map(\.url.lastPathComponent)),
            ["PyCharm2025.2", "AndroidStudio4.1"]
        )
        XCTAssertTrue(result.items.allSatisfy { $0.isDeletable && !$0.isSelectedByDefault })
        XCTAssertTrue(result.items.allSatisfy { $0.risk == .reviewRecommended })
        XCTAssertEqual(
            result.items.first { $0.url.lastPathComponent == "PyCharm2025.2" }?.name,
            "PyCharm 2025.2"
        )
    }

    func testCleansSupersededIDEVersionWithBundledNodeModules() async throws {
        try makeIDEFolder("JetBrains/PyCharm2025.2", lastUsedDaysAgo: 200, pluginBytes: 64)
        try write("Library/Application Support/JetBrains/PyCharm2025.2/plugins/vue/node_modules/x/index.js")
        try makeIDEFolder("JetBrains/PyCharm2026.2", lastUsedDaysAgo: 1)
        try age("Library/Application Support/JetBrains/PyCharm2025.2", daysAgo: 200)

        let provider = StaleIDEVersionsProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }
        XCTAssertEqual(scanned.items.count, 1)

        let result = await engine.clean(scanned.items, providers: [provider], disposition: .permanent)

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertFalse(exists("Library/Application Support/JetBrains/PyCharm2025.2"))
        XCTAssertTrue(exists("Library/Application Support/JetBrains/PyCharm2026.2"))
    }

    func testRefusesIDEVersionWhoseReplacementWasRemoved() async throws {
        try makeIDEFolder("JetBrains/PyCharm2025.2", lastUsedDaysAgo: 200)
        try makeIDEFolder("JetBrains/PyCharm2026.2", lastUsedDaysAgo: 1)

        let provider = StaleIDEVersionsProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }
        XCTAssertEqual(scanned.items.count, 1)
        try FileManager.default.removeItem(
            at: home.appendingPathComponent("Library/Application Support/JetBrains/PyCharm2026.2")
        )

        let result = await engine.clean(scanned.items, providers: [provider], disposition: .permanent)

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(exists("Library/Application Support/JetBrains/PyCharm2025.2"))
    }

    func testIDEAuthorizationNeverReachesBrowserDataInGoogleFolder() async throws {
        try makeIDEFolder("Google/AndroidStudio2024.1", lastUsedDaysAgo: 1)
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try write("Library/Application Support/Google/Chrome/Default/History")
        try age("Library/Application Support/Google/Chrome", daysAgo: 400)

        let identity = try SafetyValidator.captureIdentity(at: profile)
        let forged = CleanupItem(
            providerID: StaleIDEVersionsProvider.providerID,
            location: .staleIDEVersions,
            name: "Chrome",
            url: profile,
            size: 0,
            kind: .directory,
            modifiedAt: identity.modificationDate,
            risk: .reviewRecommended,
            explanation: ""
        )
        let result = await engine.clean(
            [forged],
            authorizations: [CleanupAuthorization(
                providerID: StaleIDEVersionsProvider.providerID,
                location: .staleIDEVersions,
                allowedRoots: StaleIDEVersionsProvider(homeDirectory: home).allowedRoots
            )],
            disposition: .permanent
        )

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertTrue(exists("Library/Application Support/Google/Chrome/Default/History"))
    }

    // MARK: - Android system images

    func testOffersOnlyAndroidImagesNoDeviceUses() async throws {
        try makeSystemImage("android-35/google_apis/arm64-v8a")
        try makeSystemImage("android-30/google_apis/x86")
        try write("Library/Android/sdk/system-images/android-29/google_apis/notes.txt")
        try write(".android/avd/Pixel.ini", contents: "path=\(home.path)/.android/avd/Pixel.avd\n")
        try write(
            ".android/avd/Pixel.avd/config.ini",
            contents: "abi.type = arm64-v8a\nimage.sysdir.1 = system-images/android-35/google_apis/arm64-v8a/\n"
        )

        let provider = AndroidSystemImagesProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }

        XCTAssertEqual(scanned.items.map(\.name), ["API 30 · google apis · x86"])
        XCTAssertFalse(try XCTUnwrap(scanned.items.first).isSelectedByDefault)

        let result = await engine.clean(scanned.items, providers: [provider], disposition: .permanent)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertFalse(exists("Library/Android/sdk/system-images/android-30/google_apis/x86"))
        XCTAssertTrue(exists("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a"))
    }

    func testOffersNoAndroidImagesWhenADeviceCannotBeRead() async throws {
        try makeSystemImage("android-30/google_apis/x86")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".android/avd/Broken.avd"),
            withIntermediateDirectories: true
        )

        let scanned = await AndroidSystemImagesProvider(homeDirectory: home)
            .scan(context: context) { _ in }

        XCTAssertTrue(scanned.items.isEmpty)
    }

    func testRefusesAndroidImageThatADeviceStartedUsing() async throws {
        try makeSystemImage("android-30/google_apis/x86")
        try write(".android/avd/Pixel.avd/config.ini", contents: "image.sysdir.1=system-images/android-35/default/x86_64/\n")

        let provider = AndroidSystemImagesProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }
        XCTAssertEqual(scanned.items.count, 1)
        try write(".android/avd/Tablet.avd/config.ini", contents: "image.sysdir.1=system-images/android-30/google_apis/x86/\n")

        let result = await engine.clean(scanned.items, providers: [provider], disposition: .permanent)

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertTrue(exists("Library/Android/sdk/system-images/android-30/google_apis/x86"))
    }

    // MARK: - Package manager caches

    func testFindsPackageManagerCachesAndReviewsUV() async throws {
        try write(".npm/_cacache/content-v2/sha512/blob", byteCount: 128)
        try write(".npm/_logs/debug.log")
        try write(".cache/uv/archive-v0/wheel/file.py")
        try write(".cargo/registry/cache/index.crates.io/serde.crate")
        try write(".m2/repository/com/example/app.jar")

        let provider = DeveloperToolCacheProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }

        XCTAssertEqual(
            Set(scanned.items.map(\.name)),
            ["npm — content-v2", "uv — archive-v0", "Cargo crates — index.crates.io"]
        )
        let uv = try XCTUnwrap(scanned.items.first { $0.name.hasPrefix("uv") })
        XCTAssertFalse(uv.isSelectedByDefault)
        let npm = try XCTUnwrap(scanned.items.first { $0.name.hasPrefix("npm") })
        XCTAssertTrue(npm.isSelectedByDefault)

        let result = await engine.clean([npm], providers: [provider])
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertFalse(exists(".npm/_cacache/content-v2"))
        XCTAssertTrue(exists(".npm/_logs/debug.log"))
    }

    // MARK: - Electron app caches

    func testFindsElectronCachesButNotAppData() async throws {
        try write("Library/Application Support/Slack/Local State", contents: "{}")
        try write("Library/Application Support/Slack/Cache/Cache_Data/f_000001", byteCount: 64)
        try write("Library/Application Support/Slack/Code Cache/js/index")
        try write("Library/Application Support/Slack/Local Storage/leveldb/000003.log")
        try write("Library/Application Support/Slack/Partitions/app/GPUCache/data_0")
        try write("Library/Application Support/NotElectron/Cache/file")

        let provider = ElectronAppCacheProvider(homeDirectory: home)
        let scanned = await provider.scan(context: context) { _ in }

        XCTAssertEqual(
            Set(scanned.items.map(\.name)),
            ["Slack — Cache", "Slack — Code Cache", "Slack — GPUCache (app)"]
        )
        XCTAssertTrue(scanned.items.allSatisfy(\.isSelectedByDefault))

        let result = await engine.clean(scanned.items, providers: [provider])
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertTrue(exists("Library/Application Support/Slack/Local Storage/leveldb/000003.log"))
        XCTAssertTrue(exists("Library/Application Support/Slack/Local State"))
        XCTAssertFalse(exists("Library/Application Support/Slack/Cache"))
    }

    func testElectronAuthorizationNeverReachesAppData() async throws {
        try write("Library/Application Support/Slack/Local State", contents: "{}")
        try write("Library/Application Support/Slack/Local Storage/leveldb/000003.log")
        let storage = home.appendingPathComponent("Library/Application Support/Slack/Local Storage")
        let identity = try SafetyValidator.captureIdentity(at: storage)
        let forged = CleanupItem(
            providerID: ElectronAppCacheProvider.providerID,
            location: .electronAppCaches,
            name: "Local Storage",
            url: storage,
            size: 0,
            kind: .directory,
            modifiedAt: identity.modificationDate,
            risk: .safe,
            explanation: ""
        )

        let result = await engine.clean(
            [forged],
            authorizations: [CleanupAuthorization(
                providerID: ElectronAppCacheProvider.providerID,
                location: .electronAppCaches,
                allowedRoots: ElectronAppCacheProvider(homeDirectory: home).allowedRoots
            )],
            disposition: .permanent
        )

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertTrue(exists("Library/Application Support/Slack/Local Storage/leveldb/000003.log"))
    }

    // MARK: - Device support

    func testSelectsOnlyBetaDeviceSupportReplacedByRelease() async throws {
        let support = "Library/Developer/Xcode/iOS DeviceSupport"
        try write("\(support)/iPhone17,2 27.2 (24B115)/Symbols/a", byteCount: 64)
        try write("\(support)/iPhone17,2 27.2 (24B5089g)/Symbols/a")
        try write("\(support)/iPhone17,2 27.3 (24C5010a)/Symbols/a")
        try write("\(support)/iPhone16,1 27.2 (24B5089g)/Symbols/a")
        try write("Library/Developer/Xcode/watchOS DeviceSupport/27.2 (24S5091f) universal/a")
        try write("Library/Developer/Xcode/watchOS DeviceSupport/27.2 (24S116) universal/a")

        let scanned = await XcodeDeviceSupportProvider(homeDirectory: home)
            .scan(context: context) { _ in }

        XCTAssertEqual(
            Set(scanned.items.filter(\.isSelectedByDefault).map(\.name)),
            ["iOS — iPhone17,2 27.2 (24B5089g)", "watchOS — 27.2 (24S5091f) universal"]
        )
        XCTAssertEqual(scanned.items.count, 6)
        XCTAssertFalse(DeviceSupportFolder(
            url: URL(fileURLWithPath: "/x/iOS DeviceSupport/iPhone 16.5 (20F75c)")
        )!.isBetaBuild)
    }

    func testElectronRootsRequireChromiumMarker() throws {
        try write("Library/Application Support/Plain/Cache/file")
        let cache = home.appendingPathComponent("Library/Application Support/Plain/Cache")

        let app = home.appendingPathComponent("Library/Application Support/Plain")

        XCTAssertThrowsError(try validator.preflightApprovedRoot(app, location: .electronAppCaches))
        try write("Library/Application Support/Plain/Local State", contents: "{}")
        XCTAssertNoThrow(try validator.preflightApprovedRoot(app, location: .electronAppCaches))
        // The app folder is only approved for this one location.
        XCTAssertThrowsError(try validator.preflightApprovedRoot(app, location: .userCaches))
        XCTAssertThrowsError(try validator.preflightApprovedRoot(cache, location: .electronAppCaches))
    }

    // MARK: - Helpers

    private var context: ScanContext {
        ScanContext(homeDirectory: home, now: now)
    }

    private var validator: SafetyValidator {
        SafetyValidator(homeDirectory: home, temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    private var engine: CleanupEngine {
        CleanupEngine(safetyValidator: validator)
    }

    private func makeIDEFolder(
        _ relativePath: String,
        lastUsedDaysAgo: Int,
        pluginBytes: Int = 8
    ) throws {
        let base = "Library/Application Support/\(relativePath)"
        try write("\(base)/options/other.xml")
        try write("\(base)/plugins/plugin.jar", byteCount: pluginBytes)
        try age(base, daysAgo: lastUsedDaysAgo)
    }

    private func makeSystemImage(_ relativePath: String) throws {
        let base = "Library/Android/sdk/system-images/\(relativePath)"
        try write("\(base)/package.xml")
        try write("\(base)/system.img", byteCount: 64)
    }

    private func write(_ relativePath: String, contents: String? = nil, byteCount: Int = 8) throws {
        let file = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x2A, count: byteCount)
        try data.write(to: file)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    /// Sets the modification date of a folder and everything in it, deepest entries first so
    /// that setting a child's date doesn't bump its parent afterwards.
    private func age(_ relativePath: String, daysAgo: Int) throws {
        let base = home.appendingPathComponent(relativePath)
        let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        var urls = [base]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        while let url = enumerator.nextObject() as? URL { urls.append(url) }
        for url in urls.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
}
