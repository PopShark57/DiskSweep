import AppKit
import Foundation
import QuickLookUI

/// Native Finder and Quick Look integration for scan results.
@MainActor
final class FinderService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = FinderService()

    private var previewURLs: [URL] = []

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

    @discardableResult
    func quickLook(_ url: URL) -> Bool {
        quickLook([url], startingAt: url)
    }

    @discardableResult
    func quickLook(_ urls: [URL], startingAt selectedURL: URL? = nil) -> Bool {
        let fileURLs = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)

        guard !fileURLs.isEmpty, let panel = QLPreviewPanel.shared() else {
            return false
        }

        previewURLs = fileURLs
        panel.dataSource = self

        if let selectedURL {
            let selectedPath = selectedURL.standardizedFileURL.path
            panel.currentPreviewItemIndex = fileURLs.firstIndex {
                $0.path == selectedPath
            } ?? 0
        } else {
            panel.currentPreviewItemIndex = 0
        }

        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func closeQuickLook() {
        QLPreviewPanel.shared()?.orderOut(nil)
        previewURLs = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }
}
