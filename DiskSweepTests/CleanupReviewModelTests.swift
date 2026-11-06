import Foundation
import XCTest
@testable import DiskSweep

final class CleanupReviewModelTests: XCTestCase {
    private func item(_ location: CleanupLocation) -> CleanupItem {
        CleanupItem(
            providerID: "p",
            location: location,
            name: location.rawValue,
            url: URL(fileURLWithPath: "/nonexistent/\(location.rawValue)"),
            size: 1,
            kind: .directory,
            risk: location.risk,
            explanation: ""
        )
    }

    func testTrashFirstFoldersStartOnTrashEvenWhenPreferenceIsPermanent() {
        for location in [CleanupLocation.projectArtifacts, .staleIDEVersions] {
            XCTAssertEqual(
                CleanupReviewModel.initialDisposition(items: [item(location)], preference: .permanent),
                .trash,
                "\(location)"
            )
            XCTAssertEqual(
                CleanupReviewModel.initialDisposition(
                    items: [item(location), item(.downloads)],
                    preference: .permanent
                ),
                .trash
            )
        }
    }

    func testOtherSelectionsFollowThePreference() {
        for preference in [CleanupDisposition.trash, .permanent] {
            XCTAssertEqual(
                CleanupReviewModel.initialDisposition(items: [item(.downloads)], preference: preference),
                preference
            )
            XCTAssertEqual(
                CleanupReviewModel.initialDisposition(items: [item(.userCaches)], preference: preference),
                preference
            )
        }
    }
}
