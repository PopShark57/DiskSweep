import SwiftUI

@MainActor
struct DiskSweepCommandActions {
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
                .disabled(actions == nil)

            Button("Rescan") { actions?.scan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Button("Cancel Scan") { actions?.cancelScan() }
                .keyboardShortcut(.cancelAction)
                .disabled(actions == nil)

            Divider()
            Button("Find") { actions?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Quick Look") { actions?.quickLook() }
                .keyboardShortcut(" ", modifiers: [])
                .disabled(actions == nil)

            Button("Reveal in Finder") { actions?.revealInFinder() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
