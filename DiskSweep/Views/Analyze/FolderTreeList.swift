import SwiftUI

/// The List mode of Disk Usage: an expandable tree of the largest folders.
struct FolderTreeList: View {
    let roots: [DirectoryNode]
    let reveal: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(roots.sorted { $0.size > $1.size }) { node in
                DirectoryNodeRow(node: node, depth: 0, reveal: reveal)
                if node.id != roots.last?.id { Divider() }
            }
        }
        .cardSurface(padding: 0)
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

                Image(systemName: node.isPackage ? "shippingbox.fill" : "folder.fill")
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

