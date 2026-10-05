import Foundation

enum ProjectArtifactKind: String, Codable, Hashable, Sendable {
    case pythonVirtualEnvironment
    case taggedCache
    case nodeModules

    var title: String {
        switch self {
        case .pythonVirtualEnvironment: "Python virtual environment"
        case .taggedCache: "Build cache"
        case .nodeModules: "Node.js dependencies"
        }
    }

    var explanation: String {
        switch self {
        case .pythonVirtualEnvironment:
            "A Python virtual environment, recognized by its pyvenv.cfg file. Packages installed by hand rather than from a lock or requirements file will need to be reinstalled."
        case .taggedCache:
            "A folder its own tool marked as a disposable cache with a standard CACHEDIR.TAG file, such as a Rust target folder or a pytest, mypy, or Ruff cache."
        case .nodeModules:
            "Installed Node.js packages next to the project's package.json."
        }
    }
}

/// Marker-based recognition for rebuildable project folders.
///
/// A folder is only treated as an artifact when the tool that created it left a marker behind.
/// Folder names alone (`build`, `env`, `target`) are never enough.
enum ProjectArtifactRules {
    /// The required header from the Cache Directory Tagging Specification (https://bford.info/cachedir/).
    static let cacheDirectoryTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    static let versionControlNames: Set<String> = [".git", ".svn", ".hg"]

    /// Nested names that may appear inside a recognized artifact even though DiskSweep
    /// normally refuses to remove a folder that contains them.
    static let permittedNestedNames: Set<String> = ["node_modules"]

    static func kind(ofDirectory url: URL) -> ProjectArtifactKind? {
        guard (try? SafetyValidator.captureIdentity(at: url))?.kind == .directory else {
            return nil
        }
        if isRegularFile(url.appendingPathComponent("pyvenv.cfg")) {
            return .pythonVirtualEnvironment
        }
        if hasCacheDirectoryTag(url) {
            return .taggedCache
        }
        if url.lastPathComponent == "node_modules",
           isRegularFile(url.deletingLastPathComponent().appendingPathComponent("package.json")) {
            return .nodeModules
        }
        return nil
    }

    static func hasCacheDirectoryTag(_ directory: URL) -> Bool {
        let tag = directory.appendingPathComponent("CACHEDIR.TAG")
        guard isRegularFile(tag),
              let handle = try? FileHandle(forReadingFrom: tag) else {
            return false
        }
        defer { try? handle.close() }
        let signature = Data(cacheDirectoryTagSignature.utf8)
        guard let prefix = try? handle.read(upToCount: signature.count) else { return false }
        return prefix == signature
    }

    /// The command that recreates the artifact, inferred from the project's lock and manifest files.
    static func rebuildCommand(
        for kind: ProjectArtifactKind,
        artifactName: String,
        projectDirectory: URL
    ) -> String? {
        func has(_ name: String) -> Bool {
            isRegularFile(projectDirectory.appendingPathComponent(name))
        }

        switch kind {
        case .pythonVirtualEnvironment:
            if has("uv.lock") { return "uv sync" }
            if has("poetry.lock") { return "poetry install" }
            if has("requirements.txt") {
                return "python3 -m venv \(artifactName) && \(artifactName)/bin/pip install -r requirements.txt"
            }
            if has("pyproject.toml") {
                return "python3 -m venv \(artifactName) && \(artifactName)/bin/pip install -e ."
            }
            return nil
        case .nodeModules:
            if has("pnpm-lock.yaml") { return "pnpm install" }
            if has("yarn.lock") { return "yarn install" }
            if has("bun.lock") || has("bun.lockb") { return "bun install" }
            return "npm install"
        case .taggedCache:
            if artifactName == "target", has("Cargo.toml") { return "cargo build" }
            return nil
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? SafetyValidator.captureIdentity(at: url))?.kind == .file
    }
}

/// Finds rebuildable dependency and build folders inside project folders the user chose,
/// limited to projects that have not changed for a configurable number of days.
struct ProjectArtifactsProvider: CleanupProvider {
    static let providerID = "project-artifacts"
    static let defaultMinimumAge: TimeInterval = 90 * 24 * 60 * 60
    static let maximumDepth = 12

