import Foundation
import XCTest
@testable import DiskSweep

/// 7.5: permanent removal walks from the approved root with descriptors and never follows a
/// symbolic link, so a folder swapped for a link after validation can't redirect it.
final class SecureRemovalTests: XCTestCase {
    private let snapshots = CleanupSnapshotRegistry()
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepSecureRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ relative: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func engine(hook: (@Sendable (URL) -> Void)? = nil) -> CleanupEngine {
        CleanupEngine(
            safetyValidator: SafetyValidator(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                temporaryDirectory: FileManager.default.temporaryDirectory
            ),
            snapshots: snapshots,
            beforePermanentRemoval: hook
        )
    }

    private var cacheRoot: URL { root.appendingPathComponent("Cache", isDirectory: true) }

    private func authorization() -> CleanupAuthorization {
        CleanupAuthorization(providerID: "secure-test", location: .temporaryFiles, allowedRoots: [cacheRoot])
    }

    private func item(_ url: URL, kind: FileItemKind, size: Int64) -> CleanupItem {
        CleanupItem(
            providerID: "secure-test", location: .temporaryFiles, name: url.lastPathComponent,
            url: url, size: size, kind: kind, risk: .safe, explanation: "test"
        )
    }

    func testParentSwappedForSymlinkBeforeRemovalIsRefused() async throws {
        let target = try write("Cache/Folder/inner/target.bin", "cache")
        let decoy = try write("Decoy/inner/target.bin", "important")
        let folder = cacheRoot.appendingPathComponent("Folder", isDirectory: true)
        let movedAside = root.appendingPathComponent("MovedAside", isDirectory: true)
        let decoyFolder = root.appendingPathComponent("Decoy", isDirectory: true)

        let swap: @Sendable (URL) -> Void = { _ in
            // A same-user process replaces Folder with a link to Decoy in the last moment.
            try? FileManager.default.moveItem(at: folder, to: movedAside)
            try? FileManager.default.createSymbolicLink(at: folder, withDestinationURL: decoyFolder)
        }
        let result = await engine(hook: swap).clean(
            [item(target, kind: .file, size: 5)],
            authorizations: [authorization()],
            disposition: .permanent
        )

        XCTAssertTrue(result.cleanedItems.isEmpty, "The removal must not follow the swapped-in link")
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), "important")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedAside.appendingPathComponent("inner/target.bin").path))
    }

    func testRemovesNestedFolderAndOnlyUnlinksLinksInside() async throws {
        _ = try write("Cache/Tree/a/b/c/deep.bin")
        _ = try write("Cache/Tree/a/file.bin")
        _ = try write("Cache/Tree/.hidden")
        let outside = try write("Outside/keep.txt", "keep")
        let tree = cacheRoot.appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("a/link-to-outside"),
            withDestinationURL: outside.deletingLastPathComponent()
        )

        let result = await engine().clean(
            [item(tree, kind: .directory, size: 1)],
            authorizations: [authorization()],
            disposition: .permanent
        )

        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.reason))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path), "The approved root stays")
    }

    /// Negative: a target replaced by another object right before removal is refused.
    func testTargetReplacedRightBeforeRemovalIsRefused() async throws {
        let target = try write("Cache/swap.bin", "original")
        let replacement = root.appendingPathComponent("replacement.bin")
        try Data("replacement".utf8).write(to: replacement)
        let swap: @Sendable (URL) -> Void = { url in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: replacement, to: url)
        }

        let result = await engine(hook: swap).clean(
            [item(target, kind: .file, size: 8)],
            authorizations: [authorization()],
            disposition: .permanent
        )

        XCTAssertTrue(result.cleanedItems.isEmpty)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
    }
}
