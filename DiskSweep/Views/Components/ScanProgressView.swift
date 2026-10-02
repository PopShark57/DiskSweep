import SwiftUI

struct ScanProgressView: View {
    let progress: ScanProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Scanning Macintosh HD…", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Button("Cancel Scan", role: .cancel, action: cancel)
            }

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(progress.currentPath.isEmpty ? "Preparing scan…" : progress.currentPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 18) {
                    Label("\(progress.filesAnalyzed.formatted()) items", systemImage: "doc.on.doc")
                    Label(
                        FileSizeFormatter.string(fromByteCount: progress.bytesFound),
                        systemImage: "sparkles"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

