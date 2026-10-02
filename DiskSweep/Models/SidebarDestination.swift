import Foundation

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overview
    case smartCleanup
    case applicationCaches
    case developerFiles
    case downloads
    case trash
    case largeFiles
    case largeFolders
    case duplicates
    case diskUsage
    case history
    case settings

    enum Group: String, CaseIterable {
        case overview
        case cleanup
        case analyze
        case activity
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .smartCleanup: "Smart Cleanup"
        case .applicationCaches: "Application Caches"
        case .developerFiles: "Developer Files"
        case .downloads: "Downloads"
        case .trash: "Trash"
        case .largeFiles: "Large Files"
        case .largeFolders: "Large Folders"
        case .duplicates: "Duplicates"
        case .diskUsage: "Disk Usage"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "internaldrive"
        case .smartCleanup: "sparkles"
        case .applicationCaches: "app.badge"
        case .developerFiles: "hammer"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .largeFiles: "doc.text.magnifyingglass"
        case .largeFolders: "folder.badge.questionmark"
        case .duplicates: "square.on.square"
        case .diskUsage: "chart.pie"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .settings: "gearshape"
        }
    }

    var group: Group {
        switch self {
        case .overview: .overview
        case .smartCleanup, .applicationCaches, .developerFiles, .downloads, .trash:
            .cleanup
        case .largeFiles, .largeFolders, .duplicates, .diskUsage:
            .analyze
        case .history, .settings:
            .activity
        }
    }
}
