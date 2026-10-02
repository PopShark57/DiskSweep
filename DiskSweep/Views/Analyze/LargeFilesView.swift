import SwiftUI

enum LargeFileSort: String, CaseIterable, Identifiable {
    case size
    case name
    case date
    case type

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct LargeFilesView: View {
    let files: [FileItem]
    @Binding var threshold: Int64
    @Binding var selectedFileID: UUID?
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void
    let quickLook: (URL) -> Void

    @State private var sort: LargeFileSort = .size
    @State private var searchText = ""
    @State private var customThresholdMB = 250
    @FocusState private var isSearchFocused: Bool

    private let thresholds: [(String, Int64)] = [
        ("> 100 MB", 100_000_000),
        ("> 500 MB", 500_000_000),
        ("> 1 GB", 1_000_000_000),
        ("> 5 GB", 5_000_000_000)
    ]

    private var visibleFiles: [FileItem] {
        let filtered = files.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.path.localizedCaseInsensitiveContains(searchText)
        }

        switch sort {
        case .size:
            return filtered.sorted { $0.size > $1.size }
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            return filtered.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .type:
            return filtered.sorted {
                if $0.fileExtension == $1.fileExtension { return $0.size > $1.size }
                return $0.fileExtension < $1.fileExtension
            }
        }
    }

    private var selectedFile: FileItem? {
        files.first { $0.id == selectedFileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "Large Files",
                    subtitle: "Find unusually large files in your home folder. DiskSweep recommends review, not deletion.",
                    symbol: "doc.text.magnifyingglass"
                )

                HStack(spacing: 12) {
                    Picker("Minimum size", selection: $threshold) {
                        ForEach(thresholds, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                        Text("Custom").tag(Int64(customThresholdMB) * 1_000_000)
                    }
                    .frame(width: 150)

                    if !thresholds.contains(where: { $0.1 == threshold }) {
                        Stepper(
                            "\(customThresholdMB) MB",
                            value: $customThresholdMB,
                            in: 1...100_000,
                            step: 50
                        )
                        .onChange(of: customThresholdMB) { _, newValue in
                            threshold = Int64(newValue) * 1_000_000
                        }
                    }

                    Picker("Sort", selection: $sort) {
                        ForEach(LargeFileSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 130)

                    Spacer()

                    if isScanning {
                        ProgressView().controlSize(.small)
                        Button("Cancel", role: .cancel, action: cancel)
                    } else {
                        Button("Scan Home Folder", action: scan)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(28)

            Divider()

            if files.isEmpty && !isScanning {
                EmptyAnalysisView(
                    title: "No Large-File Scan Yet",
                    message: "Choose a threshold and scan. Files remain untouched.",
                    symbol: "doc.text.magnifyingglass",
                    buttonTitle: "Scan Home Folder",
                    action: scan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(visibleFiles, selection: $selectedFileID) {
                    TableColumn("Name") { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).lineLimit(1)
                                Text(file.url.deletingLastPathComponent().path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .width(min: 260, ideal: 430)

                    TableColumn("Size") { file in
                        Text(FileSizeFormatter.string(fromByteCount: file.size))
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Type") { file in
                        Text(file.fileExtension.uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Modified") { file in
                        if let date = file.modifiedAt {
                            Text(date, format: .dateTime.year().month().day())
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 100, ideal: 130)

                    TableColumn("Accessed") { file in
                        if let date = file.accessedAt {
                            Text(date, format: .dateTime.year().month().day())
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 100, ideal: 130)
                }
                .contextMenu(forSelectionType: UUID.self) { selection in
                    if let id = selection.first, let file = files.first(where: { $0.id == id }) {
                        Button("Quick Look") { quickLook(file.url) }
                        Button("Reveal in Finder") { reveal(file.url) }
                    }
                } primaryAction: { selection in
                    if let id = selection.first, let file = files.first(where: { $0.id == id }) {
                        quickLook(file.url)
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search files")
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .diskSweepFocusSearch)) { _ in
            isSearchFocused = true
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if let selectedFile { quickLook(selectedFile.url) }
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .disabled(selectedFile == nil)

                Button {
                    if let selectedFile { reveal(selectedFile.url) }
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(selectedFile == nil)
            }
        }
    }
}
