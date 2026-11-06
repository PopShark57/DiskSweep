import SwiftUI

struct HistoryView: View {
    let entries: [CleanupHistoryEntry]
    var persistenceError: String?
    var deleteEntry: (CleanupHistoryEntry.ID) -> Void = { _ in }
    var clearHistory: () -> Void = {}

    @State private var confirmsClear = false

    private var totalRecovered: Int64 {
        entries.reduce(0) { $0 + $1.bytesRecovered }
    }

    private var totalMovedToTrash: Int64 {
        entries.reduce(0) { $0 + $1.bytesMovedToTrash }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Cleanup History",
                    subtitle: "A private, on-device record of completed cleanups.",
                    symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )

                if let persistenceError {
                    PersistenceErrorBanner(message: persistenceError)
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Cleanup History",
                        systemImage: "clock",
                        description: Text("Completed cleanups will appear here. History never leaves this Mac.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    HStack(spacing: 14) {
                        historySummary(
                            title: "Total Recovered",
                            value: FileSizeFormatter.string(fromByteCount: totalRecovered),
                            symbol: "sparkles"
                        )
                        historySummary(
                            title: "Moved to Trash",
                            value: FileSizeFormatter.string(fromByteCount: totalMovedToTrash),
                            symbol: "trash"
                        )
                        historySummary(
                            title: "Cleanups",
                            value: entries.count.formatted(),
                            symbol: "checkmark.circle"
                        )
                        historySummary(
                            title: "Files Cleaned",
                            value: entries.reduce(0) { $0 + $1.fileCount }.formatted(),
                            symbol: "doc.on.doc"
                        )
                    }

                    VStack(spacing: 0) {
                        ForEach(entries.sorted { $0.date > $1.date }) { entry in
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.green)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.date, format: .dateTime.month(.wide).day().year())
                                        .font(.headline)
                                    Text(entry.categories.map(\.name).joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(entryOutcome(entry))
                                        .font(.headline)
                                        .monospacedDigit()
                                    Text("\(entry.fileCount.formatted()) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button {
                                    deleteEntry(entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this history entry")
                                .accessibilityLabel("Delete history entry from \(entry.date.formatted(date: .long, time: .omitted))")
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .contextMenu {
                                Button("Delete Entry", role: .destructive) { deleteEntry(entry.id) }
                            }

                            if entry.id != entries.sorted(by: { $0.date > $1.date }).last?.id {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .cardSurface(padding: 0)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button("Clear History…") { confirmsClear = true }
                    .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all cleanup history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the record of past cleanups from this Mac. It doesn't restore or change any files.")
        }
    }

    private func historySummary(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .cardSurface(padding: 14)
    }

    private func entryOutcome(_ entry: CleanupHistoryEntry) -> String {
        if entry.bytesRecovered > 0, entry.bytesMovedToTrash > 0 {
            return "\(FileSizeFormatter.string(fromByteCount: entry.bytesRecovered)) recovered • \(FileSizeFormatter.string(fromByteCount: entry.bytesMovedToTrash)) trashed"
        }
        if entry.bytesRecovered > 0 {
            return "\(FileSizeFormatter.string(fromByteCount: entry.bytesRecovered)) recovered"
        }
        if entry.bytesMovedToTrash > 0 {
            return "\(FileSizeFormatter.string(fromByteCount: entry.bytesMovedToTrash)) moved to Trash"
        }
        return "No measured recovery"
    }
}
