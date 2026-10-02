import SwiftUI

struct CleanupCategoryCard: View {
    let category: CleanupCategory
    @Binding var selectedItemIDs: Set<UUID>
    var searchText: String = ""

    @State private var isExpanded = false

    private var visibleItems: [CleanupItem] {
        guard !searchText.isEmpty else { return category.items }
        return category.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedSize: Int64 {
        category.items
            .filter { selectedItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    private var isCategorySelected: Bool {
        let selectable = category.items.filter(\.isDeletable)
        return !selectable.isEmpty && selectable.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    itemRow(item)
                    if item.id != visibleItems.last?.id { Divider() }
                }

                if visibleItems.isEmpty {
                    Text("No items match your search.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                }

                if !category.issues.isEmpty {
                    Label(
                        "\(category.issues.count) location\(category.issues.count == 1 ? "" : "s") could not be read",
                        systemImage: "lock.trianglebadge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                Toggle(
                    isOn: Binding(
                        get: { isCategorySelected },
                        set: { selectCategory($0) }
                    )
                ) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(category.items.allSatisfy { !$0.isDeletable })
                .accessibilityLabel("Select all items in \(category.name)")

                Image(systemName: category.location.symbolName)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(category.name)
                            .font(.headline)
                        RiskBadge(risk: category.risk)
                    }
                    Text(category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(FileSizeFormatter.string(fromByteCount: category.totalSize))
                        .font(.headline)
                        .monospacedDigit()
                    if selectedSize > 0 {
                        Text("\(FileSizeFormatter.string(fromByteCount: selectedSize)) selected")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    } else {
                        Text("\(category.fileCount.formatted()) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .cardSurface()
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        HStack(spacing: 12) {
            Toggle(
                isOn: Binding(
                    get: { selectedItemIDs.contains(item.id) },
                    set: { isSelected in
                        if isSelected { selectedItemIDs.insert(item.id) }
                        else { selectedItemIDs.remove(item.id) }
                    }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!item.isDeletable)
            .accessibilityLabel("Select \(item.name)")

            Image(systemName: item.kind == .directory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.url.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(FileSizeFormatter.string(fromByteCount: item.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func selectCategory(_ isSelected: Bool) {
        for item in category.items where item.isDeletable {
            if isSelected { selectedItemIDs.insert(item.id) }
            else { selectedItemIDs.remove(item.id) }
        }
    }
}
