import SwiftUI

extension ScanIssue.Kind {
    var title: String {
        switch self {
        case .permissionDenied: "Permission denied"
        case .disappeared: "Changed or disappeared"
        case .inaccessible: "Not accessible"
        case .cancelled: "Cancelled"
        case .inputOutput: "Read error"
        case .unknown: "Other"
        }
    }
}

/// Lists scan issues grouped by kind, with each path and message.
struct IssueList: View {
    let issues: [ScanIssue]

    /// Groups issues by kind in a stable order, so the most actionable kinds come first.
    nonisolated static func grouped(_ issues: [ScanIssue]) -> [(kind: ScanIssue.Kind, issues: [ScanIssue])] {
        let order: [ScanIssue.Kind] = [
            .permissionDenied, .inaccessible, .inputOutput, .disappeared, .unknown, .cancelled
        ]
        let byKind = Dictionary(grouping: issues, by: \.kind)
        return order.compactMap { kind in
            guard let group = byKind[kind], !group.isEmpty else { return nil }
            return (kind, group.sorted { $0.path < $1.path })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.grouped(issues), id: \.kind) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.kind.title) (\(group.issues.count))")
                        .font(.caption.weight(.semibold))
                    ForEach(group.issues) { issue in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
