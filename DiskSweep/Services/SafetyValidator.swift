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

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        additionalProtectedLocations: [URL] = []
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.temporaryDirectory = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.additionalProtectedLocations = additionalProtectedLocations.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    func validate(_ target: URL, allowedRoots: [URL]) throws -> ValidatedCleanupTarget {
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
        let roots = try existingRoots.map(canonicalApprovedRoot)
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
            let requestedIsScoped = Self.isSameOrDescendant(requested, of: root.requested)
                || Self.isSameOrDescendant(requested, of: root.resolved)
            return requestedIsScoped
                && Self.isSameOrDescendant(resolved, of: root.resolved)
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
        return try validate(target, allowedRoots: allowedRoots)
    }

    func preflightApprovedRoot(
        _ root: URL,
        location: CleanupLocation
    ) throws -> URL {
        let approved = try canonicalApprovedRoot(root)
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
        exclusionRoots: [URL]
    ) throws {
        let normalizedExclusions = exclusionRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        if normalizedExclusions.contains(where: {
            Self.isSameOrDescendant(validated.deletionURL, of: $0)
        }) {
            throw SafetyValidationError.excludedContent(validated.deletionURL.path)
        }
        guard validated.identity.kind == .directory else { return }

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
            let name = standardized.lastPathComponent.lowercased()
            let pathExtension = standardized.pathExtension.lowercased()

            if FileSystemSafetyPolicy.excludedNames.contains(name)
                || FileSystemSafetyPolicy.excludedExtensions.contains(pathExtension)
                || FileSystemSafetyPolicy.excludes(standardized)
                || normalizedExclusions.contains(where: {
                    Self.isSameOrDescendant(standardized, of: $0)
                }) {
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
            if isProtected(standardized.resolvingSymlinksInPath()) {
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

    private func canonicalApprovedRoot(_ root: URL) throws -> ApprovedRoot {
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
              !isProtectedApprovedRoot(resolved) else {
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
            return Self.isSameOrDescendant(root, of: temporaryDirectory)
        case .trash:
            return root == homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        case .downloads:
            return root == homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        case .applicationCaches:
            return isApplicationContainerCacheRoot(root)
        case .browserCaches:
            return isBrowserCacheRoot(root)
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
            return Self.isSameOrDescendant(root, of: standard)
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

        if Self.isSameOrDescendant(root, of: containers),
           let index = components.lastIndex(of: "Containers"),
           components.count == index + 5 {
            return Array(components.suffix(3)) == ["Data", "Library", "Caches"]
        }
        if Self.isSameOrDescendant(root, of: groups),
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
        guard Self.isSameOrDescendant(root, of: devices),
              let index = components.lastIndex(of: "Devices"),
              components.count == index + 5 else {
            return false
        }
        return Array(components.suffix(3)) == ["data", "Library", "Caches"]
    }

    private func isWithinUserScope(_ url: URL) -> Bool {
        Self.isSameOrDescendant(url, of: temporaryDirectory)
            || (Self.isSameOrDescendant(url, of: homeDirectory) && url != homeDirectory)
    }

    private func isProtectedApprovedRoot(_ url: URL) -> Bool {
        if isProtected(url) { return true }

        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if Self.isSameOrDescendantCaseInsensitive(url, of: applicationSupport) {
            return !Self.isRecognizedCacheRoot(url)
        }

        let containers = homeDirectory
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let groupContainers = homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        if Self.isSameOrDescendantCaseInsensitive(url, of: containers)
            || Self.isSameOrDescendantCaseInsensitive(url, of: groupContainers) {
            return !Self.isRecognizedCacheRoot(url)
        }

        return false
    }

    private func isProtected(_ url: URL) -> Bool {
        if url.path == "/" { return true }

        let protectedSystemPaths = [
            "/System", "/Library", "/Applications", "/bin", "/sbin",
            "/usr", "/Volumes"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        if protectedSystemPaths.contains(where: {
            Self.isSameOrDescendantCaseInsensitive(url, of: $0)
        }) {
            return true
        }

        let privateRoot = URL(fileURLWithPath: "/private", isDirectory: true)
        if Self.isSameOrDescendantCaseInsensitive(url, of: privateRoot),
           !Self.isSameOrDescendant(url, of: temporaryDirectory) {
            return true
        }

        let protectedHomePaths = [
            "Desktop", "Documents", "Pictures", "Music", "Movies",
            ".ssh", ".gnupg", "Library/Keychains", "Library/Mail",
            "Library/Messages", "Library/Photos", "Library/Safari",
            "Library/Cookies", "Library/Accounts", "Library/Calendars",
            "Library/CloudStorage", "Library/Application Support/MobileSync"
        ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }

        if protectedHomePaths.contains(where: {
            Self.isSameOrDescendantCaseInsensitive(url, of: $0)
        }) {
            return true
        }

        let applicationSupport = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        if url.path.caseInsensitiveCompare(applicationSupport.path) == .orderedSame {
            return true
        }

        if additionalProtectedLocations.contains(where: {
            Self.isSameOrDescendantCaseInsensitive(url, of: $0)
        }) {
            return true
        }

        let components = url.pathComponents.map { $0.lowercased() }
        return components.contains(where: {
            $0.hasSuffix(".photoslibrary")
                || $0.hasSuffix(".photolibrary")
                || $0 == "backups.backupdb"
                || $0 == ".mobilebackups"
        })
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

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isSameOrDescendantCaseInsensitive(
        _ candidate: URL,
        of root: URL
    ) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(candidateComponents, rootComponents).allSatisfy {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }
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
