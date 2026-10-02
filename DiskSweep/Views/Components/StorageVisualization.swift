import SwiftUI

struct StorageVisualization: View {
    let statistics: DiskStatistics

    private var reclaimableFraction: Double {
        min(statistics.usedFraction, statistics.reclaimableFraction)
    }

    private var retainedUsedFraction: Double {
        max(0, statistics.usedFraction - reclaimableFraction)
    }

    private var freeFraction: Double {
        max(0, 1 - statistics.usedFraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    segment(
                        width: proxy.size.width * retainedUsedFraction,
                        color: Color.secondary.opacity(0.48)
                    )
                    segment(
                        width: proxy.size.width * reclaimableFraction,
                        color: .diskSweepTeal
                    )
                    segment(
                        width: proxy.size.width * freeFraction,
                        color: Color.primary.opacity(0.08)
                    )
                }
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(.quaternary) }
            }
            .frame(height: 22)

            HStack(spacing: 22) {
                legend(color: Color.secondary.opacity(0.6), title: "Used", value: statistics.used)
                legend(color: .diskSweepTeal, title: "Cleanup Available", value: statistics.reclaimable)
                legend(color: Color.primary.opacity(0.14), title: "Available", value: statistics.available)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Storage. Used \(FileSizeFormatter.string(fromByteCount: statistics.used)), " +
            "cleanup available \(FileSizeFormatter.string(fromByteCount: statistics.reclaimable)), " +
            "available \(FileSizeFormatter.string(fromByteCount: statistics.available))."
        )
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color) -> some View {
        if width > 0 {
            Rectangle()
                .fill(color)
                .frame(width: width)
        }
    }

    private func legend(color: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FileSizeFormatter.string(fromByteCount: value))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
    }
}

struct StorageMetricCard: View {
    let title: String
    let value: Int64
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FileSizeFormatter.string(fromByteCount: value))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .cardSurface(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

