import SwiftUI

struct TrashCleanupView: View {
    let category: CleanupCategory?
    @Binding var selectedItemIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let reviewCleanup: () -> Void
    let quickLook: (URL) -> Void
    let reveal: (URL) -> Void

    private var selectedSize: Int64 {
        guard let category else { return 0 }
        return category.items
            .filter { selectedItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 16) {
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
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: 980, alignment: .leading)

        Group {
            if let category {
                CleanupItemsList(
                    categories: [category],
                    checkedItemIDs: $selectedItemIDs,
                    startsExpanded: true,
                    quickLook: quickLook,
                    reveal: reveal
                )
            } else if !isScanning {
                EmptyAnalysisView(
                    title: "Trash Has Not Been Scanned",
                    message: "Scan to calculate its size. No files are changed during a scan.",
                    symbol: "trash",
                    buttonTitle: "Scan Trash",
                    action: scan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSize > 0 {
                HStack {
                    Spacer()
                    Button(
                        "Review Permanent Cleanup — \(FileSizeFormatter.string(fromByteCount: selectedSize))",
                        action: reviewCleanup
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }
}