    let projectFolders: [URL]
    let minimumAge: TimeInterval
    let homeDirectory: URL

    init(
        projectFolders: [URL],
        minimumAge: TimeInterval = Self.defaultMinimumAge,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.projectFolders = projectFolders.map(\.standardizedFileURL)
        self.minimumAge = max(24 * 60 * 60, minimumAge)
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    var id: String { Self.providerID }
    var location: CleanupLocation { .projectArtifacts }

    /// Only folders that pass root preflight are authorized. The validator refuses an entire
    /// authorization when any of its roots is unacceptable, so one protected folder in the
    /// list must not block cleanup in the others.
    var allowedRoots: [URL] {
        projectFolders.filter {
            Self.refusalReason(for: $0, homeDirectory: homeDirectory) == nil
        }
    }

    /// Explains why a chosen folder cannot be used, or returns `nil` when it is acceptable.
    static func refusalReason(
        for folder: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        do {
            _ = try SafetyValidator(homeDirectory: homeDirectory)
                .preflightApprovedRoot(folder, location: .projectArtifacts)
            return nil
        } catch {
            return "DiskSweep will skip this folder. Project folders must exist inside your home folder and cannot be in a protected location such as Desktop, Documents, or Library."
        }
    }

    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        let cutoff = context.now.addingTimeInterval(-minimumAge)
        let validator = SafetyValidator(homeDirectory: context.homeDirectory)
        var issues: [ScanIssue] = []

        var roots: [URL] = []
        for root in projectFolders {
            do {
                _ = try validator.preflightApprovedRoot(root, location: location)
                roots.append(root)
            } catch {
                issues.append(ScanIssue(
                    kind: .inaccessible,
                    path: root.path,
                    message: error.localizedDescription
                ))
            }
        }
        // A folder nested inside another chosen folder is already covered by its parent.
        roots = roots.filter { root in
            !roots.contains { other in
                other != root && Self.isStrictDescendant(root, of: other)
            }
        }

        var items: [CleanupItem] = []
        var snapshots: [UUID: CleanupScanSnapshot] = [:]
        var seenPaths: Set<String> = []
        var inspectedFiles = 0
        var inspectedBytes: Int64 = 0

        do {
            for root in roots {
                try Task.checkCancellation()
                let walkBaselineFiles = inspectedFiles
                let walkBaselineBytes = inspectedBytes
                let walk = try await Self.walk(
                    root: root,
                    exclusions: context.exclusions
                ) { visited, currentURL in
                    await progress(ScanProgress(
                        phase: .enumerating,
                        location: .projectArtifacts,
                        currentPath: currentURL.path,
                        filesAnalyzed: walkBaselineFiles + visited,
                        bytesFound: walkBaselineBytes,
                        completedProviders: 0,
                        totalProviders: 1
                    ))
                }
                issues.append(contentsOf: walk.issues)

                for candidate in walk.candidates {
                    try Task.checkCancellation()
                    guard seenPaths.insert(candidate.url.path).inserted else { continue }
                    let projectDirectory = candidate.url.deletingLastPathComponent()
                    // Adding or removing anything at the project's top level, including
                    // recreating the artifact itself, also counts as activity.
                    let projectModifiedAt = try? SafetyValidator
                        .captureIdentity(at: projectDirectory)
                        .modificationDate
                    let lastActivity = [
                        walk.activity[projectDirectory.path],
                        candidate.modifiedAt,
                        projectModifiedAt
                    ].compactMap { $0 }.max() ?? context.now
                    guard lastActivity < cutoff else { continue }

                    let baselineFiles = inspectedFiles
                    let baselineBytes = inspectedBytes
                    let built = try await makeItem(
                        for: candidate,
                        projectDirectory: projectDirectory,
                        lastActivity: lastActivity,
                        context: context,
                        issues: &issues
                    ) { update in
                        await progress(ScanProgress(
                            phase: .enumerating,
                            location: .projectArtifacts,
                            currentPath: update.currentURL.path,
                            filesAnalyzed: baselineFiles + update.filesAnalyzed,
                            bytesFound: baselineBytes + update.bytesFound,
                            completedProviders: 0,
                            totalProviders: 1
                        ))
                    }
                    guard let built else { continue }
                    inspectedFiles += built.item.fileCount
                    inspectedBytes += built.item.size
                    items.append(built.item)
                    snapshots[built.item.id] = built.snapshot
                }
            }
            try Task.checkCancellation()
        } catch {
            CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: [:])
            if error is CancellationError || Task.isCancelled {
                return ProviderScanResult(
                    location: location,
                    items: [],
                    issues: issues + [ScanIssue(
                        kind: .cancelled,
                        path: roots.last?.path ?? "",
                        message: "Scanning was cancelled."
                    )]
                )
            }
            return ProviderScanResult(
                location: location,
                items: [],
                issues: issues + [FileSystemScanner.issue(
                    for: error,
                    at: roots.last ?? URL(fileURLWithPath: "/")
                )]
            )
        }

