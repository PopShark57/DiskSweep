import SwiftUI

struct DuplicatesView: View {
    let groups: [DuplicateGroup]
    @Binding var selectedFileIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void
    let quickLook: (URL) -> Void

    @State private var highlighted: Set<UUID> = []

    private var selectedSavings: Int64 {
        groups.reduce(0) { partial, group in
            partial + group.files
                .filter { selectedFileIDs.contains($0.id) }
                .reduce(0) { $0 + $1.size }
        }
    }

    private var filesByID: [UUID: FileItem] {
        Dictionary(
            groups.flatMap(\.files).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
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
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 1040, alignment: .leading)

            if groups.isEmpty && !isScanning {
                EmptyAnalysisView(
                    title: "No Duplicate Scan Yet",
                    message: "Scan your home folder. Expensive and sensitive locations are excluded by default.",
                    symbol: "square.on.square",
                    buttonTitle: "Find Duplicates",
                    action: scan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                duplicatesList
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSavings > 0 {
                Label(
                    "\(FileSizeFormatter.string(fromByteCount: selectedSavings)) selected for review. Use Finder to inspect copies before removing them.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// Groups arrive sorted by the analyzer. Arrows move the highlight, Space toggles the
    /// highlighted copies (always leaving one copy per group unselected), and Return or a
    /// double-click opens Quick Look.
    private var duplicatesList: some View {
        List(selection: $highlighted) {
            ForEach(groups) { group in
                Section {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                        fileRow(file, index: index, group: group).tag(file.id)
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(group.files.count) Identical Copies")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Potential savings: \(FileSizeFormatter.string(fromByteCount: group.reclaimableSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(FileSizeFormatter.string(fromByteCount: group.fileSize) + " each")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            guard !highlighted.isEmpty else { return .ignored }
            var updated = CheckboxToggle.toggled(
                selectedFileIDs,
                highlighted: highlighted,
                checkable: highlighted
            )
            for group in groups {
                let ids = Set(group.files.map(\.id))
                let kept = DuplicateSelection.preservingOneCopy(updated.intersection(ids), in: group)
                updated.subtract(ids)
                updated.formUnion(kept)
            }
            selectedFileIDs = updated
            return .handled
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let file = ids.first.flatMap({ filesByID[$0] }) {
                Button("Quick Look") { quickLook(file.url) }
                Button("Reveal in Finder") { reveal(file.url) }
            }
        } primaryAction: { ids in
            if let file = ids.first.flatMap({ filesByID[$0] }) {
                quickLook(file.url)
            }
        }
    }

    private func fileRow(_ file: FileItem, index: Int, group: DuplicateGroup) -> some View {
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
                .accessibilityHidden(true)

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
                .accessibilityLabel("Quick Look \(file.name)")
            Button { reveal(file.url) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(file.name) in Finder")
        }
        .padding(.vertical, 3)
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
