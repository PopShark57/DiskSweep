import SwiftUI

/// The Map mode of Disk Usage: drill into folders, with proportional bars.
struct DiskUsageMap: View {
    let root: DirectoryNode
    let reveal: (URL) -> Void

    @State private var path: [DirectoryNode] = []

    private var currentNode: DirectoryNode { path.last ?? root }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            breadcrumbs(root: root, path: path)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentNode.name)
                        .font(.title2.weight(.semibold))
                    Text("\(FileSizeFormatter.string(fromByteCount: currentNode.size)) • \(currentNode.fileCount.formatted()) files")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") { reveal(currentNode.url) }
            }

            VStack(spacing: 10) {
                ForEach(currentNode.children.sorted { $0.size > $1.size }) { child in
                    usageRow(child, parentSize: currentNode.size)
                }
                if currentNode.unlistedSize > 0 {
                    unlistedRow(size: currentNode.unlistedSize, parentSize: currentNode.size)
                }
            }
        }
        .onChange(of: root.id) { _, _ in path.removeAll() }
    }

    private func breadcrumbs(root: DirectoryNode, path: [DirectoryNode]) -> some View {
        HStack(spacing: 6) {
            Button(root.name) { self.path.removeAll() }
                .buttonStyle(.link)
            ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button(node.name) {
                    self.path = Array(self.path.prefix(index + 1))
                }
                .buttonStyle(.link)
            }
            Spacer()
        }
        .font(.callout)
    }

    /// A row that can't be opened: files stored directly in this folder, and subfolders too
    /// small to list.
    private func unlistedRow(size: Int64, parentSize: Int64) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Files in this folder", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text(FileSizeFormatter.string(fromByteCount: size))
                    .font(.headline)
                    .monospacedDigit()
            }
            UsageBar(fraction: Double(size) / Double(max(1, parentSize)))
            Text("Includes smaller folders that aren't listed • \((Double(size) / Double(max(1, parentSize))).formatted(.percent.precision(.fractionLength(1)))) of this folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .cardSurface(padding: 14)
    }

    private func usageRow(_ node: DirectoryNode, parentSize: Int64) -> some View {
        Button {
            guard !node.children.isEmpty else {
                reveal(node.url)
                return
            }
            path.append(node)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(node.name, systemImage: node.isPackage ? "shippingbox.fill" : "folder.fill")
                        .font(.headline)
                    Spacer()
                    Text(FileSizeFormatter.string(fromByteCount: node.size))
                        .font(.headline)
                        .monospacedDigit()
                    Image(systemName: node.children.isEmpty ? "arrow.up.forward.app" : "chevron.right")
                        .foregroundStyle(.tertiary)
                }

                UsageBar(fraction: Double(node.size) / Double(max(1, parentSize)))

                Text("\(node.fileCount.formatted()) files • \((Double(node.size) / Double(max(1, parentSize))).formatted(.percent.precision(.fractionLength(1)))) of this folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface(padding: 14)
    }
}

private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.diskSweepBlue, .diskSweepTeal],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 10)
    }
}
