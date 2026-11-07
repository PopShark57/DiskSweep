import Foundation
import XCTest
@testable import DiskSweep

/// 5.3: the component-based `isProtected` must agree with the URL-based implementation it
/// replaced on every path. The old implementation is kept here, verbatim apart from being a
/// free function, so a future change to either is caught.
final class SafetyValidatorEquivalenceTests: XCTestCase {
    private func legacyIsProtected(
        _ url: URL,
        homeDirectory: URL,
        temporaryDirectory: URL,
        additionalProtectedLocations: [URL]
    ) -> Bool {
        func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
            let candidateComponents = candidate.standardizedFileURL.pathComponents
            let rootComponents = root.standardizedFileURL.pathComponents
            guard candidateComponents.count >= rootComponents.count else { return false }
            return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        }
        func isSameOrDescendantCaseInsensitive(_ candidate: URL, of root: URL) -> Bool {
            let candidateComponents = candidate.standardizedFileURL.pathComponents
            let rootComponents = root.standardizedFileURL.pathComponents
            guard candidateComponents.count >= rootComponents.count else { return false }
            return zip(candidateComponents, rootComponents).allSatisfy {
                $0.caseInsensitiveCompare($1) == .orderedSame
            }
        }

        if url.path == "/" { return true }
        let protectedSystemPaths = [
            "/System", "/Library", "/Applications", "/bin", "/sbin",
            "/usr", "/Volumes"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if protectedSystemPaths.contains(where: { isSameOrDescendantCaseInsensitive(url, of: $0) }) {
            return true
        }
        let privateRoot = URL(fileURLWithPath: "/private", isDirectory: true)
        if isSameOrDescendantCaseInsensitive(url, of: privateRoot),
           !isSameOrDescendant(url, of: temporaryDirectory) {
            return true
        }
        let protectedHomePaths = [
            "Desktop", "Documents", "Pictures", "Music", "Movies",
            ".ssh", ".gnupg", "Library/Keychains", "Library/Mail",
            "Library/Messages", "Library/Photos", "Library/Safari",
            "Library/Cookies", "Library/Accounts", "Library/Calendars",
            "Library/CloudStorage", "Library/Application Support/MobileSync"
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        if protectedHomePaths.contains(where: { isSameOrDescendantCaseInsensitive(url, of: $0) }) {
            return true
        }
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if url.path.caseInsensitiveCompare(applicationSupport.path) == .orderedSame {
            return true
        }
        if additionalProtectedLocations.contains(where: { isSameOrDescendantCaseInsensitive(url, of: $0) }) {
            return true
        }
        let components = url.pathComponents.map { $0.lowercased() }
        return components.contains(where: {
            $0.hasSuffix(".photoslibrary")
                || $0.hasSuffix(".photolibrary")
                || $0 == "backups.backupdb"
                || $0 == ".mobilebackups"
        })
    }

    func testComponentIsProtectedMatchesLegacyImplementation() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/private/var/folders/ab/xyz/T", isDirectory: true)
        let additional = [URL(fileURLWithPath: "/Users/tester/Secret Stuff", isDirectory: true)]
        let validator = SafetyValidator(
            homeDirectory: home,
            temporaryDirectory: temporary,
            additionalProtectedLocations: additional
        )

        var paths: [String] = [
            "/", "/System", "/system/Library/x", "/Library", "/LIBRARY/Caches", "/Applications/A.app",
            "/bin", "/sbin/x", "/usr/local/bin", "/Volumes/Disk", "/volumes", "/Users",
            "/private", "/private/etc/hosts", "/PRIVATE/var/db", "/private/var/folders/ab/xyz/T",
            "/private/var/folders/ab/xyz/T/item", "/private/var/folders/ab/xyz/t/item",
            "/private/var/folders/ab/xyz/Tother", "/var/folders/ab/xyz/T/item", "/tmp/x",
            "/Users/tester", "/Users/tester/Library", "/Users/tester/Library/Caches/a",
            "/Users/tester/Library/Application Support", "/users/TESTER/library/application support",
            "/Users/tester/Library/Application Support/App", "/Users/tester/Library/Application Supportx",
            "/Users/tester/Library/Application Support/MobileSync/Backup/1",
            "/Users/tester/Secret Stuff", "/Users/tester/secret stuff/inner", "/Users/tester/Secret Stuffing",
            "/Users/tester/Pictures/My.photoslibrary", "/Users/tester/Downloads/Old.PhotosLibrary/db",
            "/Users/tester/Downloads/x.photolibrary", "/Volumes/Backup/Backups.backupdb/x",
            "/Users/tester/Downloads/.MobileBackups/x", "/Users/tester/Downloads/backups.backupdbx",
            "/Users/tester/Desktop", "/Users/tester/Desktopx", "/Users/tester/.ssh/id",
            "/Users/tester/.sshx", "/Users/tester/Library/Keychains/login", "/Users/tester/Library/Mail",
            "/Users/tester/library/mail/V10", "/Users/tester/Library/CloudStorage/x",
            "/Users/other/Documents", "/Users/tester/Documents/../Downloads/file",
            "/Users/tester/Old.photoslibrary/../Downloads/file", "/Users/tester/Library/Caches/./x"
        ]
        // Generate more: every protected home folder in several casings and depths.
        let names = SafetyValidator.protectedHomeRelativePaths + ["Downloads", "Developer", "Library/Caches"]
        for name in names {
            for variant in [name, name.lowercased(), name.uppercased()] {
                paths.append("/Users/tester/\(variant)")
                paths.append("/Users/tester/\(variant)/child")
                paths.append("/Users/tester/\(variant)x/child")
            }
        }
        XCTAssertGreaterThanOrEqual(paths.count, 200)

        for path in paths {
            let url = URL(fileURLWithPath: path)
            XCTAssertEqual(
                validator.isProtected(url),
                legacyIsProtected(
                    url,
                    homeDirectory: home,
                    temporaryDirectory: temporary,
                    additionalProtectedLocations: additional
                ),
                path
            )
        }
    }

    /// Negative: a cache folder holding a Time Machine store or a photo library is still
    /// refused by the pre-delete walk after 5.3.
    func testPreDeleteWalkStillRefusesProtectedDescendants() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepEquivalence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("Home", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let validator = SafetyValidator(homeDirectory: home, temporaryDirectory: sandbox)

        for protectedName in ["Backups.backupdb", ".MobileBackups"] {
            let target = caches.appendingPathComponent("com.example.\(UUID().uuidString)", isDirectory: true)
            let inner = target.appendingPathComponent("\(protectedName)/data", isDirectory: false)
            try FileManager.default.createDirectory(
                at: inner.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: inner)

            let validated = try validator.validate(target, allowedRoots: [caches])
            XCTAssertThrowsError(try validator.validateDirectoryContents(validated, exclusionRoots: [])) {
                switch $0 {
                case SafetyValidationError.protectedLocation, SafetyValidationError.excludedContent:
                    break
                default:
                    XCTFail("Unexpected error for \(protectedName): \($0)")
                }
            }
        }
    }
}
