import AppKit
import Foundation

/// Native Finder integration for scan results. Quick Look is presented by SwiftUI's
/// `quickLookPreview` modifier in `RootView`, driven by `AppViewModel.quickLookURL`, so
/// the preview panel's data source is managed by the framework rather than set by hand.
@MainActor
final class FinderService {
    static let shared = FinderService()

    func revealInFinder(_ url: URL) {
        revealInFinder([url])
    }

    func revealInFinder(_ urls: [URL]) {
        let fileURLs = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)

        guard !fileURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
    }
}
