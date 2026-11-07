import Foundation
import XCTest
@testable import DiskSweep

final class URLContainmentTests: XCTestCase {
    private struct Case {
        let candidate: String
        let root: String
        let sameOrDescendant: Bool
        let strictDescendant: Bool
        let ignoringCase: Bool
    }

    private let cases: [Case] = [
        // The same path.
        Case(candidate: "/a/b", root: "/a/b", sameOrDescendant: true, strictDescendant: false, ignoringCase: true),
        // A child and a deeper descendant.
        Case(candidate: "/a/b/c", root: "/a/b", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        Case(candidate: "/a/b/c/d", root: "/a/b", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        // A sibling that shares a string prefix is not inside.
        Case(candidate: "/a/bc", root: "/a/b", sameOrDescendant: false, strictDescendant: false, ignoringCase: false),
        Case(candidate: "/a/b c/d", root: "/a/b", sameOrDescendant: false, strictDescendant: false, ignoringCase: false),
        // The parent is not inside the child.
        Case(candidate: "/a", root: "/a/b", sameOrDescendant: false, strictDescendant: false, ignoringCase: false),
        // Trailing slashes don't matter.
        Case(candidate: "/a/b/", root: "/a/b", sameOrDescendant: true, strictDescendant: false, ignoringCase: true),
        Case(candidate: "/a/b/c", root: "/a/b/", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        // Everything is inside the filesystem root.
        Case(candidate: "/a", root: "/", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        Case(candidate: "/", root: "/", sameOrDescendant: true, strictDescendant: false, ignoringCase: true),
        // Case differences only match the case-insensitive variant.
        Case(candidate: "/A/b/c", root: "/a/B", sameOrDescendant: false, strictDescendant: false, ignoringCase: true),
        Case(candidate: "/Users/x/LIBRARY/Caches", root: "/Users/x/Library", sameOrDescendant: false, strictDescendant: false, ignoringCase: true),
        // `..` is resolved by standardization before comparing.
        Case(candidate: "/a/b/../c", root: "/a/b", sameOrDescendant: false, strictDescendant: false, ignoringCase: false),
        Case(candidate: "/a/x/../b/c", root: "/a/b", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        Case(candidate: "/a/b/./c", root: "/a/b", sameOrDescendant: true, strictDescendant: true, ignoringCase: true),
        // Unrelated paths.
        Case(candidate: "/x/y", root: "/a/b", sameOrDescendant: false, strictDescendant: false, ignoringCase: false)
    ]

    func testContainmentTable() {
        for item in cases {
            let candidate = URL(fileURLWithPath: item.candidate)
            let root = URL(fileURLWithPath: item.root)
            XCTAssertEqual(
                candidate.isSameOrDescendant(of: root), item.sameOrDescendant,
                "isSameOrDescendant \(item.candidate) in \(item.root)"
            )
            XCTAssertEqual(
                candidate.isStrictDescendant(of: root), item.strictDescendant,
                "isStrictDescendant \(item.candidate) in \(item.root)"
            )
            XCTAssertEqual(
                candidate.isSameOrDescendantIgnoringCase(of: root), item.ignoringCase,
                "isSameOrDescendantIgnoringCase \(item.candidate) in \(item.root)"
            )
        }
    }

    /// `AnalyzerFileSystem` used a string-prefix comparison before 1.1. It must agree with the
    /// component comparison on every case, including trailing slashes, so replacing it changes
    /// no analyzer result.
    func testLegacyStringPrefixContainmentAgreesWithComponentContainment() {
        func legacyContains(_ candidate: URL, in root: URL) -> Bool {
            let candidatePath = candidate.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            guard candidatePath != rootPath else { return true }
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            return candidatePath.hasPrefix(prefix)
        }

        for item in cases {
            let candidate = URL(fileURLWithPath: item.candidate)
            let root = URL(fileURLWithPath: item.root)
            XCTAssertEqual(
                legacyContains(candidate, in: root),
                candidate.isSameOrDescendant(of: root),
                "\(item.candidate) in \(item.root)"
            )
        }
    }

    /// The safety validator's case-insensitive check must never treat a sibling that only
    /// differs by a suffix as protected-root content, or vice versa.
    func testCaseInsensitiveContainmentStillRequiresWholeComponents() {
        let documents = URL(fileURLWithPath: "/Users/x/Documents")
        XCTAssertTrue(URL(fileURLWithPath: "/users/X/documents/file").isSameOrDescendantIgnoringCase(of: documents))
        XCTAssertFalse(URL(fileURLWithPath: "/Users/x/Documents2/file").isSameOrDescendantIgnoringCase(of: documents))
    }
}
