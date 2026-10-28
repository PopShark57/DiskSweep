import Foundation

/// Recognizes the per-version folders that JetBrains IDEs and Android Studio leave behind.
///
/// Each IDE release keeps settings and plugins in a folder named after the product and version,
/// such as `PyCharm2025.2` or `AndroidStudio2024.1`. After an upgrade imports those settings,
/// the older folder is never read again. A folder is only treated as stale when a newer version
/// of the same product exists beside it and the old version has not been used recently.
enum StaleIDEVersionRules {
    static let minimumIdleDays = 30
    static var minimumIdleInterval: TimeInterval {
        TimeInterval(minimumIdleDays) * 24 * 60 * 60
    }

    /// Community editions whose users move to the unified product's settings folder.
    static let successorFamilies: [String: String] = [
        "PyCharmCE": "PyCharm",
        "IdeaIC": "IntelliJIdea"
    ]

    /// Plugins bundle their own Node.js dependencies, and Settings Sync keeps a local Git
    /// history of the IDE's settings in `settingsSync/.git`. Both belong to the IDE version.
    static let permittedNestedNames: Set<String> = ["node_modules", ".git"]

    struct VersionedFolder: Hashable, Sendable {
        let url: URL
        let family: String
        let version: [Int]
        let isBackup: Bool

        var versionString: String { version.map(String.init).joined(separator: ".") }
    }

    static func roots(homeDirectory: URL) -> [URL] {
        let applicationSupport = homeDirectory.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        return [
            applicationSupport.appendingPathComponent("JetBrains", isDirectory: true),
            applicationSupport.appendingPathComponent("Google", isDirectory: true)
        ]
    }

    /// Parses names such as `PyCharm2025.2`, `IdeaIC2024.3-backup`, or `AndroidStudio4.2`.
    /// Inside Google's folder, only Android Studio folders are recognized.
    static func parse(_ url: URL, inRoot root: URL) -> VersionedFolder? {
        var name = url.lastPathComponent
        let isBackup = name.hasSuffix("-backup")
        if isBackup { name.removeLast("-backup".count) }

        guard let firstDigit = name.firstIndex(where: \.isNumber) else { return nil }
        let family = String(name[..<firstDigit])
        guard !family.isEmpty, family.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return nil
        }
        if root.lastPathComponent == "Google", !family.hasPrefix("AndroidStudio") {
            return nil
        }

        let components = name[firstDigit...].split(separator: ".", omittingEmptySubsequences: false)
        let version = components.compactMap { Int($0) }
        guard version.count >= 2, version.count == components.count else { return nil }
        return VersionedFolder(url: url, family: family, version: version, isBackup: isBackup)
    }

    static func folders(in root: URL) -> [VersionedFolder] {
        let children = (try? FileManager().contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.compactMap { child in
            guard (try? SafetyValidator.captureIdentity(at: child))?.kind == .directory else {
                return nil
            }
            return parse(child, inRoot: root)
        }
    }

    /// The newest folder that makes `folder` obsolete, if there is one.
    static func replacement(
        for folder: VersionedFolder,
        among folders: [VersionedFolder]
    ) -> VersionedFolder? {
        var families: Set<String> = [folder.family]
        if let successor = successorFamilies[folder.family] { families.insert(successor) }
        return folders
            .filter {
                !$0.isBackup
                    && families.contains($0.family)
                    && folder.version.lexicographicallyPrecedes($0.version)
            }
            .max { $0.version.lexicographicallyPrecedes($1.version) }
    }

    /// The last time the IDE wrote its settings. IDEs rewrite files in `options` as they run,
    /// which does not change the version folder's own modification date.
    static func lastUsed(_ url: URL) -> Date? {
        let options = url.appendingPathComponent("options", isDirectory: true)
        let optionFiles = (try? FileManager().contentsOfDirectory(
            at: options,
            includingPropertiesForKeys: nil
        )) ?? []
        return ([url, options] + optionFiles)
            .compactMap { try? SafetyValidator.captureIdentity(at: $0).modificationDate }
            .max()
    }

    /// Rechecked immediately before removal: the folder must still sit directly in an IDE root,
    /// still be superseded by a newer version, and still be unused.
    static func isRemovable(_ url: URL, approvedRoot: URL, now: Date = Date()) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard parent == approvedRoot.standardizedFileURL.pathComponents,
              let folder = parse(url, inRoot: approvedRoot),
              replacement(for: folder, among: folders(in: approvedRoot)) != nil,
              let lastUsed = lastUsed(url) else {
            return false
        }
        return now.timeIntervalSince(lastUsed) >= minimumIdleInterval
    }

    static func displayName(for folder: VersionedFolder) -> String {
        let product: String
        switch folder.family {
        case "IntelliJIdea": product = "IntelliJ IDEA"
        case "IdeaIC": product = "IntelliJ IDEA Community"
        case "PyCharmCE": product = "PyCharm Community"
        case "AndroidStudio": product = "Android Studio"
        case "AndroidStudioPreview": product = "Android Studio Preview"
        default: product = folder.family
        }
        return "\(product) \(folder.versionString)\(folder.isBackup ? " (settings backup)" : "")"
    }
}

struct StaleIDEVersionsProvider: CleanupProvider {
    static let providerID = "stale-ide-versions"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .staleIDEVersions }
    var allowedRoots: [URL] {
        StaleIDEVersionRules.roots(homeDirectory: homeDirectory)
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let now = context.now
        return await ProviderSupport.scanDirectoryCandidates(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress,
            permittedNestedNames: StaleIDEVersionRules.permittedNestedNames
        ) { root in
            let folders = StaleIDEVersionRules.folders(in: root)
            return folders.compactMap { folder in
                guard let newer = StaleIDEVersionRules.replacement(for: folder, among: folders),
                      let lastUsed = StaleIDEVersionRules.lastUsed(folder.url),
                      now.timeIntervalSince(lastUsed) >= StaleIDEVersionRules.minimumIdleInterval else {
                    return nil
                }
                let idleDays = Int(now.timeIntervalSince(lastUsed) / 86_400)
                return ProviderSupport.DirectoryCandidate(
                    url: folder.url,
                    name: StaleIDEVersionRules.displayName(for: folder),
                    explanation: "Settings, plugins, and caches from an IDE version that \(StaleIDEVersionRules.displayName(for: newer)) has replaced. Newer versions import these settings when they first start, so this folder is no longer read. It moves to the Trash by default.",
                    detail: "Last used \(idleDays) days ago · Replaced by \(StaleIDEVersionRules.displayName(for: newer))"
                )
            }
        }
    }
}
