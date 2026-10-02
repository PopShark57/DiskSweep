import SwiftUI

struct CleanupCompleteView: View {
    let result: CleanupResult
    let done: () -> Void

    @State private var revealCheckmark = false

    private var recoveredBytes: Int64 {
        result.creditedBytesRecovered
    }

    private var completionSummary: String {
        if recoveredBytes > 0 {
            return "\(FileSizeFormatter.string(fromByteCount: recoveredBytes)) recovered"
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

            if result.reportedBytesMovedToTrash > 0 {
                Label(
                    "\(FileSizeFormatter.string(fromByteCount: result.reportedBytesMovedToTrash)) was moved to Trash and is not counted as recovered capacity until Trash is emptied.",
                    systemImage: "trash"
                )
                .foregroundStyle(.secondary)
                .cardSurface()
            }

            if !result.failures.isEmpty {
                Label(
                    "\(result.failures.count) item\(result.failures.count == 1 ? "" : "s") could not be cleaned. Other items completed safely.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
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
