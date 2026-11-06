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

    /// Locks in the engine's disposition rule for every location; the review sheet's badges
    /// use the same function.
    func testEngineDispositionForEveryLocation() {
        for location in CleanupLocation.allCases {
            let item = item(location)
            for requested in [nil, CleanupDisposition.trash, .permanent] {
                let expected: CleanupDisposition
                if location == .trash {
                    expected = .permanent
                } else if location.defaultsToTrash || location.risk == .userFiles {
                    expected = requested ?? .trash
                } else {
                    expected = .permanent
                }
                XCTAssertEqual(
                    CleanupEngine.disposition(for: item, requested: requested),
                    expected,
                    "\(location) requested \(String(describing: requested))"
                )
            }
        }
        // Spot checks that pin the policy itself, not just the formula above.
        XCTAssertEqual(CleanupEngine.disposition(for: item(.userCaches), requested: .trash), .permanent)
        XCTAssertEqual(CleanupEngine.disposition(for: item(.trash), requested: .trash), .permanent)
        XCTAssertEqual(CleanupEngine.disposition(for: item(.downloads), requested: nil), .trash)
        XCTAssertEqual(CleanupEngine.disposition(for: item(.projectArtifacts), requested: .permanent), .permanent)
    }

    func testGroupDispositionsFollowThePickerOnlyForTrashFirstGroups() {
        XCTAssertEqual(CleanupReviewModel.dispositions(of: [item(.projectArtifacts)], requested: .permanent), [.permanent])
        XCTAssertEqual(CleanupReviewModel.dispositions(of: [item(.projectArtifacts)], requested: .trash), [.trash])
        XCTAssertEqual(CleanupReviewModel.dispositions(of: [item(.xcodeDerivedData)], requested: .trash), [.permanent])
    }
}
