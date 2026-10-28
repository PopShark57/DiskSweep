import Foundation

/// Recognizes the disposable cache folders of Electron and Chromium-based apps such as
/// Visual Studio Code, Slack, Discord, and Teams.
///
/// These apps keep caches inside their Application Support folder rather than in
/// `~/Library/Caches`. An app folder is only recognized when Chromium's `Local State` file is
/// present, and only cache folders with Chromium's own names are offered. Local Storage,
/// IndexedDB, cookies, and Service Worker data are never offered.
enum ElectronAppCacheRules {
    static let cacheNames: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "GraphiteDawnCache", "GrShaderCache", "ShaderCache",
        // Visual Studio Code and its forks keep V8 code caches and downloaded extension
        // packages here.
        "CachedData", "CachedExtensionVSIXs"
    ]

    static func applicationSupport(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static func isElectronDataDirectory(_ url: URL) -> Bool {
        ProjectArtifactRules.isRegularFile(url.appendingPathComponent("Local State"))
    }

    /// App data folders directly inside Application Support that carry Chromium's marker.
    static func applicationDirectories(homeDirectory: URL) -> [URL] {
        let candidates = (try? FileManager().contentsOfDirectory(
            at: applicationSupport(homeDirectory: homeDirectory),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return ProviderSupport.existingDirectories(candidates.filter(isElectronDataDirectory))
    }

    static func isApplicationDirectory(_ url: URL, homeDirectory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.pathComponents
            == applicationSupport(homeDirectory: homeDirectory).standardizedFileURL.pathComponents
            && isElectronDataDirectory(url)
    }

    /// Cache folders in the app folder, including those of embedded web views, which
    /// Electron keeps per session in `Partitions/<name>`.
    static func cacheFolders(in application: URL) -> [URL] {
        let partitions = (try? FileManager().contentsOfDirectory(
            at: application.appendingPathComponent("Partitions", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let folders = ([application] + partitions).flatMap { base in
            cacheNames.sorted().map { base.appendingPathComponent($0, isDirectory: true) }
        }
        return ProviderSupport.existingDirectories(folders)
    }

    /// Rechecked immediately before removal: the target must be a Chromium cache folder of
    /// the approved app folder, never the app's other data.
    static func isCacheFolder(_ url: URL, inApplication application: URL) -> Bool {
        let base = application.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > base.count,
              Array(components.prefix(base.count)) == base,
              let name = components.last,
              cacheNames.contains(name) else {
            return false
        }
        let relative = components.dropFirst(base.count)
        return relative.count == 1
            || (relative.count == 3 && relative.first == "Partitions")
    }

    static func displayName(for folder: URL, inApplication application: URL) -> String {
        let appName = ProviderSupport.humanReadableIdentifier(application.lastPathComponent)
        let partition = folder.deletingLastPathComponent()
        if partition.deletingLastPathComponent().lastPathComponent == "Partitions" {
            return "\(appName) — \(folder.lastPathComponent) (\(partition.lastPathComponent))"
        }
        return "\(appName) — \(folder.lastPathComponent)"
    }
}

struct ElectronAppCacheProvider: CleanupProvider {
    static let providerID = "electron-app-caches"

    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .electronAppCaches }
    var allowedRoots: [URL] {
        ElectronAppCacheRules.applicationDirectories(homeDirectory: homeDirectory)
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        await ProviderSupport.scanDirectoryCandidates(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress
        ) { application in
            ElectronAppCacheRules.cacheFolders(in: application).map {
                ProviderSupport.DirectoryCandidate(
                    url: $0,
                    name: ElectronAppCacheRules.displayName(for: $0, inApplication: application),
                    explanation: CleanupLocation.electronAppCaches.explanation
                        + " The app rebuilds this cache as you use it.",
                    detail: nil
                )
            }
        }
    }
}
