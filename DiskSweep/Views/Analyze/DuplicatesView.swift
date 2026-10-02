import SwiftUI

struct DuplicatesView: View {
    let groups: [DuplicateGroup]
    @Binding var selectedFileIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void
    let quickLook: (URL) -> Void

    private var selectedSavings: Int64 {
        groups.reduce(0) { partial, group in
            partial + group.files
                .filter { selectedFileIDs.contains($0.id) }
                .reduce(0) { $0 + $1.size }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Duplicates",
                    subtitle: "Size, sample, cryptographic hash, and byte-for-byte verification—all must agree.",
                    symbol: "square.on.square"
                )

                HStack {
                    Label(
                        "DiskSweep never identifies duplicates by filename alone and always leaves at least one copy unselected.",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.small)
                        Button("Cancel", role: .cancel, action: cancel)
                    } else {
                        Button("Find Duplicates", action: scan)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .cardSurface()

                if groups.isEmpty && !isScanning {
                    EmptyAnalysisView(
                        title: "No Duplicate Scan Yet",
                        message: "Scan your home folder. Expensive and sensitive locations are excluded by default.",
                        symbol: "square.on.square",
                        buttonTitle: "Find Duplicates",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    ForEach(groups.sorted { $0.reclaimableSize > $1.reclaimableSize }) { group in
                        duplicateGroup(group)
                    }
                }

                if selectedSavings > 0 {
                    Label(
                        "\(FileSizeFormatter.string(fromByteCount: selectedSavings)) selected for review. Use Finder to inspect copies before removing them.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    private func duplicateGroup(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(group.files.count) Identical Copies")
                        .font(.headline)
                    Text("Potential savings: \(FileSizeFormatter.string(fromByteCount: group.reclaimableSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(FileSizeFormatter.string(fromByteCount: group.fileSize) + " each")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            .padding(16)

            Divider()

            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 12) {
                    Toggle(
                        isOn: Binding(
                            get: { selectedFileIDs.contains(file.id) },
                            set: { value in updateSelection(value, file: file, group: group) }
                        )
                    ) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(index == 0 ? "Keep \(file.name)" : "Select duplicate \(file.name)")

                    Image(systemName: index == 0 ? "checkmark.shield.fill" : "doc.on.doc")
                        .foregroundStyle(index == 0 ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1)
                        Text(file.url.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if index == 0 && !selectedFileIDs.contains(file.id) {
                        Text("Keep")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    Button { quickLook(file.url) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .help("Quick Look")
                    Button { reveal(file.url) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if file.id != group.files.last?.id { Divider().padding(.leading, 48) }
            }
        }
        .cardSurface(padding: 0)
    }

    private func updateSelection(_ value: Bool, file: FileItem, group: DuplicateGroup) {
        if value {
            let unselectedCount = group.files.filter { !selectedFileIDs.contains($0.id) }.count
            guard unselectedCount > 1 else { return }
            selectedFileIDs.insert(file.id)
        } else {
            selectedFileIDs.remove(file.id)
        }
    }
}
