import Darwin
import Foundation

enum SafetyValidationError: Error, LocalizedError, Sendable {
    case nonFileURL
    case traversalComponent(String)
    case noApprovedRoots
    case invalidApprovedRoot(String)
    case targetDoesNotExist(String)
    case cannotInspect(String)
    case targetIsApprovedRoot(String)
    case outsideApprovedRoots(String)
    case protectedLocation(String)
    case symbolicLink(String)
    case unsupportedFileType(String)
    case excludedContent(String)
    case volumeBoundary(String)
    case targetChanged(String)
    case unrecognizedProjectArtifact(String)
    case noLongerQualifies(String)

    var errorDescription: String? {
        switch self {
        case .nonFileURL:
            "Only local file URLs can be cleaned."
        case let .traversalComponent(path):
            "The path contains a traversal component: \(path)"
        case .noApprovedRoots:
            "No approved cleanup roots were supplied."
        case let .invalidApprovedRoot(path):
            "The cleanup root is not an approved user-scoped directory: \(path)"
        case let .targetDoesNotExist(path):
            "The cleanup target no longer exists: \(path)"
        case let .cannotInspect(path):
            "The cleanup target could not be inspected safely: \(path)"
        case let .targetIsApprovedRoot(path):
            "DiskSweep never removes an approved cleanup root itself: \(path)"
        case let .outsideApprovedRoots(path):
            "The target is outside this provider's approved cleanup roots: \(path)"
        case let .protectedLocation(path):
            "The target is in a protected location: \(path)"
        case let .symbolicLink(path):
            "Direct symbolic-link cleanup targets are refused: \(path)"
        case let .unsupportedFileType(path):
            "Only regular files and directories can be cleaned: \(path)"
        case let .excludedContent(path):
            "The directory contains content excluded from cleanup: \(path)"
        case let .volumeBoundary(path):
            "The target crosses a filesystem boundary: \(path)"
        case let .targetChanged(path):
            "The target changed after validation and was not removed: \(path)"
        case let .unrecognizedProjectArtifact(path):
            "The folder no longer has the marker that identifies it as a rebuildable project artifact: \(path)"
        case let .noLongerQualifies(path):
            "The item no longer qualifies for cleanup. It may be in use again, or the newer version that replaced it is gone: \(path)"
        }
    }
}

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteSize: Int64
    let allocatedByteSize: Int64
    let modificationTime: Int64
    let modificationNanoseconds: Int64
    let changeTime: Int64
    let changeNanoseconds: Int64
    let kind: FileItemKind

    var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationTime)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }

    var displayByteSize: Int64 {
        max(0, allocatedByteSize > 0 ? allocatedByteSize : byteSize)
    }
}

struct ValidatedCleanupTarget: Sendable {
    let requestedURL: URL
    let deletionURL: URL
    let approvedRoot: URL
    let identity: FileIdentity
}

struct SafetyValidator: Sendable {
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let additionalProtectedLocations: [URL]

    /// Protected roots as standardized path components, computed once so `isProtected`
    /// allocates no URLs. The pre-delete walk calls it for every descendant.
    private let protectedSystemComponents: [[String]]
    private let privateComponents: [String]
    private let temporaryComponents: [String]
    private let protectedHomeComponents: [[String]]
    private let applicationSupportComponents: [String]
    private let additionalProtectedComponents: [[String]]

    static let protectedSystemPaths = [
        "/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/Volumes"
    ]

