import Foundation
import XCTest
@testable import DiskSweep

final class SafetyValidatorTests: XCTestCase {
    private var sandboxURL: URL!
    private var homeURL: URL!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepSafetyTests-\(UUID().uuidString)", isDirectory: true)
        homeURL = sandboxURL.appendingPathComponent("Home", isDirectory: true)
        cacheRoot = homeURL.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL,
           FileManager.default.fileExists(atPath: sandboxURL.path) {
            try FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testAllowsExistingDescendantOfApprovedRoot() throws {
        let file = try makeFile(at: cacheRoot.appendingPathComponent("safe.cache"))
        let validated = try validator.validate(file, allowedRoots: [cacheRoot])

        XCTAssertEqual(validated.deletionURL, file.standardizedFileURL)
        XCTAssertEqual(validated.approvedRoot, cacheRoot.standardizedFileURL)
        XCTAssertEqual(validated.identity.kind, .file)
    }

    func testRejectsApprovedRootItself() throws {
        XCTAssertThrowsError(try validator.validate(cacheRoot, allowedRoots: [cacheRoot])) {
            guard case SafetyValidationError.targetIsApprovedRoot = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testIgnoresAbsentOptionalRootWhenAnotherApprovedRootMatches() throws {
        let file = try makeFile(at: cacheRoot.appendingPathComponent("safe.cache"))
        let absent = homeURL.appendingPathComponent("Library/Caches/Absent", isDirectory: true)

        XCTAssertNoThrow(
            try validator.validate(file, allowedRoots: [cacheRoot, absent])
        )
    }

    func testRejectsApprovedRootThatIsItselfASymbolicLink() throws {
        let file = try makeFile(at: cacheRoot.appendingPathComponent("safe.cache"))
        let linkedRoot = homeURL.appendingPathComponent("LinkedCaches", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: cacheRoot
        )

        XCTAssertThrowsError(
            try validator.validate(
                linkedRoot.appendingPathComponent(file.lastPathComponent),
                allowedRoots: [linkedRoot]
            )
        ) {
            guard case SafetyValidationError.invalidApprovedRoot = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testRejectsOutsideApprovedRoot() throws {
        let outside = try makeFile(at: homeURL.appendingPathComponent("outside.txt"))

        XCTAssertThrowsError(try validator.validate(outside, allowedRoots: [cacheRoot])) {
            guard case SafetyValidationError.outsideApprovedRoots = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testRejectsDotDotTraversalBeforeStandardization() throws {
        let outside = try makeFile(
            at: cacheRoot.deletingLastPathComponent().appendingPathComponent("outside.txt")
        )
        let traversal = cacheRoot.appendingPathComponent("../outside.txt")
        XCTAssertEqual(traversal.standardizedFileURL, outside.standardizedFileURL)

        XCTAssertThrowsError(try validator.validate(traversal, allowedRoots: [cacheRoot])) {
            guard case SafetyValidationError.traversalComponent = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testRejectsDirectSymbolicLinkWithoutTouchingDestination() throws {
        let outside = try makeFile(at: homeURL.appendingPathComponent("outside.txt"))
        let link = cacheRoot.appendingPathComponent("linked.cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try validator.validate(link, allowedRoots: [cacheRoot])) {
            guard case SafetyValidationError.symbolicLink = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRejectsTraversalThroughParentSymbolicLink() throws {
        let outsideDirectory = homeURL.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let payload = try makeFile(at: outsideDirectory.appendingPathComponent("payload.cache"))
        let link = cacheRoot.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideDirectory
        )

        XCTAssertThrowsError(
            try validator.validate(
                link.appendingPathComponent("payload.cache"),
                allowedRoots: [cacheRoot]
            )
        ) {
            guard case SafetyValidationError.outsideApprovedRoots = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testRejectsProtectedSystemRootsEvenWhenCallerClaimsTheyAreAllowed() {
        let system = URL(fileURLWithPath: "/System", isDirectory: true)
        let library = URL(fileURLWithPath: "/Library", isDirectory: true)

        XCTAssertThrowsError(try validator.validate(system, allowedRoots: [system]))
        XCTAssertThrowsError(try validator.validate(library, allowedRoots: [library]))
    }

    func testRejectsProtectedUserDocuments() throws {
        let documents = homeURL.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = try makeFile(at: documents.appendingPathComponent("important.txt"))

        XCTAssertThrowsError(try validator.validate(file, allowedRoots: [documents])) {
            guard case SafetyValidationError.invalidApprovedRoot = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testRejectsPersistentApplicationSupportButAllowsSpecificCacheRoot() throws {
        let applicationSupport = homeURL.appendingPathComponent(
            "Library/Application Support/Example/Default",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        let state = try makeFile(at: applicationSupport.appendingPathComponent("state.sqlite"))

        XCTAssertThrowsError(
            try validator.validate(state, allowedRoots: [applicationSupport])
        )

        let browserCache = applicationSupport.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: browserCache, withIntermediateDirectories: true)
        let cachedFile = try makeFile(at: browserCache.appendingPathComponent("entry"))
        XCTAssertNoThrow(try validator.validate(cachedFile, allowedRoots: [browserCache]))
    }

    func testRevalidationDetectsChangedFileIdentity() throws {
        let file = try makeFile(at: cacheRoot.appendingPathComponent("changing.cache"))
        let first = try validator.validate(file, allowedRoots: [cacheRoot])
        try Data(repeating: 0xAB, count: 128).write(to: file, options: .atomic)

        XCTAssertThrowsError(try validator.revalidate(first, allowedRoots: [cacheRoot])) {
            guard case SafetyValidationError.targetChanged = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testEveryStandardProviderUsesAnAcceptedRootShape() throws {
        let requiredRoots = [
            homeURL.appendingPathComponent("Library/Caches", isDirectory: true),
            homeURL.appendingPathComponent("Library/Logs", isDirectory: true),
            homeURL.appendingPathComponent(".Trash", isDirectory: true),
            homeURL.appendingPathComponent("Downloads", isDirectory: true),
            homeURL.appendingPathComponent(
                "Library/Containers/com.example.App/Data/Library/Caches",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Caches/Google/Chrome",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Developer/Xcode/DerivedData",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Developer/Xcode/Archives",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Developer/CoreSimulator/Caches",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Developer/Xcode/iOS DeviceSupport",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Caches/org.swift.swiftpm",
                isDirectory: true
            ),
            homeURL.appendingPathComponent(
                "Library/Caches/Homebrew",
                isDirectory: true
            )
        ]
        for root in requiredRoots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let providers: [any CleanupProvider] = [
            UserCacheProvider(homeDirectory: homeURL),
            ApplicationCacheProvider(homeDirectory: homeURL),
            LogProvider(homeDirectory: homeURL),
            TemporaryFilesProvider(temporaryDirectory: sandboxURL),
            TrashProvider(homeDirectory: homeURL),
            BrowserCacheProvider(homeDirectory: homeURL),
            XcodeDerivedDataProvider(homeDirectory: homeURL),
            XcodeArchivesProvider(homeDirectory: homeURL),
            XcodeSimulatorDataProvider(homeDirectory: homeURL),
            XcodeDeviceSupportProvider(homeDirectory: homeURL),
            SwiftPackageCacheProvider(homeDirectory: homeURL),
            HomebrewCacheProvider(homeDirectory: homeURL, environment: [:]),
            DownloadsProvider(homeDirectory: homeURL)
        ]

        for provider in providers {
            let root = try XCTUnwrap(provider.allowedRoots.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }), "No existing root for \(provider.id)")
            let probe = try makeFile(
                at: root.appendingPathComponent("probe-\(provider.id)")
            )
            XCTAssertNoThrow(
                try validator.validate(
                    probe,
                    location: provider.location,
                    allowedRoots: provider.allowedRoots
                ),
                "Rejected standard provider root for \(provider.id)"
            )
        }
    }

    private var validator: SafetyValidator {
        SafetyValidator(homeDirectory: homeURL, temporaryDirectory: sandboxURL)
    }

    @discardableResult
    private func makeFile(at url: URL, contents: Data = Data("cache".utf8)) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url
    }
}
