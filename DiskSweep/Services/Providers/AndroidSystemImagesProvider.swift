import Foundation

/// Finds Android emulator system images that no Android virtual device (AVD) refers to.
///
/// Images live at `system-images/<api>/<tag>/<abi>` in the SDK, and each AVD names the image it
/// boots in its `config.ini` as `image.sysdir.N`. If any AVD cannot be read, every image is
/// treated as possibly in use.
enum AndroidSystemImageRules {
    static func imagesRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Android/sdk/system-images",
            isDirectory: true
        )
    }

    static func avdDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// Folders that only an Android SDK has next to `system-images`.
    static let sdkMarkerNames = ["platform-tools", "licenses", "emulator"]

    /// A `system-images` folder in an SDK the person chose in Settings. Its parent must look
    /// like an SDK; the validator separately requires a user-scoped, unprotected location,
    /// and every image is rechecked against the virtual devices before removal.
    static func isSDKImagesRoot(_ root: URL) -> Bool {
        guard root.lastPathComponent == "system-images" else { return false }
        let sdk = root.deletingLastPathComponent()
        return sdkMarkerNames.contains {
            (try? SafetyValidator.captureIdentity(at: sdk.appendingPathComponent($0)))?.kind == .directory
        }
    }

    /// The validator only approves `~/Library/Android/sdk/system-images`, so the home folder is
    /// always four levels above an approved images root.
    static func homeDirectory(forImagesRoot root: URL) -> URL {
        root.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Installed images, recognized by the package metadata the SDK Manager writes into each.
    static func installedImages(in root: URL) -> [URL] {
        let manager = FileManager()
        func directories(in url: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                (try? SafetyValidator.captureIdentity(at: $0))?.kind == .directory
            }
        }

        return directories(in: root)
            .flatMap(directories(in:))
            .flatMap(directories(in:))
            .filter(isSystemImage)
    }

    static func isSystemImage(_ url: URL) -> Bool {
        ["package.xml", "source.properties"].contains {
            ProjectArtifactRules.isRegularFile(url.appendingPathComponent($0))
        }
    }

    /// Standardized paths of every image an AVD boots, or `nil` when an AVD could not be read.
    static func referencedImagePaths(avdDirectory avds: URL, sdkDirectory: URL) -> Set<String>? {
        guard let entries = try? FileManager().contentsOfDirectory(
            at: avds,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            // Without the standard AVD folder, devices may live somewhere DiskSweep can't see.
            return nil
        }

        var avdFolders = Set(entries.filter { $0.pathExtension == "avd" }.map(\.standardizedFileURL))
        // An AVD's .ini file can point at a folder stored somewhere else.
        for ini in entries where ini.pathExtension == "ini" {
            guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return nil }
            if let path = value(forKey: "path", in: text) {
                avdFolders.insert(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
            }
        }

        var referenced: Set<String> = []
        for avd in avdFolders {
            guard let text = try? String(
                contentsOf: avd.appendingPathComponent("config.ini"),
                encoding: .utf8
            ) else {
                return nil
            }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).hasPrefix("image.sysdir.") else {
                    continue
                }
                let path = parts[1].trimmingCharacters(in: .whitespaces)
                let url = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path, isDirectory: true)
                    : sdkDirectory.appendingPathComponent(path, isDirectory: true)
                referenced.insert(normalizedPath(url))
            }
        }
        return referenced
    }

    static func unusedImages(in root: URL, avdDirectory: URL) -> [URL] {
        guard let referenced = referencedImagePaths(
            avdDirectory: avdDirectory,
            sdkDirectory: root.deletingLastPathComponent()
        ) else {
            return []
        }
        return installedImages(in: root).filter { !referenced.contains(normalizedPath($0)) }
    }

    /// Rechecked immediately before removal, in case an AVD started using the image.
    /// `avdDirectory` defaults to `~/.android/avd` of the home folder above the default root.
    static func isRemovable(_ url: URL, approvedRoot: URL, avdDirectory: URL? = nil) -> Bool {
        let rootComponents = approvedRoot.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count == rootComponents.count + 3,
              Array(components.prefix(rootComponents.count)) == rootComponents,
              isSystemImage(url) else {
            return false
        }
        let devices = avdDirectory
            ?? Self.avdDirectory(homeDirectory: homeDirectory(forImagesRoot: approvedRoot))
        return unusedImages(in: approvedRoot, avdDirectory: devices)
            .contains { normalizedPath($0) == normalizedPath(url) }
    }

    static func displayName(for image: URL) -> String {
        let abi = image.lastPathComponent
        let tag = image.deletingLastPathComponent().lastPathComponent
        let api = image.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let level = api.hasPrefix("android-") ? "API \(api.dropFirst("android-".count))" : api
        return "\(level) · \(tag.replacingOccurrences(of: "_", with: " ")) · \(abi)"
    }

    private static func value(forKey key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct AndroidSystemImagesProvider: CleanupProvider {
    static let providerID = "android-system-images"

    let homeDirectory: URL
    /// A custom SDK folder chosen in Settings; `nil` uses `~/Library/Android/sdk`.
    let sdkDirectory: URL?
    /// A custom virtual-device folder chosen in Settings; `nil` uses `~/.android/avd`.
    let customAVDDirectory: URL?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sdkDirectory: URL? = nil,
        avdDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.sdkDirectory = sdkDirectory?.standardizedFileURL
        self.customAVDDirectory = avdDirectory?.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .androidSystemImages }
    var allowedRoots: [URL] {
        if let sdkDirectory {
            return [sdkDirectory.appendingPathComponent("system-images", isDirectory: true)]
        }
        return [AndroidSystemImageRules.imagesRoot(homeDirectory: homeDirectory)]
    }

    var avdDirectory: URL {
        customAVDDirectory ?? AndroidSystemImageRules.avdDirectory(homeDirectory: homeDirectory)
    }

    var ruleContext: CleanupRuleContext {
        CleanupRuleContext(androidAVDDirectory: avdDirectory)
    }

    @concurrent
    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let devices = avdDirectory
        let devicesLabel = devices.path.replacingOccurrences(
            of: homeDirectory.path,
            with: "~",
            options: .anchored
        )
        return await ProviderSupport.scanDirectoryCandidates(
            providerID: id,
            location: location,
            roots: allowedRoots,
            context: context,
            progress: progress
        ) { root in
            AndroidSystemImageRules.unusedImages(in: root, avdDirectory: devices).map {
                ProviderSupport.DirectoryCandidate(
                    url: $0,
                    name: AndroidSystemImageRules.displayName(for: $0),
                    explanation: "An emulator system image that none of your Android virtual devices uses. Android Studio's SDK Manager can download it again.",
                    detail: "Not used by any virtual device in \(devicesLabel)"
                )
            }
        }
    }
}
