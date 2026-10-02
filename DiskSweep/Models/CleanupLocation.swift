import Foundation

enum CleanupLocation: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case userCaches
    case userLogs
    case temporaryFiles
    case trash
    case applicationCaches
    case browserCaches
    case xcodeDerivedData
    case xcodeArchives
    case xcodeSimulatorData
    case xcodeDeviceSupport
    case swiftPackageCaches
    case homebrewCache
    case downloads

    var id: String { rawValue }

    var name: String {
        switch self {
        case .userCaches: "User Caches"
        case .userLogs: "User Logs"
        case .temporaryFiles: "Temporary Files"
        case .trash: "Trash"
        case .applicationCaches: "Application Caches"
        case .browserCaches: "Browser Caches"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode Archives"
        case .xcodeSimulatorData: "Simulator Data"
        case .xcodeDeviceSupport: "Device Support"
        case .swiftPackageCaches: "Swift Package Caches"
        case .homebrewCache: "Homebrew Cache"
        case .downloads: "Downloads"
        }
    }

    var explanation: String {
        switch self {
        case .userCaches:
            "Disposable cache folders created by apps in your user Library."
        case .userLogs:
            "Diagnostic logs written by apps in your user Library."
        case .temporaryFiles:
            "Older files in this account's temporary directory."
        case .trash:
            "Items already moved to Trash. Emptying Trash is permanent."
        case .applicationCaches:
            "Per-application data that apps can recreate when needed."
        case .browserCaches:
            "Disposable browser cache data only—not profiles or browsing data."
        case .xcodeDerivedData:
            "Build products and indexes that Xcode regenerates."
        case .xcodeArchives:
            "Archived builds that may be needed for distribution or symbolication."
        case .xcodeSimulatorData:
            "Large simulator runtimes, caches, and device data. Review carefully."
        case .xcodeDeviceSupport:
            "Symbols and support files Xcode may redownload for connected devices."
        case .swiftPackageCaches:
            "Downloaded package artifacts that Swift Package Manager can restore."
        case .homebrewCache:
            "Downloaded Homebrew bottles and source archives, never installed packages."
        case .downloads:
            "Files in Downloads. DiskSweep never selects these automatically."
        }
    }

    var symbolName: String {
        switch self {
        case .userCaches: "shippingbox"
        case .userLogs: "doc.text.magnifyingglass"
        case .temporaryFiles: "timer"
        case .trash: "trash"
        case .applicationCaches: "app.badge"
        case .browserCaches: "globe"
        case .xcodeDerivedData: "hammer"
        case .xcodeArchives: "archivebox"
        case .xcodeSimulatorData: "iphone.gen3"
        case .xcodeDeviceSupport: "externaldrive.connected.to.line.below"
        case .swiftPackageCaches: "shippingbox.and.arrow.backward"
        case .homebrewCache: "mug"
        case .downloads: "arrow.down.circle"
        }
    }

    var risk: CleanupRisk {
        switch self {
        case .userCaches, .userLogs, .applicationCaches, .browserCaches,
             .xcodeDerivedData, .swiftPackageCaches, .homebrewCache:
            .safe
        case .temporaryFiles, .trash, .xcodeArchives, .xcodeSimulatorData,
             .xcodeDeviceSupport:
            .reviewRecommended
        case .downloads:
            .userFiles
        }
    }

    var isDeveloperCategory: Bool {
        switch self {
        case .xcodeDerivedData, .xcodeArchives, .xcodeSimulatorData,
             .xcodeDeviceSupport, .swiftPackageCaches, .homebrewCache:
            true
        default:
            false
        }
    }
}

