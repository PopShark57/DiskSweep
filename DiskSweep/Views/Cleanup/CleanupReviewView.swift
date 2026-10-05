import SwiftUI

struct CleanupReviewView: View {
    let items: [CleanupItem]
    let isCleaning: Bool
    let clean: (CleanupDisposition) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var userFileDisposition: CleanupDisposition

    init(
        items: [CleanupItem],
        isCleaning: Bool,
        preferredUserFileDisposition: CleanupDisposition,
        clean: @escaping (CleanupDisposition) -> Void
    ) {
        self.items = items
        self.isCleaning = isCleaning
        self.clean = clean
        _userFileDisposition = State(initialValue: preferredUserFileDisposition)
    }

    private var groups: [(location: CleanupLocation, items: [CleanupItem])] {
        Dictionary(grouping: items, by: \.location)
            .map { (location: $0.key, items: $0.value) }
            .sorted { $0.location.name < $1.location.name }
    }

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var includesUserFiles: Bool { items.contains { $0.risk == .userFiles } }
    private var includesProjectArtifacts: Bool {
        items.contains { $0.location == .projectArtifacts }
    }
    private var includesTrash: Bool { items.contains { $0.location == .trash } }

    private var dispositionTitle: String {
        switch (includesUserFiles, includesProjectArtifacts) {
        case (true, true): "User file and project artifact handling"
        case (false, true): "Project artifact handling"
        default: "User file handling"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to Clean")
                        .font(.title.weight(.semibold))
                    Text("Review the exact categories and size before DiskSweep makes changes.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.location) { group in
                        HStack(spacing: 12) {
                            Image(systemName: group.location.symbolName)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.location.name)
                                    .font(.headline)
                                Text("\(group.items.reduce(0) { $0 + $1.fileCount }.formatted()) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(FileSizeFormatter.string(fromByteCount: group.items.reduce(0) { $0 + $1.size }))
                                .font(.headline)
                                .monospacedDigit()
                        }
                        .cardSurface(padding: 14)
                    }

                    if includesUserFiles || includesProjectArtifacts {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dispositionTitle)
                                .font(.headline)
                            Picker(dispositionTitle, selection: $userFileDisposition) {
                                Label("Move to Trash", systemImage: "trash").tag(CleanupDisposition.trash)
                                Label("Delete Permanently", systemImage: "trash.slash").tag(CleanupDisposition.permanent)
                            }
                            .pickerStyle(.segmented)
                            Text(
                                userFileDisposition == .trash
                                ? "Recommended. You can restore these files from Trash until it is emptied."
                                : "Permanent deletion cannot be undone."
                            )
                            .font(.caption)
                            .foregroundStyle(userFileDisposition == .trash ? Color.secondary : Color.red)
                        }
                        .cardSurface()
                    }

                    if includesTrash {
                        Label(
                            "Selected Trash items will be deleted permanently. This cannot be undone.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .cardSurface()
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(FileSizeFormatter.string(fromByteCount: totalSize))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCleaning)

                Button {
                    clean(userFileDisposition)
                } label: {
                    if isCleaning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Cleaning…")
                        }
                    } else {
                        Text("Clean \(FileSizeFormatter.string(fromByteCount: totalSize))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isCleaning || items.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
        .interactiveDismissDisabled(isCleaning)
    }
}
