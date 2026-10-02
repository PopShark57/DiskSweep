import SwiftUI

extension Color {
    static let diskSweepTeal = Color(red: 0.08, green: 0.63, blue: 0.72)
    static let diskSweepBlue = Color(red: 0.10, green: 0.34, blue: 0.70)
    static let diskSweepNavy = Color(red: 0.04, green: 0.12, blue: 0.25)

    static func risk(_ risk: CleanupRisk) -> Color {
        switch risk {
        case .safe: .green
        case .reviewRecommended: .orange
        case .userFiles: .blue
        }
    }
}

struct CardSurface: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}

extension View {
    func cardSurface(padding: CGFloat = 18) -> some View {
        modifier(CardSurface(padding: padding))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RiskBadge: View {
    let risk: CleanupRisk

    var body: some View {
        Label(risk.title, systemImage: risk.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.risk(risk))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.risk(risk).opacity(0.11), in: Capsule())
            .accessibilityLabel("Risk level: \(risk.title)")
    }
}

struct EmptyAnalysisView: View {
    let title: String
    let message: String
    let symbol: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

