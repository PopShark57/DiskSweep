import SwiftUI

/// The menu bar extra: free space, the last scan's reclaimable total, and quick actions.
struct MenuBarContent: View {
    @Bindable var model: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.diskStatistics.volumeName): \(FileSizeFormatter.string(fromByteCount: model.diskStatistics.available)) free")
        if model.diskStatistics.reclaimable > 0 {
            Text("\(FileSizeFormatter.string(fromByteCount: model.diskStatistics.reclaimable)) can be cleaned")
        }
        Divider()
        Button(model.isCleanupScanning ? "Scanning…" : "Scan") {
            model.startCleanupScan()
            showMainWindow()
        }
        .disabled(model.isCleanupScanning)
        Button("Open DiskSweep") { showMainWindow() }
        Divider()
        Button("Quit DiskSweep") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMainWindow() {
        openWindow(id: DiskSweepApp.mainWindowID)
        NSApplication.shared.activate()
    }
}
