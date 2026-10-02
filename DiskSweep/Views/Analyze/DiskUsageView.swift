import SwiftUI

struct DiskUsageView: View {
    let root: DirectoryNode?
    let isScanning: Bool
    let scan: () -> Void
    let cancel: () -> Void
    let reveal: (URL) -> Void

    @State private var path: [DirectoryNode] = []

    private var currentNode: DirectoryNode? { path.last ?? root }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "Disk Usage",
                    subtitle: "Drill into a proportional, hierarchical view of your home folder.",
                    symbol: "chart.pie"
                )

                if isScanning {
                    HStack {
                        ProgressView()
                        Text("Building disk usage map…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                    .cardSurface()
                } else if let currentNode {
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
                    }
                } else {
                    EmptyAnalysisView(
                        title: "No Disk Map Yet",
                        message: "Analyze your home folder to see which directories use the most space.",
                        symbol: "chart.pie",
                        buttonTitle: "Build Disk Map",
                        action: scan
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .onChange(of: root?.id) { _, _ in path.removeAll() }
    }

    private func breadcrumbs(root: DirectoryNode?, path: [DirectoryNode]) -> some View {
        HStack(spacing: 6) {
            Button(root?.name ?? "Home") { self.path.removeAll() }
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
                    Label(node.name, systemImage: "folder.fill")
                        .font(.headline)
                    Spacer()
                    Text(FileSizeFormatter.string(fromByteCount: node.size))
                        .font(.headline)
                        .monospacedDigit()
                    Image(systemName: node.children.isEmpty ? "arrow.up.forward.app" : "chevron.right")
                        .foregroundStyle(.tertiary)
                }

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
                            .frame(
                                width: proxy.size.width * min(1, max(0, Double(node.size) / Double(max(1, parentSize))))
                            )
                    }
                }
                .frame(height: 10)

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

