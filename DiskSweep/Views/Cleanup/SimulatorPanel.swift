import SwiftUI

/// Finds simulators whose runtime is gone and removes them with `simctl`.
struct SimulatorPanel: View {
    let check: SimulatorCheck
    let checkNow: () -> Void
    let deleteAll: () -> Void

    @State private var confirmsDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Unavailable Simulators")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .found(devices) = check, !devices.isEmpty {
                    DisclosureGroup("Show \(devices.count) simulator\(devices.count == 1 ? "" : "s")") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(devices) { device in
                                Text("\(device.name) — \(device.runtime)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                }
            }

            Spacer()

            switch check {
            case .checking, .deleting:
                ProgressView().controlSize(.small)
            case let .found(devices) where !devices.isEmpty:
                Button("Delete Unavailable Simulators…") { confirmsDelete = true }
            default:
                Button("Check", action: checkNow)
            }
        }
        .cardSurface(padding: 14)
        .confirmationDialog(
            "Delete unavailable simulators?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DiskSweep runs “xcrun simctl delete unavailable”, which permanently removes every simulator whose runtime is no longer installed, with its apps and data. Simulators you can still run aren't affected.")
        }
    }

    private var summary: String {
        switch check {
        case .notChecked:
            "Simulators whose iOS, watchOS, tvOS, or visionOS runtime was removed can't run and still use space. Check uses Xcode's simctl."
        case .checking:
            "Checking with simctl…"
        case let .found(devices):
            devices.isEmpty
                ? "No unavailable simulators."
                : "\(devices.count) simulator\(devices.count == 1 ? " has" : "s have") no installed runtime."
        case .deleting:
            "Deleting with simctl…"
        case let .failed(message):
            message
        }
    }
}
