import Foundation

enum CleanupRisk: String, CaseIterable, Codable, Hashable, Sendable {
    case safe
    case reviewRecommended
    case userFiles

    /// The localized risk title.
    var title: String { String(localized: titleResource) }

    var titleResource: LocalizedStringResource {
        switch self {
        case .safe: "Safe"
        case .reviewRecommended: "Review Recommended"
        case .userFiles: "User Files"
        }
    }

    /// The localized risk explanation.
    var explanation: String { String(localized: explanationResource) }

    var explanationResource: LocalizedStringResource {
        switch self {
        case .safe:
            "Regeneratable data in a recognized cleanup location."
        case .reviewRecommended:
            "Usually disposable, but it may still be useful to you."
        case .userFiles:
            "Content you created or downloaded. DiskSweep never preselects it."
        }
    }

    var symbolName: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .reviewRecommended: "exclamationmark.triangle.fill"
        case .userFiles: "person.crop.circle.badge.exclamationmark"
        }
    }

    var isSelectedByDefault: Bool { self == .safe }
}

