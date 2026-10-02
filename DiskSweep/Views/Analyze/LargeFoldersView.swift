import SwiftUI

struct LargeFoldersView: View {
    let roots: [DirectoryNode]
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Large Folders",
                    subtitle: "Explore the largest directories in your home folder without changing their contents.",
                    symbol: "folder.badge.questionmark"
                )

                HStack {
                    if isScanning {
                        ProgressView()
                        Text("Calculating folder sizes…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel, action: cancel)
                    } else {
                        Spacer()
                        Button("Analyze Home Folder", action: scan)
                            .buttonStyle(.borderedProminent)
                    }
                }

                if roots.isEmpty && !isScanning {
                    EmptyAnalysisView(
                        title: "No Folder Analysis Yet",
                        message: "Analyze your home folder to build a browsable size tree.",
                        symbol: "folder.badge.questionmark",
                        buttonTitle: "Analyze Home Folder",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    VStack(spacing: 0) {
                        ForEach(roots.sorted { $0.size > $1.size }) { node in
                            DirectoryNodeRow(node: node, depth: 0, reveal: reveal)
                            if node.id != roots.last?.id { Divider() }
                        }
                    }
                    .cardSurface(padding: 0)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }
}

private struct DirectoryNodeRow: View {
    let node: DirectoryNode
    let depth: Int
    let reveal: (URL) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 16, height: 16)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse \(node.name)" : "Expand \(node.name)")
                }

                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(depth == 0 ? .headline : .body)
                    Text("\(node.fileCount.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(FileSizeFormatter.string(fromByteCount: node.size))
                    .font(.headline)
                    .monospacedDigit()
                Button {
                    reveal(node.url)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            .padding(.leading, CGFloat(depth) * 22)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isExpanded {
                ForEach(node.children.sorted { $0.size > $1.size }) { child in
                    Divider().padding(.leading, CGFloat(depth + 1) * 22 + 42)
                    DirectoryNodeRow(node: child, depth: depth + 1, reveal: reveal)
                }
            }
        }
    }
}

