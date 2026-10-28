import Foundation

enum CleanupLocation: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case userCaches
    case userLogs
    case temporaryFiles
    case trash
    case applicationCaches
    case browserCaches
    case electronAppCaches
    case xcodeDerivedData
    case xcodeArchives
    case xcodeSimulatorData
    case xcodeDeviceSupport
    case swiftPackageCaches
    case homebrewCache
    case developerToolCaches
    case staleIDEVersions
    case androidSystemImages
    case projectArtifacts
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
        case .electronAppCaches: "Electron App Caches"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .xcodeArchives: "Xcode Archives"
        case .xcodeSimulatorData: "Simulator Data"
        case .xcodeDeviceSupport: "Device Support"
        case .swiftPackageCaches: "Swift Package Caches"
        case .homebrewCache: "Homebrew Cache"
        case .developerToolCaches: "Package Manager Caches"
        case .staleIDEVersions: "Old IDE Versions"
        case .androidSystemImages: "Unused Android System Images"
        case .projectArtifacts: "Project Build Artifacts"
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
        case .electronAppCaches:
            "HTTP, script, and GPU shader caches of Electron and Chromium-based apps—never their settings, sign-ins, or local storage."
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
        case .developerToolCaches:
            "Download caches for npm, pnpm, Yarn, Bun, pip, uv, Cargo, Gradle, CocoaPods, and Composer, which these tools fetch again when needed."
        case .staleIDEVersions:
            "Settings, plugins, and indexes left behind by JetBrains IDE and Android Studio versions you have since upgraded from."
        case .androidSystemImages:
            "Android emulator system images that no virtual device uses. Android Studio's SDK Manager can download them again."
        case .projectArtifacts:
            "Virtual environments, dependency folders, and tagged build caches in idle projects inside folders you choose in Settings."
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
        case .electronAppCaches: "atom"
        case .xcodeDerivedData: "hammer"
        case .xcodeArchives: "archivebox"
        case .xcodeSimulatorData: "iphone.gen3"
        case .xcodeDeviceSupport: "externaldrive.connected.to.line.below"
        case .swiftPackageCaches: "shippingbox.and.arrow.backward"
        case .homebrewCache: "mug"
        case .developerToolCaches: "shippingbox.circle"
        case .staleIDEVersions: "clock.badge.xmark"
        case .androidSystemImages: "smartphone"
        case .projectArtifacts: "folder.badge.gearshape"
        case .downloads: "arrow.down.circle"
        }
    }

    var risk: CleanupRisk {
        switch self {
        case .userCaches, .userLogs, .applicationCaches, .browserCaches,
             .electronAppCaches, .xcodeDerivedData, .swiftPackageCaches, .homebrewCache,
             .developerToolCaches:
            .safe
        case .temporaryFiles, .trash, .xcodeArchives, .xcodeSimulatorData,
             .xcodeDeviceSupport, .staleIDEVersions, .androidSystemImages,
             .projectArtifacts:
            .reviewRecommended
        case .downloads:
            .userFiles
        }
    }

    var isDeveloperCategory: Bool {
        switch self {
        case .xcodeDerivedData, .xcodeArchives, .xcodeSimulatorData,
             .xcodeDeviceSupport, .swiftPackageCaches, .homebrewCache,
             .developerToolCaches, .staleIDEVersions, .androidSystemImages,
             .projectArtifacts:
            true
        default:
            false
        }
    }

    /// Locations whose items move to the Trash unless the person chooses permanent deletion,
    /// because they may hold something that cannot be downloaded or rebuilt.
    var defaultsToTrash: Bool {
        switch self {
        case .downloads, .projectArtifacts, .staleIDEVersions:
            true
        default:
            false
        }
    }
}

