import SwiftUI

struct TrashCleanupView: View {
    let category: CleanupCategory?
    @Binding var selectedItemIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let reviewCleanup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Trash",
                    subtitle: "Review items already in Trash before permanently removing them.",
                    symbol: "trash"
                )

                Label {
                    Text("Emptying Trash is permanent and cannot be undone. DiskSweep never selects Trash automatically.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .cardSurface()

                if let category {
                    CleanupCategoryCard(
                        category: category,
                        selectedItemIDs: $selectedItemIDs
                    )

                    let selectedSize = category.items
                        .filter { selectedItemIDs.contains($0.id) }
                        .reduce(0) { $0 + $1.size }

                    if selectedSize > 0 {
                        HStack {
                            Spacer()
                            Button("Review Permanent Cleanup — \(FileSizeFormatter.string(fromByteCount: selectedSize))", action: reviewCleanup)
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.large)
                        }
                    }
                } else if !isScanning {
                    EmptyAnalysisView(
                        title: "Trash Has Not Been Scanned",
                        message: "Scan to calculate its size. No files are changed during a scan.",
                        symbol: "trash",
                        buttonTitle: "Scan Trash",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 380)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }
}
