import SwiftUI

/// Shows a settings or history persistence problem, such as a file that couldn't be read and
/// was set aside, at the top of the screen that owns that data.
struct PersistenceErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 12)
        .accessibilityElement(children: .combine)
    }
}
