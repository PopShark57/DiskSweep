import SwiftUI

/// What Space does in a list with checkboxes: it toggles the checkboxes of the highlighted
/// rows. If every highlighted row that can be checked is checked, they're all unchecked;
/// otherwise they're all checked.
enum CheckboxToggle {
    static func toggled(
        _ checked: Set<UUID>,
        highlighted: Set<UUID>,
        checkable: Set<UUID>
    ) -> Set<UUID> {
        let targets = highlighted.intersection(checkable)
        guard !targets.isEmpty else { return checked }
        return targets.isSubset(of: checked)
            ? checked.subtracting(targets)
            : checked.union(targets)
    }
}

/// The disclosure button at the start of a list section header.
struct SectionDisclosureButton: View {
    @Binding var isExpanded: Bool
    let title: String

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    }
}

/// One cleanup item: checkbox, name, path, optional detail and unavailable reason, size.
struct CleanupItemRow: View {
    let item: CleanupItem
    @Binding var isChecked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isChecked) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isDeletable)
                .accessibilityLabel(
                    "\(item.name), \(FileSizeFormatter.string(fromByteCount: item.size))"
                )

            Image(systemName: item.kind == .directory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.url.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let reason = item.unavailableReason {
                    Label(reason, systemImage: "nosign")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Text(FileSizeFormatter.string(fromByteCount: item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(item.explanation)
    }
}

/// Scan categories as a lazy, keyboard-navigable list. Arrow keys move the highlight,
/// ⌘A highlights everything, Space toggles the highlighted rows' checkboxes, and Return or
/// a double-click opens Quick Look. The checkboxes, not the highlight, decide what's cleaned.
struct CleanupItemsList: View {
    let categories: [CleanupCategory]
    @Binding var checkedItemIDs: Set<UUID>
    var searchText: String = ""
    var startsExpanded = false
    let quickLook: (URL) -> Void
    let reveal: (URL) -> Void

    @State private var highlighted: Set<UUID> = []
    @State private var expanded: Set<CleanupLocation> = []
    @State private var collapsed: Set<CleanupLocation> = []

    private var itemsByID: [UUID: CleanupItem] {
        Dictionary(
            categories.flatMap(\.items).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func visibleItems(in category: CleanupCategory) -> [CleanupItem] {
        guard !searchText.isEmpty else { return category.items }
        return category.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.url.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isExpanded(_ location: CleanupLocation) -> Binding<Bool> {
        Binding(
            get: {
                !searchText.isEmpty
                    || expanded.contains(location)
                    || (startsExpanded && !collapsed.contains(location))
            },
            set: { value in
                if value {
                    expanded.insert(location)
                    collapsed.remove(location)
                } else {
                    expanded.remove(location)
                    collapsed.insert(location)
                }
            }
        )
    }

    var body: some View {
        List(selection: $highlighted) {
            ForEach(categories) { category in
                Section {
                    if isExpanded(category.location).wrappedValue {
                        let items = visibleItems(in: category)
                        ForEach(items) { item in
                            CleanupItemRow(item: item, isChecked: checkBinding(item))
                                .tag(item.id)
                        }
                        if items.isEmpty {
                            Text("No items match your search.")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        if !category.issues.isEmpty {
                            DisclosureGroup {
                                IssueList(issues: category.issues)
                            } label: {
                                Label(
                                    "\(category.issues.count) location\(category.issues.count == 1 ? "" : "s") could not be read",
                                    systemImage: "lock.trianglebadge.exclamationmark"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .selectionDisabled()
                        }
                    }
                } header: {
                    CategorySectionHeader(
                        category: category,
                        checkedItemIDs: $checkedItemIDs,
                        isExpanded: isExpanded(category.location)
                    )
                }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            let checkable = Set(highlighted.filter { itemsByID[$0]?.isDeletable == true })
            guard !checkable.isEmpty else { return .ignored }
            checkedItemIDs = CheckboxToggle.toggled(
                checkedItemIDs,
                highlighted: highlighted,
                checkable: checkable
            )
            return .handled
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let item = ids.first.flatMap({ itemsByID[$0] }) {
                Button("Quick Look") { quickLook(item.url) }
                Button("Reveal in Finder") { reveal(item.url) }
            }
        } primaryAction: { ids in
            if let item = ids.first.flatMap({ itemsByID[$0] }) {
                quickLook(item.url)
            }
        }
    }

    private func checkBinding(_ item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { checkedItemIDs.contains(item.id) },
            set: { isChecked in
                if isChecked { checkedItemIDs.insert(item.id) } else { checkedItemIDs.remove(item.id) }
            }
        )
    }
}

/// A category's section header: expand button, select-all checkbox, name, risk, and size.
struct CategorySectionHeader: View {
    let category: CleanupCategory
    @Binding var checkedItemIDs: Set<UUID>
    @Binding var isExpanded: Bool

    private var selectable: [CleanupItem] { category.items.filter(\.isDeletable) }

    private var isCategoryChecked: Bool {
        !selectable.isEmpty && selectable.allSatisfy { checkedItemIDs.contains($0.id) }
    }

    private var checkedSize: Int64 {
        category.items.filter { checkedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        HStack(spacing: 10) {
            SectionDisclosureButton(isExpanded: $isExpanded, title: category.name)

            Toggle(
                isOn: Binding(
                    get: { isCategoryChecked },
                    set: { value in
                        for item in selectable {
                            if value { checkedItemIDs.insert(item.id) } else { checkedItemIDs.remove(item.id) }
                        }
                    }
                )
            ) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(selectable.isEmpty)
            .accessibilityLabel("Select all items in \(category.name)")

            Image(systemName: category.location.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(category.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    RiskBadge(risk: category.risk)
                }
                Text(category.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(FileSizeFormatter.string(fromByteCount: category.totalSize))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if checkedSize > 0 {
                    Text("\(FileSizeFormatter.string(fromByteCount: checkedSize)) selected")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else {
                    Text("\(category.fileCount.formatted()) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .textCase(nil)
    }
}
