import Foundation
import XCTest
@testable import DiskSweep

final class ProjectArtifactsProviderTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var code: URL!
    private let now = Date()
    private let idleAge: TimeInterval = 90 * 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepProjectTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        code = home.appendingPathComponent("Code", isDirectory: true)
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testFindsIdleArtifactsByMarkerAndIgnoresLookalikes() async throws {
        try write("old-python/main.py")
        try write("old-python/uv.lock")
        try write("old-python/.venv/pyvenv.cfg", contents: "home = /usr/bin")
        try write("old-python/.venv/lib/site-packages/package.py", byteCount: 64)
        try write("old-python/build/output.txt")

        try write("old-rust/Cargo.toml")
        try write("old-rust/target/CACHEDIR.TAG", contents: cacheTag)
        try write("old-rust/target/debug/app", byteCount: 128)

        try write("old-node/package.json")
        try write("old-node/node_modules/left-pad/index.js")
        try write("old-node/node_modules/left-pad/node_modules/nested/index.js")

        try write("lookalikes/venv/lib/module.py")
        try write("lookalikes/target/CACHEDIR.TAG", contents: "Signature: not a real cache tag")
        try write("lookalikes/orphan/node_modules/module/index.js")

        try ageEverything()

        let result = await scan()

        XCTAssertEqual(
            Set(result.items.map { resolvedPath($0.url) }),
            Set([
                resolvedPath(project("old-python/.venv")),
                resolvedPath(project("old-rust/target")),
                resolvedPath(project("old-node/node_modules"))
            ])
        )
        XCTAssertTrue(result.items.allSatisfy { $0.kind == .directory })
        XCTAssertTrue(result.items.allSatisfy { $0.isDeletable })
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelectedByDefault })
        XCTAssertTrue(result.items.allSatisfy { $0.risk == .reviewRecommended })
        XCTAssertTrue(result.items.allSatisfy { $0.location == .projectArtifacts })

        let venv = try XCTUnwrap(result.items.first { $0.url.lastPathComponent == ".venv" })
        XCTAssertEqual(venv.name, "old-python — Python virtual environment")
        XCTAssertTrue(venv.detail?.contains("uv sync") == true)
        let target = try XCTUnwrap(result.items.first { $0.url.lastPathComponent == "target" })
        XCTAssertTrue(target.detail?.contains("cargo build") == true)
        let modules = try XCTUnwrap(result.items.first { $0.url.lastPathComponent == "node_modules" })
        XCTAssertEqual(modules.fileCount, 2)
    }

    func testArtifactsInRecentlyActiveProjectsAreNotOffered() async throws {
        try write("edited/.venv/pyvenv.cfg")
        try write("edited/src/package/deep/module.py")
        try write("committed/.venv/pyvenv.cfg")
        try write("committed/main.py")
        try write("committed/.git/index")
        try write("browsed/.venv/pyvenv.cfg")
        try write("browsed/main.py")
        try write("browsed/.DS_Store")
        try ageEverything()

        let recently = now.addingTimeInterval(-86_400)
        try setModificationDate(recently, for: project("edited/src/package/deep/module.py"))
        try setModificationDate(recently, for: project("committed/.git/index"))
        try setModificationDate(recently, for: project("browsed/.DS_Store"))

        let result = await scan()

        XCTAssertEqual(
            result.items.map { resolvedPath($0.url) },
            [resolvedPath(project("browsed/.venv"))]
        )
    }

    func testArtifactContainingRepositoryIsNotDeletable() async throws {
        try write("vendored/requirements.txt")
        try write("vendored/.venv/pyvenv.cfg")
        try write("vendored/.venv/src/checkout/.git/HEAD")
        try ageEverything()

        let result = await scan()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertFalse(item.isDeletable)
        XCTAssertEqual(result.category.totalSize, 0)
    }

    func testEngineRemovesScannedArtifactsAndLeavesProjectSources() async throws {
        try write("app/package.json")
        try write("app/index.js")
        try write("app/node_modules/dependency/index.js")
        try write("app/node_modules/dependency/node_modules/transitive/index.js")
        try write("tool/main.py")
        try write("tool/.venv/pyvenv.cfg")
        try ageEverything()

        let provider = makeProvider()
        let scanned = await provider.scan(context: context) { _ in }
        XCTAssertEqual(scanned.items.count, 2)

        let result = await engine.clean(
            scanned.items,
            providers: [provider],
            disposition: .permanent
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertEqual(result.cleanedItems.count, 2)
        XCTAssertFalse(exists("app/node_modules"))
        XCTAssertFalse(exists("tool/.venv"))
        XCTAssertTrue(exists("app/package.json"))
        XCTAssertTrue(exists("app/index.js"))
        XCTAssertTrue(exists("tool/main.py"))
    }

    func testEngineRefusesArtifactWhoseMarkerNoLongerMatches() async throws {
        try write("rust/Cargo.toml")
        try write("rust/target/CACHEDIR.TAG", contents: cacheTag)
        try write("rust/target/debug/app")
        try ageEverything()

        let provider = makeProvider()
        let scanned = await provider.scan(context: context) { _ in }
        let item = try XCTUnwrap(scanned.items.first)

        // Rewriting the tag in place leaves the folder's own identity unchanged, so only the
        // marker check stands between this folder and removal.
        let tag = project("rust/target/CACHEDIR.TAG")
        let handle = try FileHandle(forWritingTo: tag)
        try handle.write(contentsOf: Data(String(repeating: "x", count: cacheTag.utf8.count).utf8))
        try handle.close()

        let result = await engine.clean([item], providers: [provider], disposition: .permanent)

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(exists("rust/target/debug/app"))
    }

    func testRemovedProjectFolderRevokesCleanup() async throws {
        try write("tool/main.py")
        try write("tool/.venv/pyvenv.cfg")
        try ageEverything()

        let scanned = await makeProvider().scan(context: context) { _ in }
        let item = try XCTUnwrap(scanned.items.first)

        let result = await engine.clean(
            [item],
            providers: [ProjectArtifactsProvider(
                projectFolders: [],
                minimumAge: idleAge,
                homeDirectory: home
            )],
            disposition: .permanent
        )

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(exists("tool/.venv/pyvenv.cfg"))
    }

    func testRefusedProjectFolderDoesNotBlockCleanupElsewhere() async throws {
        let documents = home.appendingPathComponent("Documents/Code", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try write("tool/main.py")
        try write("tool/.venv/pyvenv.cfg")
        try ageEverything()

        let provider = makeProvider(extraFolders: [documents])
        XCTAssertEqual(provider.allowedRoots, [code.standardizedFileURL])

        let scanned = await provider.scan(context: context) { _ in }
        XCTAssertTrue(scanned.issues.contains { $0.path == documents.standardizedFileURL.path })

        let result = await engine.clean(scanned.items, providers: [provider], disposition: .permanent)

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertFalse(exists("tool/.venv"))
    }

    func testProtectedAndBroadProjectFoldersAreRefused() throws {
        let documents = home.appendingPathComponent("Documents/Code", isDirectory: true)
        let library = home.appendingPathComponent("Library/Code", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        XCTAssertNil(ProjectArtifactsProvider.refusalReason(for: code, homeDirectory: home))
        XCTAssertNotNil(ProjectArtifactsProvider.refusalReason(for: home, homeDirectory: home))
        XCTAssertNotNil(ProjectArtifactsProvider.refusalReason(for: documents, homeDirectory: home))
        XCTAssertNotNil(ProjectArtifactsProvider.refusalReason(for: library, homeDirectory: home))
        XCTAssertNotNil(ProjectArtifactsProvider.refusalReason(
            for: home.appendingPathComponent("Missing", isDirectory: true),
            homeDirectory: home
        ))
    }

    // MARK: - Helpers

    private let cacheTag = "Signature: 8a477f597d28d172789f06886806bc55\n# Test cache.\n"

    private var context: ScanContext {
        ScanContext(homeDirectory: home, now: now)
    }

    private var engine: CleanupEngine {
        CleanupEngine(
            safetyValidator: SafetyValidator(
                homeDirectory: home,
                temporaryDirectory: FileManager.default.temporaryDirectory
            )
        )
    }

    private func makeProvider(extraFolders: [URL] = []) -> ProjectArtifactsProvider {
        ProjectArtifactsProvider(
            projectFolders: [code] + extraFolders,
            minimumAge: idleAge,
            homeDirectory: home
        )
    }

    private func scan() async -> ProviderScanResult {
        await makeProvider().scan(context: context) { _ in }
    }

    private func project(_ relativePath: String) -> URL {
        code.appendingPathComponent(relativePath)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: project(relativePath).path)
    }

    private func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func write(_ relativePath: String, contents: String? = nil, byteCount: Int = 8) throws {
        let file = project(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x2A, count: byteCount)
        try data.write(to: file)
    }

    /// Makes every file and folder under the code folder look untouched for 200 days.
    private func ageEverything() throws {
        let old = now.addingTimeInterval(-200 * 86_400)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: code,
            includingPropertiesForKeys: nil
        ))
        while let url = enumerator.nextObject() as? URL {
            try setModificationDate(old, for: url)
        }
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}
