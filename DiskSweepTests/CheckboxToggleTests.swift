import Foundation
import XCTest
@testable import DiskSweep

final class CheckboxToggleTests: XCTestCase {
    func testSpaceChecksAllHighlightedUnlessAllAreChecked() {
        let a = UUID(), b = UUID(), c = UUID(), locked = UUID()
        let checkable: Set<UUID> = [a, b, c]

        // Mixed: everything highlighted becomes checked; non-checkable rows are ignored.
        XCTAssertEqual(
            CheckboxToggle.toggled([a], highlighted: [a, b, locked], checkable: checkable),
            [a, b]
        )
        // All highlighted already checked: they're unchecked, others untouched.
        XCTAssertEqual(
            CheckboxToggle.toggled([a, b, c], highlighted: [a, b], checkable: checkable),
            [c]
        )
        // Nothing checkable highlighted: no change.
        XCTAssertEqual(
            CheckboxToggle.toggled([a], highlighted: [locked], checkable: checkable),
            [a]
        )
    }

    /// 5.6: the Downloads screen's cached filter gives the same groups as filtering inline.
    func testDownloadsVisibleGroupsMatchFilterAndSearch() {
        let now = Date()
        let root = URL(fileURLWithPath: "/nonexistent/Downloads", isDirectory: true)
        let old = FileItem(url: root.appendingPathComponent("old.dmg"), size: 200_000_000, kind: .file,
                           modifiedAt: now.addingTimeInterval(-400 * 86_400))
        let new = FileItem(url: root.appendingPathComponent("new.zip"), size: 10, kind: .file, modifiedAt: now)
        let analysis = DownloadsAnalysis(
            root: root, allFiles: [old, new], groups: [], filter: .all, issues: [], scannedAt: now
        ).applying(.all)

        let all = DownloadsView.visibleGroups(in: analysis, filter: .all, searchText: "")
        XCTAssertEqual(Set(all.flatMap(\.files).map(\.id)), [old.id, new.id])

        let older = DownloadsView.visibleGroups(in: analysis, filter: .olderThanOneYear, searchText: "")
        XCTAssertEqual(older.flatMap(\.files).map(\.id), [old.id])

        let searched = DownloadsView.visibleGroups(in: analysis, filter: .all, searchText: "NEW")
        XCTAssertEqual(searched.flatMap(\.files).map(\.id), [new.id])
    }
}
