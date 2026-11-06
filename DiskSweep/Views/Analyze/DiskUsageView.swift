import SwiftUI

/// Large Folders and Disk Usage share one analysis, so they're one screen with two modes.
struct DiskUsageView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list
        case map

        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: "List"
            case .map: "Map"
            }
        }
    }

    let root: DirectoryNode?
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void

    @State private var mode: Mode = .list

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Disk Usage",
                    subtitle: "See which folders in your home folder use the most space, as a list or a map. Nothing is changed.",
                    symbol: "chart.pie"
                )

                HStack(spacing: 12) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)

                    Spacer()

                    if isScanning {
                        ProgressView().controlSize(.small)
                        Text("Calculating folder sizes…")
                            .foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel, action: cancel)
                    } else {
                        Button(root == nil ? "Analyze Home Folder" : "Rescan", action: scan)
                            .buttonStyle(.borderedProminent)
                    }
                }

                if let root, !isScanning {
                    switch mode {
                    case .list:
                        FolderTreeList(roots: root.children, reveal: reveal)
                    case .map:
                        DiskUsageMap(root: root, reveal: reveal)
                    }
                } else if !isScanning {
                    EmptyAnalysisView(
                        title: "No Folder Analysis Yet",
                        message: "Analyze your home folder to build a browsable size tree and map.",
                        symbol: "chart.pie",
                        buttonTitle: "Analyze Home Folder",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }
}
