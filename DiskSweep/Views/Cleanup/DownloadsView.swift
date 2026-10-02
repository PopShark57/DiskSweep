import SwiftUI

private enum DownloadsAgeFilter: String, CaseIterable, Identifiable {
    case any
    case thirtyDays
    case ninetyDays
    case oneYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Age"
        case .thirtyDays: "Older than 30 days"
        case .ninetyDays: "Older than 90 days"
        case .oneYear: "Older than 1 year"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .any: nil
        case .thirtyDays: 30 * 24 * 60 * 60
        case .ninetyDays: 90 * 24 * 60 * 60
        case .oneYear: 365 * 24 * 60 * 60
        }
    }
}

private enum DownloadsSizeFilter: String, CaseIterable, Identifiable {
    case any
    case hundredMB
    case oneGB

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Size"
        case .hundredMB: "Larger than 100 MB"
        case .oneGB: "Larger than 1 GB"
        }
    }

    var bytes: Int64? {
        switch self {
        case .any: nil
        case .hundredMB: 100 * 1_024 * 1_024
        case .oneGB: 1_024 * 1_024 * 1_024
        }
    }
}

struct DownloadsView: View {
    let analysis: DownloadsAnalysis?
    @Binding var selectedFileIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reviewCleanup: () -> Void
    let reveal: (URL) -> Void
    let quickLook: (URL) -> Void

    @State private var ageFilter: DownloadsAgeFilter = .any
    @State private var sizeFilter: DownloadsSizeFilter = .any
    @State private var searchText = ""
    @State private var expandedCategories = Set(DownloadsCategory.allCases)
    @FocusState private var isSearchFocused: Bool

    private var filteredAnalysis: DownloadsAnalysis? {
        analysis?.applying(DownloadsFilter(
            olderThan: ageFilter.interval,
            largerThan: sizeFilter.bytes
        ))
    }

    private var visibleGroups: [DownloadsGroup] {
        guard let filteredAnalysis else { return [] }
        return filteredAnalysis.groups.compactMap { group in
            let files = group.files.filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.url.path.localizedCaseInsensitiveContains(searchText)
            }
            return files.isEmpty ? nil : DownloadsGroup(category: group.category, files: files)
        }
    }

    private var selectedSize: Int64 {
        guard let analysis else { return 0 }
        return analysis.allFiles
            .filter { selectedFileIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Downloads",
                    subtitle: "Group installers, archives, media, and documents for deliberate review.",
                    symbol: "arrow.down.circle"
                )

                Label(
                    "Downloads are user files. DiskSweep never selects them automatically and prefers moving chosen files to Trash.",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.blue)
                .cardSurface()

                HStack(spacing: 12) {
                    Picker("Age", selection: $ageFilter) {
                        ForEach(DownloadsAgeFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 190)

                    Picker("Size", selection: $sizeFilter) {
                        ForEach(DownloadsSizeFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 190)

                    Spacer()

                    if isScanning {
                        ProgressView().controlSize(.small)
                        Button("Cancel", role: .cancel, action: cancel)
                    } else {
                        Button(analysis == nil ? "Analyze Downloads" : "Rescan", action: scan)
                            .buttonStyle(.borderedProminent)
                    }
                }

                if analysis == nil && !isScanning {
                    EmptyAnalysisView(
                        title: "Downloads Have Not Been Analyzed",
                        message: "Scanning reads file metadata only and does not select or remove anything.",
                        symbol: "arrow.down.circle",
                        buttonTitle: "Analyze Downloads",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 380)
                } else if visibleGroups.isEmpty && !isScanning {
                    ContentUnavailableView.search(text: searchText.isEmpty ? "current filters" : searchText)
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ForEach(visibleGroups) { group in
                        downloadsGroup(group)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Downloads")
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .diskSweepFocusSearch)) { _ in
            isSearchFocused = true
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSize > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("User files selected")
                            .font(.headline)
                        Text("\(FileSizeFormatter.string(fromByteCount: selectedSize)) — Move to Trash recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review Selected Files", action: reviewCleanup)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private func downloadsGroup(_ group: DownloadsGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedCategories.contains(group.category) },
                set: { value in
                    if value { expandedCategories.insert(group.category) }
                    else { expandedCategories.remove(group.category) }
                }
            )
        ) {
            VStack(spacing: 0) {
                ForEach(group.files) { file in
                    HStack(spacing: 12) {
                        Toggle(
                            isOn: Binding(
                                get: { selectedFileIDs.contains(file.id) },
                                set: { value in
                                    if value { selectedFileIDs.insert(file.id) }
                                    else { selectedFileIDs.remove(file.id) }
                                }
                            )
                        ) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Select \(file.name)")

                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            HStack(spacing: 8) {
                                Text(file.fileExtension.uppercased())
                                if let modifiedAt = file.modifiedAt {
                                    Text(modifiedAt, format: .dateTime.year().month().day())
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(FileSizeFormatter.string(fromByteCount: file.size))
                            .monospacedDigit()
                        Button { quickLook(file.url) } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless)
                            .help("Quick Look")
                        Button { reveal(file.url) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                    }
                    .padding(.vertical, 9)
                    if file.id != group.files.last?.id { Divider() }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Label(group.category.name, systemImage: symbol(for: group.category))
                    .font(.headline)
                Spacer()
                Text("\(group.files.count.formatted()) files")
                    .foregroundStyle(.secondary)
                Text(FileSizeFormatter.string(fromByteCount: group.totalSize))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
        .cardSurface()
    }

    private func symbol(for category: DownloadsCategory) -> String {
        switch category {
        case .diskImages: "externaldrive.badge.plus"
        case .archives: "archivebox"
        case .installers: "shippingbox"
        case .videos: "film"
        case .images: "photo"
        case .documents: "doc.text"
        case .other: "doc"
        }
    }
}
