import Foundation
import UniformTypeIdentifiers

enum AnalyzerTraversalPurpose: Sendable {
    case largeFiles
    case largeFolders
    case downloads
    case duplicates
}

struct AnalyzerEnumerationResult: Sendable {
    let files: [FileItem]
    let issues: [ScanIssue]
    let filesAnalyzed: Int
    let bytesAnalyzed: Int64
}

enum AnalyzerFileSystem {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentAccessDateKey,
        .contentTypeKey,
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey
    ]

    private static let photoLibraryExtensions: Set<String> = [
        "photoslibrary",
        "photolibrary",
        "aplibrary"
    ]

    static func enumerateFiles(
        roots: [URL],
        minimumSize: Int64,
        context: ScanContext,
        purpose: AnalyzerTraversalPurpose,
        progressLocation: CleanupLocation?,
        progressBatchSize: Int,
        emitFinalizingProgress: Bool = true,
        progress: @escaping ScanProgressHandler
    ) async throws -> AnalyzerEnumerationResult {
        var files: [FileItem] = []
        var issues: [ScanIssue] = []
        var filesAnalyzed = 0
        var bytesAnalyzed: Int64 = 0
        let fileManager = FileManager.default
        let normalizedRoots = nonOverlappingRoots(roots)

        await progress(
            progressValue(
                phase: .preparing,
                location: progressLocation,
                path: normalizedRoots.first?.path ?? "",
                filesAnalyzed: 0,
                bytesFound: 0
            )
        )

        for root in normalizedRoots {
            try Task.checkCancellation()
            var pendingDirectories = [root.standardizedFileURL]

            while let directory = pendingDirectories.popLast() {
                try Task.checkCancellation()

                guard let directoryMetadata = metadata(for: directory, issueSink: &issues) else {
                    continue
                }

                if directoryMetadata.isSymbolicLink {
                    continue
                }

                if directoryMetadata.isRegularFile {
                    filesAnalyzed += 1
                    bytesAnalyzed = addingClamped(bytesAnalyzed, directoryMetadata.size)
                    if !shouldExclude(
                        directory,
                        metadata: directoryMetadata,
                        context: context,
                        purpose: purpose,
                        isRoot: true
                    ), directoryMetadata.size >= minimumSize {
                        files.append(fileItem(
                            from: directoryMetadata,
                            purpose: purpose,
                            context: context
                        ))
                    }
                    continue
                }

                guard directoryMetadata.isDirectory else { continue }
                guard !shouldExclude(
                    directory,
                    metadata: directoryMetadata,
                    context: context,
                    purpose: purpose,
                    isRoot: directory == root.standardizedFileURL
                ) else {
                    continue
                }

                let options: FileManager.DirectoryEnumerationOptions = context.showHiddenFiles
                    ? []
                    : [.skipsHiddenFiles]

                let children: [URL]
                do {
                    children = try fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: options
                    )
                } catch {
                    issues.append(issue(for: error, at: directory))
                    continue
                }

                for child in children {
                    try Task.checkCancellation()
                    guard let childMetadata = metadata(for: child, issueSink: &issues) else {
                        continue
                    }

                    if shouldExclude(
                        child,
                        metadata: childMetadata,
                        context: context,
                        purpose: purpose,
                        isRoot: false
                    ) {
                        continue
                    }

                    if childMetadata.isSymbolicLink {
                        continue
                    }

                    if childMetadata.isDirectory {
                        pendingDirectories.append(child.standardizedFileURL)
                        continue
                    }

                    guard childMetadata.isRegularFile else { continue }
                    filesAnalyzed += 1
                    bytesAnalyzed = addingClamped(bytesAnalyzed, childMetadata.size)

                    if childMetadata.size >= minimumSize {
                        files.append(fileItem(
                            from: childMetadata,
                            purpose: purpose,
                            context: context
                        ))
                    }

                    if filesAnalyzed.isMultiple(of: max(1, progressBatchSize)) {
                        await progress(
                            progressValue(
                                phase: .enumerating,
                                location: progressLocation,
                                path: child.path,
                                filesAnalyzed: filesAnalyzed,
                                bytesFound: bytesAnalyzed
                            )
                        )
                    }
                }
            }
        }

        try Task.checkCancellation()
        if emitFinalizingProgress {
            await progress(
                progressValue(
                    phase: .finalizing,
                    location: progressLocation,
                    path: normalizedRoots.first?.path ?? "",
                    filesAnalyzed: filesAnalyzed,
                    bytesFound: bytesAnalyzed
                )
            )
        }

        return AnalyzerEnumerationResult(
            files: files,
            issues: issues,
            filesAnalyzed: filesAnalyzed,
            bytesAnalyzed: bytesAnalyzed
        )
    }

    static func metadata(
        for url: URL,
        issueSink: inout [ScanIssue]
    ) -> AnalyzerFileMetadata? {
        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            return AnalyzerFileMetadata(url: url, values: values)
        } catch {
            issueSink.append(issue(for: error, at: url))
            return nil
        }
    }

    static func shouldExclude(
        _ url: URL,
        metadata: AnalyzerFileMetadata,
        context: ScanContext,
        purpose: AnalyzerTraversalPurpose,
        isRoot: Bool
    ) -> Bool {
        let standardizedURL = url.standardizedFileURL

        if context.exclusions.contains(where: { contains(standardizedURL, in: $0) }) {
            return true
        }

        if context.excludeCloudPlaceholders, metadata.isCloudPlaceholder {
            return true
        }

        if !context.showHiddenFiles, metadata.isHidden, !isRoot {
            return true
        }

        guard metadata.isDirectory else { return false }

        let lowercaseName = standardizedURL.lastPathComponent.lowercased()
        if context.excludedDirectoryNames.contains(lowercaseName) {
            return true
        }

        if purpose == .duplicates,
           context.excludeNodeModulesFromDeepScans,
           lowercaseName == "node_modules" {
            return true
        }

        if context.excludePhotoLibraries,
           photoLibraryExtensions.contains(standardizedURL.pathExtension.lowercased()) {
            return true
        }

        if context.excludeTimeMachineBackups, isTimeMachinePath(standardizedURL) {
            return true
        }

        // Directory packages are intentionally treated as opaque. Reading their
        // internals is unnecessary for these discovery tools and can be expensive.
        if context.excludePackageContents, metadata.isPackage {
            return true
        }

        return false
    }

    static func issue(for error: Error, at url: URL) -> ScanIssue {
        let nsError = error as NSError
        let kind: ScanIssue.Kind

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.fileReadNoPermission.rawValue,
                 CocoaError.fileWriteNoPermission.rawValue:
                kind = .permissionDenied
            case CocoaError.fileNoSuchFile.rawValue,
                 CocoaError.fileReadNoSuchFile.rawValue:
                kind = .disappeared
            case CocoaError.fileReadUnknown.rawValue,
                 CocoaError.fileReadCorruptFile.rawValue:
                kind = .inputOutput
            default:
                kind = .inaccessible
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                kind = .permissionDenied
            case Int(ENOENT):
                kind = .disappeared
            case Int(EIO):
                kind = .inputOutput
            default:
                kind = .inaccessible
            }
        } else {
            kind = .unknown
        }

        return ScanIssue(
            kind: kind,
            path: url.path,
            message: nsError.localizedDescription
        )
    }

    static func progressValue(
        phase: ScanPhase,
        location: CleanupLocation?,
        path: String,
        filesAnalyzed: Int,
        bytesFound: Int64
    ) -> ScanProgress {
        ScanProgress(
            phase: phase,
            location: location,
            currentPath: path,
            filesAnalyzed: filesAnalyzed,
            bytesFound: bytesFound,
            completedProviders: 0,
            totalProviders: 0
        )
    }

    static func addingClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(max(0, rhs))
        return overflow ? Int64.max : result
    }

    private static func fileItem(
        from metadata: AnalyzerFileMetadata,
        purpose: AnalyzerTraversalPurpose,
        context: ScanContext
    ) -> FileItem {
        let item = metadata.fileItem
        if purpose == .downloads,
           let identity = try? SafetyValidator.captureIdentity(at: metadata.url) {
            CleanupSnapshotRegistry.shared.record(
                providerID: DownloadsProvider.analysisSnapshotProviderID,
                itemID: item.id,
                identity: identity,
                exclusionRoots: context.exclusions
            )
        }
        return item
    }

    private static func nonOverlappingRoots(_ roots: [URL]) -> [URL] {
        let unique = Dictionary(
            roots.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path.count < $1.path.count }

        var result: [URL] = []
        for candidate in unique where !result.contains(where: { contains(candidate, in: $0) }) {
            result.append(candidate)
        }
        return result
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard candidatePath != rootPath else { return true }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func isTimeMachinePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        return components.contains(".timemachine")
            || components.contains(".mobilebackups")
            || components.contains("backups.backupdb")
    }
}

struct AnalyzerFileMetadata: Sendable {
    let url: URL
    let size: Int64
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isCloudPlaceholder: Bool
    let createdAt: Date?
    let modifiedAt: Date?
    let accessedAt: Date?
    let contentTypeIdentifier: String?

    init(url: URL, values: URLResourceValues) {
        self.url = url.standardizedFileURL
        size = Int64(max(0, values.fileSize ?? 0))
        isDirectory = values.isDirectory == true
        isRegularFile = values.isRegularFile == true
        isSymbolicLink = values.isSymbolicLink == true
        isPackage = values.isPackage == true
        isHidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
        isCloudPlaceholder = values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus != .current
        createdAt = values.creationDate
        modifiedAt = values.contentModificationDate
        accessedAt = values.contentAccessDate
        contentTypeIdentifier = values.contentType?.identifier
    }

    var fileItem: FileItem {
        FileItem(
            url: url,
            size: size,
            kind: isSymbolicLink ? .symbolicLink : (isDirectory ? .directory : .file),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            accessedAt: accessedAt,
            contentTypeIdentifier: contentTypeIdentifier,
            isHidden: isHidden
        )
    }
}
