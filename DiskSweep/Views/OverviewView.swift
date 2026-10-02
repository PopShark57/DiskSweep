import SwiftUI

struct OverviewView: View {
    let statistics: DiskStatistics
    let categories: [CleanupCategory]
    @Binding var selectedItemIDs: Set<UUID>
    let progress: ScanProgress?
    let lastScanDate: Date?
    let scanWasCancelled: Bool
    let scan: () -> Void
    let cancelScan: () -> Void
    let reviewCleanup: () -> Void

    private var selectedSize: Int64 {
        categories
            .flatMap(\.items)
            .filter { selectedItemIDs.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    private var recommendedCategories: [CleanupCategory] {
        categories.filter { $0.risk == .safe && $0.totalSize > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Macintosh HD",
                    subtitle: "A clear, local view of storage and low-risk cleanup opportunities.",
                    symbol: "internaldrive"
                )

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statistics.volumeName)
                                .font(.title2.weight(.semibold))
                            Text("\(FileSizeFormatter.string(fromByteCount: statistics.capacity)) capacity")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let lastScanDate {
                            Text("Scanned \(lastScanDate, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    StorageVisualization(statistics: statistics)
                }
                .cardSurface(padding: 22)

                HStack(spacing: 14) {
                    StorageMetricCard(
                        title: "Used",
                        value: statistics.used,
                        symbol: "internaldrive.fill",
                        tint: .secondary
                    )
                    StorageMetricCard(
                        title: "Available",
                        value: statistics.available,
                        symbol: "checkmark.circle.fill",
                        tint: .green
                    )
                    StorageMetricCard(
                        title: "Cleanup Available",
                        value: statistics.reclaimable,
                        symbol: "sparkles",
                        tint: .diskSweepTeal
                    )
                }

                if let progress {
                    ScanProgressView(progress: progress, cancel: cancelScan)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    actionPanel
                }

                if !recommendedCategories.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recommended Cleanup")
                                    .font(.title2.weight(.semibold))
                                Text("Only regeneratable items are selected automatically.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            RiskBadge(risk: .safe)
                        }

                        ForEach(recommendedCategories) { category in
                            CleanupCategoryCard(
                                category: category,
                                selectedItemIDs: $selectedItemIDs
                            )
                        }
                    }
                }

                privacyFooter
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionPanel: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.diskSweepBlue.opacity(0.15), .diskSweepTeal.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(
                    systemName: categories.isEmpty
                    ? "magnifyingglass"
                    : scanWasCancelled ? "exclamationmark.circle" : "sparkles"
                )
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    categories.isEmpty
                    ? "Find reclaimable space"
                    : scanWasCancelled ? "Partial scan results" : "Your scan is ready"
                )
                    .font(.title3.weight(.semibold))
                Text(
                    categories.isEmpty
                    ? "DiskSweep checks only recognized cleanup locations. Nothing is removed during a scan."
                    : scanWasCancelled
                        ? "The scan was cancelled. Completed categories remain available; rescan for a full result."
                        : "Review every selected item before DiskSweep removes anything."
                )
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            if categories.isEmpty {
                Button("Scan Macintosh HD", action: scan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
            } else if selectedSize > 0 {
                HStack(spacing: 10) {
                    if scanWasCancelled {
                        Button("Rescan", action: scan)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    Button("Clean Selected — \(FileSizeFormatter.string(fromByteCount: selectedSize))", action: reviewCleanup)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                Button("Rescan", action: scan)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .cardSurface(padding: 20)
    }

    private var privacyFooter: some View {
        Label {
            Text("DiskSweep analyzes file metadata locally. File names, paths, contents, and cleanup history are never uploaded.")
        } icon: {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.green)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
