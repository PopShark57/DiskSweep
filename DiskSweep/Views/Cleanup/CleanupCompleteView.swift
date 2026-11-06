import SwiftUI

struct CleanupCompleteView: View {
    let result: CleanupResult
    let done: () -> Void
    var reveal: (URL) -> Void = { _ in }

    @State private var revealCheckmark = false
    @State private var showsFailures = false

    private var recoveredBytes: Int64 {
        result.creditedBytesRecovered
    }

    private var completionSummary: String {
        if recoveredBytes > 0 {
            return "About \(FileSizeFormatter.string(fromByteCount: recoveredBytes)) recovered"
        }
        if result.reportedBytesMovedToTrash > 0 {
            return "\(FileSizeFormatter.string(fromByteCount: result.reportedBytesMovedToTrash)) moved to Trash"
        }
        return "Cleanup finished safely"
    }

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 104, height: 104)
                    .scaleEffect(revealCheckmark ? 1 : 0.65)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: revealCheckmark)
            }

            VStack(spacing: 6) {
                Text("Cleanup Complete")
                    .font(.largeTitle.weight(.semibold))
                Text(completionSummary)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.tint)
            }

            HStack(spacing: 12) {
                resultMetric(
                    title: "Items Cleaned",
                    value: result.fileCount.formatted(),
                    symbol: "sparkles"
                )
                resultMetric(
                    title: "Before",
                    value: FileSizeFormatter.string(fromByteCount: result.availableBefore),
                    symbol: "internaldrive"
                )
                resultMetric(
                    title: "Available Now",
                    value: FileSizeFormatter.string(fromByteCount: result.availableAfter),
                    symbol: "checkmark.circle"
                )
            }

            if result.measuredRecoveryLooksLow {
                Label(
                    "\(FileSizeFormatter.string(fromByteCount: result.reportedBytesPermanentlyRemoved)) was deleted. Space may be held by local snapshots or still being freed, so less free space was measured.",
                    systemImage: "clock.arrow.circlepath"
                )
                .foregroundStyle(.secondary)
                .cardSurface()
            }

            if result.reportedBytesMovedToTrash > 0 {
                Label(
                    "\(FileSizeFormatter.string(fromByteCount: result.reportedBytesMovedToTrash)) was moved to Trash and is not counted as recovered capacity until Trash is emptied.",
                    systemImage: "trash"
                )
                .foregroundStyle(.secondary)
                .cardSurface()
            }

            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "\(result.failures.count) item\(result.failures.count == 1 ? "" : "s") could not be cleaned. Other items completed safely.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)

                    DisclosureGroup(
                        "Show \(result.failures.count) item\(result.failures.count == 1 ? "" : "s") that weren't cleaned",
                        isExpanded: $showsFailures
                    ) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(result.failures) { failure in
                                    failureRow(failure)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }

            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(34)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                revealCheckmark = true
            }
        }
    }

    private func failureRow(_ failure: CleanupFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.itemName)
                    .font(.callout.weight(.medium))
                Text(failure.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(failure.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                reveal(URL(fileURLWithPath: failure.path))
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(failure.itemName) in Finder")
        }
    }

    private func resultMetric(title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .cardSurface(padding: 14)
    }
}
