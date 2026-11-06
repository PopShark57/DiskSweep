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
    /// Reports which files the filters and search show, so review covers only those.
    var reportVisibleFileIDs: (Set<UUID>) -> Void = { _ in }

    /// Groups start collapsed above this many files, so a huge Downloads folder opens fast.
    static let collapseThreshold = 200

    @State private var ageFilter: DownloadsAgeFilter = .any
    @State private var sizeFilter: DownloadsSizeFilter = .any
    @State private var searchText = ""
    @State private var expandedCategories = Set(DownloadsCategory.allCases)
    @State private var highlighted: Set<UUID> = []
    /// Filtered and searched groups, recomputed only when a filter, the search, or the
    /// analysis changes, not on every checkbox click.
    @State private var visibleGroups: [DownloadsGroup] = []
    @FocusState private var isSearchFocused: Bool

    private struct FilterKey: Equatable {
        let age: DownloadsAgeFilter
        let size: DownloadsSizeFilter
        let search: String
        let scannedAt: Date?
    }

    private var filterKey: FilterKey {
        FilterKey(age: ageFilter, size: sizeFilter, search: searchText, scannedAt: analysis?.scannedAt)
    }

    nonisolated static func visibleGroups(
        in analysis: DownloadsAnalysis?,
        filter: DownloadsFilter,
        searchText: String
    ) -> [DownloadsGroup] {
        guard let filtered = analysis?.applying(filter) else { return [] }
        return filtered.groups.compactMap { group in
            let files = searchText.isEmpty ? group.files : group.files.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.url.path.localizedCaseInsensitiveContains(searchText)
            }
            return files.isEmpty ? nil : DownloadsGroup(category: group.category, files: files)
        }
    }

    private func recomputeVisibleGroups() {
        visibleGroups = Self.visibleGroups(
            in: analysis,
            filter: DownloadsFilter(olderThan: ageFilter.interval, largerThan: sizeFilter.bytes),
            searchText: searchText
        )
    }

    private var visibleFileIDs: Set<UUID> {
        Set(visibleGroups.flatMap { $0.files.map(\.id) })
    }

    private var filesByID: [UUID: FileItem] {
        Dictionary(
            visibleGroups.flatMap(\.files).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The size of the selected files the filters show; only these are reviewed.
    private var selectedSize: Int64 {
        visibleGroups
            .flatMap(\.files)
            .filter { selectedFileIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    private var hiddenSelectionCount: Int {
        selectedFileIDs.subtracting(visibleFileIDs).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
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
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: 1040, alignment: .leading)

            if analysis == nil && !isScanning {
                EmptyAnalysisView(
                    title: "Downloads Have Not Been Analyzed",
                    message: "Scanning reads file metadata only and does not select or remove anything.",
                    symbol: "arrow.down.circle",
                    buttonTitle: "Analyze Downloads",
                    action: scan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGroups.isEmpty && !isScanning {
                ContentUnavailableView.search(text: searchText.isEmpty ? "current filters" : searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                filesList
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Downloads")
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .diskSweepFocusSearch)) { _ in
            isSearchFocused = true
        }
        .onChange(of: filterKey, initial: true) { _, _ in
            recomputeVisibleGroups()
        }
        .onChange(of: analysis?.scannedAt, initial: true) { _, _ in
            let count = analysis?.allFiles.count ?? 0
            expandedCategories = count > Self.collapseThreshold ? [] : Set(DownloadsCategory.allCases)
        }
        .onChange(of: visibleFileIDs, initial: true) { _, visible in
            reportVisibleFileIDs(visible)
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSize > 0 || hiddenSelectionCount > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("User files selected")
                            .font(.headline)
                        Text("\(FileSizeFormatter.string(fromByteCount: selectedSize)) — Move to Trash recommended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if hiddenSelectionCount > 0 {
                            Label(
                                "\(hiddenSelectionCount) selected file\(hiddenSelectionCount == 1 ? "" : "s") hidden by filters",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Hidden files aren't reviewed or cleaned. Clear the filters or search to include them.")
                        }
                    }
                    Spacer()
                    Button("Review Selected Files", action: reviewCleanup)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(selectedSize == 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// Lazy, keyboard-navigable: arrows move the highlight, Space toggles the highlighted
    /// files' checkboxes, Return or a double-click opens Quick Look.
    private var filesList: some View {
        List(selection: $highlighted) {
            ForEach(visibleGroups) { group in
                Section {
                    if expandedCategories.contains(group.category) {
                        ForEach(group.files) { file in
                            fileRow(file).tag(file.id)
                        }
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            let checkable = highlighted.intersection(visibleFileIDs)
            guard !checkable.isEmpty else { return .ignored }
            selectedFileIDs = CheckboxToggle.toggled(
                selectedFileIDs,
                highlighted: highlighted,
                checkable: checkable
            )
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

    private func groupHeader(_ group: DownloadsGroup) -> some View {
        HStack(spacing: 10) {
            SectionDisclosureButton(
                isExpanded: Binding(
                    get: { expandedCategories.contains(group.category) },
                    set: { value in
                        if value { expandedCategories.insert(group.category) }
                        else { expandedCategories.remove(group.category) }
                    }
                ),
                title: group.category.name
            )
            Label(group.category.name, systemImage: symbol(for: group.category))
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(group.files.count.formatted()) files")
                .foregroundStyle(.secondary)
            Text(FileSizeFormatter.string(fromByteCount: group.totalSize))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    private func fileRow(_ file: FileItem) -> some View {
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
            .accessibilityLabel("\(file.name), \(FileSizeFormatter.string(fromByteCount: file.size))")

            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
                .accessibilityHidden(true)
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