    static let protectedHomeRelativePaths = [
        "Desktop", "Documents", "Pictures", "Music", "Movies",
        ".ssh", ".gnupg", "Library/Keychains", "Library/Mail",
        "Library/Messages", "Library/Photos", "Library/Safari",
        "Library/Cookies", "Library/Accounts", "Library/Calendars",
        "Library/CloudStorage", "Library/Application Support/MobileSync"
    ]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        additionalProtectedLocations: [URL] = []
    ) {
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let additional = additionalProtectedLocations.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.homeDirectory = home
        self.temporaryDirectory = temporary
        self.additionalProtectedLocations = additional

        func components(_ url: URL) -> [String] { url.standardizedFileURL.pathComponents }
        protectedSystemComponents = Self.protectedSystemPaths.map {
            components(URL(fileURLWithPath: $0, isDirectory: true))
        }
        privateComponents = components(URL(fileURLWithPath: "/private", isDirectory: true))
        temporaryComponents = components(temporary)
        protectedHomeComponents = Self.protectedHomeRelativePaths.map {
            components(home.appendingPathComponent($0, isDirectory: true))
        }
        applicationSupportComponents = components(
            home.appendingPathComponent("Library/Application Support", isDirectory: true)
        )
        additionalProtectedComponents = additional.map(components)
    }

    func validate(_ target: URL, allowedRoots: [URL]) throws -> ValidatedCleanupTarget {
        try validate(target, allowedRoots: allowedRoots, location: nil)
    }

    private func validate(
        _ target: URL,
        allowedRoots: [URL],
        location: CleanupLocation?
    ) throws -> ValidatedCleanupTarget {
        guard target.isFileURL else { throw SafetyValidationError.nonFileURL }
        guard !Self.containsTraversal(in: target) else {
            throw SafetyValidationError.traversalComponent(target.path)
        }
        guard !allowedRoots.isEmpty else {
            throw SafetyValidationError.noApprovedRoots
        }

        let existingRoots = allowedRoots.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existingRoots.isEmpty else {
            throw SafetyValidationError.noApprovedRoots
        }
        let roots = try existingRoots.map { try canonicalApprovedRoot($0, location: location) }
        let requested = target.standardizedFileURL

        let requestedIdentity = try Self.captureIdentity(at: requested)
        if requestedIdentity.kind == .symbolicLink {
            throw SafetyValidationError.symbolicLink(requested.path)
        }

        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let resolvedIdentity = try Self.captureIdentity(at: resolved)
        guard resolvedIdentity.kind == .file || resolvedIdentity.kind == .directory else {
            throw SafetyValidationError.unsupportedFileType(resolved.path)
        }

        guard let matchingRoot = roots.first(where: { root in
            let requestedIsScoped = requested.isSameOrDescendant(of: root.requested)
                || requested.isSameOrDescendant(of: root.resolved)
            return requestedIsScoped
                && resolved.isSameOrDescendant(of: root.resolved)
        }) else {
            throw SafetyValidationError.outsideApprovedRoots(resolved.path)
        }

        guard resolved != matchingRoot.resolved else {
            throw SafetyValidationError.targetIsApprovedRoot(resolved.path)
        }
        guard !isProtected(resolved) else {
            throw SafetyValidationError.protectedLocation(resolved.path)
        }
        guard resolvedIdentity.device == matchingRoot.identity.device else {
            throw SafetyValidationError.volumeBoundary(resolved.path)
        }

        return ValidatedCleanupTarget(
            requestedURL: requested,
            deletionURL: resolved,
            approvedRoot: matchingRoot.resolved,
            identity: resolvedIdentity
        )
    }

    func validate(
        _ target: URL,
        location: CleanupLocation,
        allowedRoots: [URL]
    ) throws -> ValidatedCleanupTarget {
        for root in allowedRoots where FileManager.default.fileExists(atPath: root.path) {
            let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
            guard isExpectedRoot(resolved, for: location) else {
                throw SafetyValidationError.invalidApprovedRoot(resolved.path)
            }
        }
        return try validate(target, allowedRoots: allowedRoots, location: location)
    }

    func preflightApprovedRoot(
        _ root: URL,
        location: CleanupLocation
    ) throws -> URL {
        let approved = try canonicalApprovedRoot(root, location: location)
        guard isExpectedRoot(approved.resolved, for: location) else {
            throw SafetyValidationError.invalidApprovedRoot(approved.resolved.path)
        }
        return approved.resolved
    }

    func revalidate(
        _ validated: ValidatedCleanupTarget,
        allowedRoots: [URL]
    ) throws -> ValidatedCleanupTarget {
        let current = try validate(validated.deletionURL, allowedRoots: allowedRoots)
        guard current.deletionURL == validated.deletionURL,
              current.approvedRoot == validated.approvedRoot,
              current.identity == validated.identity else {
            throw SafetyValidationError.targetChanged(validated.deletionURL.path)
        }
        return current
    }

    func validateDirectoryContents(
        _ validated: ValidatedCleanupTarget,
        exclusionRoots: [URL],
        permittedNestedNames: Set<String> = []
    ) throws {
        let normalizedExclusions = exclusionRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        if normalizedExclusions.contains(where: {
            validated.deletionURL.isSameOrDescendant(of: $0)
        }) {
            throw SafetyValidationError.excludedContent(validated.deletionURL.path)
        }
        guard validated.identity.kind == .directory else { return }
        let exclusionComponents = normalizedExclusions.map {
            $0.standardizedFileURL.pathComponents
        }

        let manager = FileManager()
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: validated.deletionURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw SafetyValidationError.cannotInspect(validated.deletionURL.path)
        }

        while let candidate = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            let standardized = candidate.standardizedFileURL
            let components = standardized.pathComponents
            let name = standardized.lastPathComponent.lowercased()
            let pathExtension = standardized.pathExtension.lowercased()

            let isExcludedByPolicy = !permittedNestedNames.contains(name)
                && (FileSystemSafetyPolicy.excludedNames.contains(name)
                    || FileSystemSafetyPolicy.excludes(standardized))
            if isExcludedByPolicy
                || FileSystemSafetyPolicy.excludedExtensions.contains(pathExtension)
                || exclusionComponents.contains(where: { Self.hasPrefix(components, $0) }) {
                throw SafetyValidationError.excludedContent(standardized.path)
            }

            let identity = try Self.captureIdentity(at: standardized)
            if identity.kind == .symbolicLink {
                enumerator.skipDescendants()
                continue
            }
            guard identity.device == validated.identity.device else {
                throw SafetyValidationError.volumeBoundary(standardized.path)
            }
            // No symlink resolution is needed here: the walk starts at the resolved target,
            // never descends into a symbolic link (skipped above), and stays on one volume,
            // so every entry's path is already its resolved path.
            if isProtected(components: components) {
                throw SafetyValidationError.protectedLocation(standardized.path)
            }
        }

        if enumerationError != nil {
            throw SafetyValidationError.cannotInspect(validated.deletionURL.path)
        }
    }

    func revalidate(
        _ validated: ValidatedCleanupTarget,
        location: CleanupLocation,
        allowedRoots: [URL]
    ) throws -> ValidatedCleanupTarget {
        let current = try validate(
            validated.deletionURL,
            location: location,
            allowedRoots: allowedRoots
        )
        guard current.deletionURL == validated.deletionURL,
              current.approvedRoot == validated.approvedRoot,
              current.identity == validated.identity else {
            throw SafetyValidationError.targetChanged(validated.deletionURL.path)
        }
        return current
    }

    private struct ApprovedRoot {
        let requested: URL
        let resolved: URL
        let identity: FileIdentity
    }

    private func canonicalApprovedRoot(
        _ root: URL,
        location: CleanupLocation?
    ) throws -> ApprovedRoot {
        guard root.isFileURL, !Self.containsTraversal(in: root) else {
            throw SafetyValidationError.invalidApprovedRoot(root.path)
        }

        let requested = root.standardizedFileURL
        let requestedIdentity: FileIdentity
        do {
            requestedIdentity = try Self.captureIdentity(at: requested)
        } catch {
            throw SafetyValidationError.invalidApprovedRoot(requested.path)
        }
        guard requestedIdentity.kind != .symbolicLink else {
            throw SafetyValidationError.invalidApprovedRoot(requested.path)
        }

        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        let identity: FileIdentity
        do {
            identity = try Self.captureIdentity(at: resolved)
        } catch {
            throw SafetyValidationError.invalidApprovedRoot(resolved.path)
        }

        guard identity.kind == .directory,
              resolved.path != "/",
              resolved != homeDirectory,
              isWithinUserScope(resolved),
              !isProtectedApprovedRoot(resolved, location: location) else {
            throw SafetyValidationError.invalidApprovedRoot(resolved.path)
        }

        return ApprovedRoot(requested: requested, resolved: resolved, identity: identity)
    }

    private func isExpectedRoot(_ root: URL, for location: CleanupLocation) -> Bool {
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        let developer = library.appendingPathComponent("Developer", isDirectory: true)
        let xcode = developer.appendingPathComponent("Xcode", isDirectory: true)

        switch location {
        case .userCaches:
            return root == library.appendingPathComponent("Caches", isDirectory: true)
        case .userLogs:
            return root == library.appendingPathComponent("Logs", isDirectory: true)
        case .temporaryFiles:
            return root.isSameOrDescendant(of: temporaryDirectory)
        case .trash:
            return root == homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        case .downloads:
            return root == homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        case .applicationCaches:
            return isApplicationContainerCacheRoot(root)
        case .browserCaches:
            return isBrowserCacheRoot(root)
        case .electronAppCaches:
            return ElectronAppCacheRules.isApplicationDirectory(root, homeDirectory: homeDirectory)
        case .xcodeDerivedData:
            return root == xcode.appendingPathComponent("DerivedData", isDirectory: true)
        case .xcodeArchives:
            return root == xcode.appendingPathComponent("Archives", isDirectory: true)
        case .xcodeSimulatorData:
            return isSimulatorCacheRoot(root, developer: developer)
        case .xcodeDeviceSupport:
            let names = [
                "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
                "visionOS DeviceSupport"
            ]
            return names.contains {
                root == xcode.appendingPathComponent($0, isDirectory: true)
            }
        case .swiftPackageCaches:
            let expected = [
                library.appendingPathComponent("Caches/org.swift.swiftpm", isDirectory: true),
                homeDirectory.appendingPathComponent(".swiftpm/cache", isDirectory: true),
                homeDirectory.appendingPathComponent(".cache/org.swift.swiftpm", isDirectory: true)
            ]
            return expected.contains(root)
        case .homebrewCache:
            let standard = library.appendingPathComponent(
                "Caches/Homebrew",
                isDirectory: true
            )
            return root.isSameOrDescendant(of: standard)
        case .developerToolCaches:
            return DeveloperToolCacheProvider.cacheDirectories.contains {
                homeDirectory.appendingPathComponent($0.relativePath, isDirectory: true)
                    .pathComponents == root.pathComponents
            }
        case .staleIDEVersions:
            return isStaleIDEVersionsRoot(root)
        case .androidSystemImages:
            return AndroidSystemImageRules.imagesRoot(homeDirectory: homeDirectory)
                .pathComponents == root.pathComponents
        case .projectArtifacts:
            // Project folders are chosen by the user. Protected locations and the home folder
            // itself are already refused by canonicalApprovedRoot; the Library and Trash are
            // owned by other providers and are never project folders.
            let trash = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
            return root.isSameOrDescendant(of: homeDirectory)
                && !root.isSameOrDescendantIgnoringCase(of: library)
                && !root.isSameOrDescendantIgnoringCase(of: trash)
        }
    }

    /// IDE version folders live directly in Application Support, which is otherwise only
    /// approved for cache-named folders. Only these exact vendor folders are accepted, and the
    /// cleanup engine separately requires every target to be a superseded version folder.
    private func isStaleIDEVersionsRoot(_ root: URL) -> Bool {
        StaleIDEVersionRules.roots(homeDirectory: homeDirectory).contains {
            $0.standardizedFileURL.pathComponents == root.standardizedFileURL.pathComponents
        }
    }

    private func isApplicationContainerCacheRoot(_ root: URL) -> Bool {
        let containers = homeDirectory.appendingPathComponent(
            "Library/Containers",
            isDirectory: true
        )
        let groups = homeDirectory.appendingPathComponent(
            "Library/Group Containers",
            isDirectory: true
        )
        let components = root.pathComponents

        if root.isSameOrDescendant(of: containers),
           let index = components.lastIndex(of: "Containers"),
           components.count == index + 5 {
            return Array(components.suffix(3)) == ["Data", "Library", "Caches"]
        }
        if root.isSameOrDescendant(of: groups),
           let index = components.lastIndex(of: "Group Containers"),
           components.count == index + 4 {
            return Array(components.suffix(2)) == ["Library", "Caches"]
        }
        return false
    }

    private func isBrowserCacheRoot(_ root: URL) -> Bool {
        let browserRoots = [
            "Library/Caches/com.apple.Safari",
            "Library/Caches/Google/Chrome",
            "Library/Caches/Chromium",
            "Library/Caches/Microsoft Edge",
            "Library/Caches/BraveSoftware/Brave-Browser",
            "Library/Caches/Firefox/Profiles",
            "Library/Caches/Mozilla/Firefox/Profiles",
            "Library/Containers/com.apple.Safari/Data/Library/Caches"
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        if browserRoots.contains(root) { return true }

        let profileBases = [
            "Library/Application Support/Google/Chrome",
            "Library/Application Support/Chromium",
            "Library/Application Support/Microsoft Edge",
            "Library/Application Support/BraveSoftware/Brave-Browser"
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
        let cacheNames: Set<String> = [
            "Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache"
        ]
        guard cacheNames.contains(root.lastPathComponent) else { return false }

        let profile = root.deletingLastPathComponent()
        let profileName = profile.lastPathComponent
        let isProfile = profileName == "Default"
            || profileName == "Guest Profile"
            || profileName.hasPrefix("Profile ")
        return isProfile && profileBases.contains(profile.deletingLastPathComponent())
    }

    private func isSimulatorCacheRoot(_ root: URL, developer: URL) -> Bool {
        let coreSimulator = developer.appendingPathComponent(
            "CoreSimulator",
            isDirectory: true
        )
        if root == coreSimulator.appendingPathComponent("Caches", isDirectory: true) {
            return true
        }

        let devices = coreSimulator.appendingPathComponent("Devices", isDirectory: true)
        let components = root.pathComponents
        guard root.isSameOrDescendant(of: devices),
              let index = components.lastIndex(of: "Devices"),
              components.count == index + 5 else {
            return false
        }
        return Array(components.suffix(3)) == ["data", "Library", "Caches"]
    }

    private func isWithinUserScope(_ url: URL) -> Bool {
        url.isSameOrDescendant(of: temporaryDirectory)
            || (url.isSameOrDescendant(of: homeDirectory) && url != homeDirectory)
    }

    private func isProtectedApprovedRoot(_ url: URL, location: CleanupLocation?) -> Bool {
        if isProtected(url) { return true }
        // These roots sit in Application Support. The engine only lets each one's items go
        // after rechecking that they are superseded IDE versions or Chromium cache folders.
        if location == .staleIDEVersions, isStaleIDEVersionsRoot(url) { return false }
        if location == .electronAppCaches,
           ElectronAppCacheRules.isApplicationDirectory(url, homeDirectory: homeDirectory) {
            return false
        }

        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if url.isSameOrDescendantIgnoringCase(of: applicationSupport) {
            return !Self.isRecognizedCacheRoot(url)
        }

        let containers = homeDirectory
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let groupContainers = homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        if url.isSameOrDescendantIgnoringCase(of: containers)
            || url.isSameOrDescendantIgnoringCase(of: groupContainers) {
            return !Self.isRecognizedCacheRoot(url)
        }

        return false
    }

    func isProtected(_ url: URL) -> Bool {
        // The name check also runs on the raw components, as before 5.3, so a path that
        // mentions a photo library or backup store before a `..` is still protected.
        isProtected(components: url.standardizedFileURL.pathComponents)
            || Self.containsProtectedStoreName(url.pathComponents)
    }

    /// `components` are a standardized path's components. Comparisons are by whole component,
    /// case-insensitive except for the temporary directory, as before 5.3.
    func isProtected(components: [String]) -> Bool {
        if components == ["/"] { return true }

        if protectedSystemComponents.contains(where: {
            Self.hasPrefixIgnoringCase(components, $0)
        }) {
            return true
        }

        if Self.hasPrefixIgnoringCase(components, privateComponents),
           !Self.hasPrefix(components, temporaryComponents) {
            return true
        }

        if protectedHomeComponents.contains(where: {
            Self.hasPrefixIgnoringCase(components, $0)
        }) {
            return true
        }

        if components.count == applicationSupportComponents.count,
           Self.hasPrefixIgnoringCase(components, applicationSupportComponents) {
            return true
        }

        if additionalProtectedComponents.contains(where: {
            Self.hasPrefixIgnoringCase(components, $0)
        }) {
            return true
        }

        return Self.containsProtectedStoreName(components)
    }

    /// Photo libraries and backup stores are protected wherever they appear.
    private static func containsProtectedStoreName(_ components: [String]) -> Bool {
        components.contains { component in
            let lowercased = component.lowercased()
            return lowercased.hasSuffix(".photoslibrary")
                || lowercased.hasSuffix(".photolibrary")
                || lowercased == "backups.backupdb"
                || lowercased == ".mobilebackups"
        }
    }

    private static func hasPrefix(_ components: [String], _ prefix: [String]) -> Bool {
        components.count >= prefix.count && zip(components, prefix).allSatisfy { $0 == $1 }
    }

    private static func hasPrefixIgnoringCase(_ components: [String], _ prefix: [String]) -> Bool {
        components.count >= prefix.count && zip(components, prefix).allSatisfy {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }
    }

    private static func isRecognizedCacheRoot(_ url: URL) -> Bool {
        let cacheDirectoryNames: Set<String> = [
            "cache", "caches", "code cache", "gpucache", "dawncache",
            "grshadercache", "shadercache", "cache2"
        ]
        return cacheDirectoryNames.contains(url.lastPathComponent.lowercased())
    }

    private static func containsTraversal(in url: URL) -> Bool {
        let text = (url.absoluteString.removingPercentEncoding ?? url.absoluteString)
            .replacingOccurrences(of: "\\", with: "/")
        return text.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    static func captureIdentity(at url: URL) throws -> FileIdentity {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }

        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw SafetyValidationError.targetDoesNotExist(url.path)
            }
            throw SafetyValidationError.cannotInspect(url.path)
        }

        let fileType = information.st_mode & S_IFMT
        let kind: FileItemKind
        switch fileType {
        case S_IFREG:
            kind = .file
        case S_IFDIR:
            kind = .directory
        case S_IFLNK:
            kind = .symbolicLink
        default:
            kind = .other
        }

        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            byteSize: Int64(information.st_size),
            allocatedByteSize: Int64(information.st_blocks) * 512,
            modificationTime: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changeTime: Int64(information.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(information.st_ctimespec.tv_nsec),
            kind: kind
        )
    }
}
