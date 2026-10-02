import SwiftUI

struct CleanupListView: View {
    let title: String
    let subtitle: String
    let symbol: String
    let categories: [CleanupCategory]
    @Binding var selectedItemIDs: Set<UUID>
    let isScanning: Bool
    let scan: () -> Void
    let reviewCleanup: () -> Void

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var selectedSize: Int64 {
        categories
            .flatMap(\.items)
            .filter { selectedItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: title, subtitle: subtitle, symbol: symbol)

                if categories.isEmpty && !isScanning {
                    EmptyAnalysisView(
                        title: "No Scan Results",
                        message: "Run a scan to inspect these locations. Scanning never deletes files.",
                        symbol: symbol,
                        buttonTitle: "Scan Now",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    ForEach(categories) { category in
                        CleanupCategoryCard(
                            category: category,
                            selectedItemIDs: $selectedItemIDs,
                            searchText: searchText
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1060, alignment: .leading)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search results")
        .searchFocused($isSearchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .diskSweepFocusSearch)) { _ in
            isSearchFocused = true
        }
        .safeAreaInset(edge: .bottom) {
            if selectedSize > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready to review")
                            .font(.headline)
                        Text("\(FileSizeFormatter.string(fromByteCount: selectedSize)) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review Cleanup", action: reviewCleanup)
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
}