        items.sort { $0.size > $1.size }
        CleanupSnapshotRegistry.shared.replace(providerID: id, snapshots: snapshots)
        await progress(ScanProgress(
            phase: .completed,
            location: location,
            currentPath: roots.last?.path ?? "",
            filesAnalyzed: items.reduce(0) { $0 + $1.fileCount },
            bytesFound: items.reduce(0) { $0 + $1.size },
            completedProviders: 1,
            totalProviders: 1
        ))

        return ProviderScanResult(location: location, items: items, issues: issues)
    }

    private func makeItem(
        for candidate: ArtifactCandidate,
        projectDirectory: URL,
        lastActivity: Date,
        context: ScanContext,
        issues: inout [ScanIssue],
        onProgress: @escaping DirectorySizeProgressHandler
    ) async throws -> (item: CleanupItem, snapshot: CleanupScanSnapshot)? {
        var isDeletable = true
        var explanation = candidate.kind.explanation
        var byteCount: Int64 = 0
        var fileCount = 0

        do {
            let measured = try await DirectorySizer().size(
                of: candidate.url,
                exclusions: context.exclusions,
                includeHiddenFiles: true,
                skipPackages: false,
                excludedNames: FileSystemSafetyPolicy.excludedNames
                    .subtracting(ProjectArtifactRules.permittedNestedNames),
                batchSize: 256,
                onProgress: onProgress
            )
            byteCount = measured.byteCount
            fileCount = measured.fileCount
            issues.append(contentsOf: measured.issues)
            if !measured.excludedURLs.isEmpty || !measured.issues.isEmpty {
                isDeletable = false
                explanation += " It contains excluded or uninspected content, so DiskSweep will not remove it as a unit."
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            issues.append(FileSystemScanner.issue(for: error, at: candidate.url))
            isDeletable = false
            explanation += " DiskSweep could not inspect every descendant, so this folder cannot be removed."
        }

        let identity: FileIdentity
        do {
            identity = try SafetyValidator.captureIdentity(at: candidate.url)
        } catch {
            issues.append(ScanIssue(
                kind: .disappeared,
                path: candidate.url.path,
                message: "The folder changed or disappeared before its cleanup identity could be recorded."
            ))
            return nil
        }
        guard identity.kind == .directory else { return nil }

        let idleDays = max(0, Int(context.now.timeIntervalSince(lastActivity) / 86_400))
        var detail = "Project unchanged for \(idleDays) days"
        if let command = ProjectArtifactRules.rebuildCommand(
            for: candidate.kind,
            artifactName: candidate.url.lastPathComponent,
            projectDirectory: projectDirectory
        ) {
            detail += " · Rebuild with: \(command)"
        }

        let item = CleanupItem(
            providerID: id,
            location: location,
            name: "\(projectDirectory.lastPathComponent) — \(candidate.kind.title)",
            url: candidate.url,
            size: byteCount,
            fileCount: fileCount,
            kind: .directory,
            modifiedAt: identity.modificationDate,
            risk: .reviewRecommended,
            explanation: explanation,
            detail: detail,
            isSelectedByDefault: false,
            isDeletable: isDeletable
        )
        return (
            item,
            CleanupScanSnapshot(identity: identity, exclusionRoots: context.exclusions)
        )
    }

    // MARK: - Project walk

    struct ArtifactCandidate: Sendable {
        let url: URL
        let kind: ProjectArtifactKind
        let modifiedAt: Date?
    }

    struct WalkResult: Sendable {
        var candidates: [ArtifactCandidate] = []
        /// The newest modification date of any source file at or below each directory path,
        /// ignoring artifacts themselves.
        var activity: [String: Date] = [:]
        var issues: [ScanIssue] = []
    }

    static func walk(
        root requestedRoot: URL,
        exclusions: [URL],
        onProgress: @escaping @Sendable (Int, URL) async -> Void
    ) async throws -> WalkResult {
        let worker = Task.detached(priority: .utility) { () throws -> WalkResult in
            let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
            let normalizedExclusions = exclusions.map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            }
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey
            ]
            var result = WalkResult()
            guard let enumerator = FileManager().enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    result.issues.append(FileSystemScanner.issue(for: error, at: url))
                    return true
                }
            ) else {
                throw FileSystemScannerError.cannotEnumerate(root.path)
            }

            var visited = 0
            while let candidate = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                visited += 1
                if visited % 512 == 0 {
                    await onProgress(visited, candidate)
                }

                let url = candidate.standardizedFileURL
                let name = url.lastPathComponent
                let lowercaseName = name.lowercased()
                let pathExtension = url.pathExtension.lowercased()

                if normalizedExclusions.contains(where: {
                    Self.isSameOrDescendant(url, of: $0)
                        || Self.isSameOrDescendant(url.resolvingSymlinksInPath(), of: $0)
                }) || FileSystemSafetyPolicy.excludedExtensions.contains(pathExtension)
                    || pathExtension == "icloud" {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true {
                    continue
                }

                if values.isDirectory == true {
                    if ProjectArtifactRules.versionControlNames.contains(lowercaseName) {
                        // Commits, checkouts, and staging update these files even when the
                        // working tree is unchanged, so they count as project activity.
                        for marker in ["index", "HEAD", "logs/HEAD"] {
                            if let date = try? SafetyValidator.captureIdentity(
                                at: url.appendingPathComponent(marker)
                            ).modificationDate {
                                Self.record(date, for: url, root: root, in: &result.activity)
                            }
                        }
                        enumerator.skipDescendants()
                        continue
                    }
                    if let kind = ProjectArtifactRules.kind(ofDirectory: url) {
                        result.candidates.append(ArtifactCandidate(
                            url: url,
                            kind: kind,
                            modifiedAt: values.contentModificationDate
                        ))
                        enumerator.skipDescendants()
                        continue
                    }
                    if FileSystemSafetyPolicy.excludedNames.contains(lowercaseName)
                        || enumerator.level >= Self.maximumDepth {
                        // Unrecognized dependency folders and very deep trees are not explored.
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Finder rewrites .DS_Store when a folder is merely browsed, which is not project work.
                if values.isRegularFile == true,
                   name != ".DS_Store",
                   let modified = values.contentModificationDate {
                    Self.record(modified, for: url, root: root, in: &result.activity)
                }
            }
            await onProgress(visited, root)
            return result
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Propagates a modification date to every ancestor directory up to the scan root.
    /// Each ancestor always holds a date at least as new as its descendants, so the walk
    /// stops as soon as it reaches one that is already newer.
    private static func record(
        _ date: Date,
        for url: URL,
        root: URL,
        in activity: inout [String: Date]
    ) {
        let rootComponentCount = root.pathComponents.count
        var directory = url.deletingLastPathComponent()
        while directory.pathComponents.count >= rootComponentCount {
            let path = directory.path
            if let existing = activity[path], existing >= date { return }
            activity[path] = date
            if directory.pathComponents.count == rootComponentCount { return }
            directory = directory.deletingLastPathComponent()
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.pathComponents.count > root.pathComponents.count
            && isSameOrDescendant(candidate, of: root)
    }
}
