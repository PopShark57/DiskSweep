import SwiftUI

@MainActor
struct DiskSweepCommandActions {
    let isScanning: Bool
    let scan: () -> Void
    let cancelScan: () -> Void
    let focusSearch: () -> Void
    let quickLook: () -> Void
    let revealInFinder: () -> Void
}

private struct DiskSweepCommandActionsKey: FocusedValueKey {
    typealias Value = DiskSweepCommandActions
}

extension FocusedValues {
    var diskSweepCommandActions: DiskSweepCommandActions? {
        get { self[DiskSweepCommandActionsKey.self] }
        set { self[DiskSweepCommandActionsKey.self] = newValue }
    }
}

struct DiskSweepCommands: Commands {
    @FocusedValue(\.diskSweepCommandActions) private var actions

    var body: some Commands {
        CommandMenu("DiskSweep") {
            Button("Scan") { actions?.scan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions == nil || actions?.isScanning == true)

            // Enabled only while a scan runs, so it never relabels a finished scan as partial.
            // ⌘. rather than Esc, so Esc still clears a focused search field.
            Button("Cancel Scan") { actions?.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.isScanning != true)

            Divider()
            Button("Find") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            // ⌘Y, as in Finder. A bare Space menu equivalent would swallow spaces typed in
            // search fields; lists and tables handle Space themselves.
            Button("Quick Look") { actions?.quickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(actions == nil)

            Button("Reveal in Finder") { actions?.revealInFinder() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
