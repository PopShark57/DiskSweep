import Foundation

typealias FileSystemScanBatchHandler = @Sendable (FileSystemScanBatch) async -> Void

enum FileSystemSafetyPolicy {
    static let excludedNames: Set<String> = [
        ".git", ".svn", "node_modules", ".spotlight-v100",
        ".documentrevisions-v100", ".fseventsd"
    ]
    static let excludedExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "backupdb"
    ]

    static func excludes(_ url: URL) -> Bool {
        excludedNames.contains(url.lastPathComponent.lowercased())
            || excludedExtensions.contains(url.pathExtension.lowercased())
            || url.pathExtension.lowercased() == "icloud"
    }
}

struct FileSystemScanOptions: Sendable {
    var recursive: Bool
    var includeFiles: Bool
    var includeDirectories: Bool
    var includeSymbolicLinks: Bool
    var includeHiddenFiles: Bool
    var skipPackages: Bool
    var skipCloudPlaceholders: Bool
    var collectItems: Bool
    var batchSize: Int
    var exclusionURLs: [URL]
    var excludedNames: Set<String>
    var excludedExtensions: Set<String>
    var modifiedBefore: Date?

    init(
        recursive: Bool = true,
        includeFiles: Bool = true,
        includeDirectories: Bool = false,
        includeSymbolicLinks: Bool = false,
        includeHiddenFiles: Bool = false,
        skipPackages: Bool = true,
        skipCloudPlaceholders: Bool = true,
        collectItems: Bool = true,
        batchSize: Int = 256,
        exclusionURLs: [URL] = [],
        excludedNames: Set<String> = FileSystemSafetyPolicy.excludedNames,
        excludedExtensions: Set<String> = FileSystemSafetyPolicy.excludedExtensions,
        modifiedBefore: Date? = nil
    ) {
        self.recursive = recursive
        self.includeFiles = includeFiles
        self.includeDirectories = includeDirectories
        self.includeSymbolicLinks = includeSymbolicLinks
        self.includeHiddenFiles = includeHiddenFiles
        self.skipPackages = skipPackages
        self.skipCloudPlaceholders = skipCloudPlaceholders
        self.collectItems = collectItems
        self.batchSize = max(1, batchSize)
        self.exclusionURLs = exclusionURLs
        self.excludedNames = excludedNames
        self.excludedExtensions = excludedExtensions
        self.modifiedBefore = modifiedBefore
    }
}

struct FileSystemScanBatch: Sendable {
    let items: [FileItem]
    let currentURL: URL
    let entriesAnalyzed: Int
    let filesAnalyzed: Int
    let bytesAnalyzed: Int64
}

struct FileSystemScanResult: Sendable {
    let root: URL
    let items: [FileItem]
    let issues: [ScanIssue]
    let excludedURLs: [URL]
    let entriesAnalyzed: Int
    let fileCount: Int
    let directoryCount: Int
    let symbolicLinkCount: Int
    let byteCount: Int64
}

enum FileSystemScannerError: Error, LocalizedError, Sendable {
    case rootDoesNotExist(String)
    case rootIsNotDirectory(String)
    case cannotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case let .rootDoesNotExist(path):
            "The scan location no longer exists: \(path)"
        case let .rootIsNotDirectory(path):
            "The scan location is not a directory: \(path)"
        case let .cannotEnumerate(path):
            "The scan location cannot be enumerated: \(path)"
        }
    }
}

struct FileSystemScanner: Sendable {
    func scan(
        root requestedRoot: URL,
        options: FileSystemScanOptions = FileSystemScanOptions(),
        onBatch: FileSystemScanBatchHandler? = nil
    ) async throws -> FileSystemScanResult {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()

            let manager = FileManager()
            let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                throw FileSystemScannerError.rootDoesNotExist(root.path)
            }
            guard isDirectory.boolValue else {
                throw FileSystemScannerError.rootIsNotDirectory(root.path)
            }

            let exclusions = options.exclusionURLs.map {
                $0.standardizedFileURL.resolvingSymlinksInPath()
            }
            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .fileSizeKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .contentAccessDateKey
            ]

            var enumerationOptions: FileManager.DirectoryEnumerationOptions = []
            if !options.recursive {
                enumerationOptions.insert(.skipsSubdirectoryDescendants)
            }
            if !options.includeHiddenFiles {
                enumerationOptions.insert(.skipsHiddenFiles)
            }
            if options.skipPackages {
                enumerationOptions.insert(.skipsPackageDescendants)
            }

            var issues: [ScanIssue] = []
            var excludedURLs: [URL] = []
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: enumerationOptions,
                errorHandler: { url, error in
                    issues.append(Self.issue(for: error, at: url))
                    return true
                }
            ) else {
                throw FileSystemScannerError.cannotEnumerate(root.path)
            }

            var collected: [FileItem] = []
            var batch: [FileItem] = []
            batch.reserveCapacity(options.batchSize)
            var entriesAnalyzed = 0
            var filesAnalyzed = 0
            var directoryCount = 0
            var symbolicLinkCount = 0
            var byteCount: Int64 = 0
            var lastURL = root

            while let candidate = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                lastURL = candidate

                let standardized = candidate.standardizedFileURL
                let resolved = standardized.resolvingSymlinksInPath()
                let name = standardized.lastPathComponent
                let pathExtension = standardized.pathExtension.lowercased()

                if options.excludedNames.contains(name)
                    || options.excludedNames.contains(name.lowercased())
                    || options.excludedExtensions.contains(pathExtension)
                    || (options.skipCloudPlaceholders && pathExtension == "icloud")
                    || exclusions.contains(where: {
                        Self.isSameOrDescendant(standardized, of: $0)
                            || Self.isSameOrDescendant(resolved, of: $0)
                    }) {
                    excludedURLs.append(standardized)
                    enumerator.skipDescendants()
                    continue
                }

                let values: URLResourceValues
                do {
                    values = try standardized.resourceValues(forKeys: resourceKeys)
                } catch {
                    issues.append(Self.issue(for: error, at: standardized))
                    continue
                }

                let kind: FileItemKind
                if values.isSymbolicLink == true {
                    kind = .symbolicLink
                } else if values.isDirectory == true {
                    kind = .directory
                } else if values.isRegularFile == true {
                    kind = .file
                } else {
                    kind = .other
                }

                if kind == .symbolicLink {
                    enumerator.skipDescendants()
                }

                if let cutoff = options.modifiedBefore,
                   kind != .directory,
                   let modified = values.contentModificationDate,
                   modified >= cutoff {
                    continue
                }

                let shouldInclude: Bool
                switch kind {
                case .file, .other:
                    shouldInclude = options.includeFiles
                case .directory:
                    shouldInclude = options.includeDirectories
                case .symbolicLink:
                    shouldInclude = options.includeSymbolicLinks
                }
                guard shouldInclude else { continue }

                entriesAnalyzed += 1
                switch kind {
                case .file, .other:
                    filesAnalyzed += 1
                case .directory:
                    directoryCount += 1
                case .symbolicLink:
                    symbolicLinkCount += 1
                }

                let byteSize: Int64
                if kind == .file || kind == .other {
                    byteSize = Int64(
                        values.totalFileAllocatedSize
                            ?? values.fileAllocatedSize
                            ?? values.fileSize
                            ?? 0
                    )
                } else {
                    byteSize = 0
                }
                byteCount += max(0, byteSize)

                let item = FileItem(
                    url: standardized,
                    size: byteSize,
                    kind: kind,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate,
                    accessedAt: values.contentAccessDate,
                    isHidden: values.isHidden ?? name.hasPrefix(".")
                )

                if options.collectItems {
                    collected.append(item)
                }
                batch.append(item)

                if batch.count >= options.batchSize {
                    if let onBatch {
                        await onBatch(FileSystemScanBatch(
                            items: batch,
                            currentURL: standardized,
                            entriesAnalyzed: entriesAnalyzed,
                            filesAnalyzed: filesAnalyzed,
                            bytesAnalyzed: byteCount
                        ))
                    }
                    batch.removeAll(keepingCapacity: true)
                }
            }

            if !batch.isEmpty, let onBatch {
                await onBatch(FileSystemScanBatch(
                    items: batch,
                    currentURL: lastURL,
                    entriesAnalyzed: entriesAnalyzed,
                    filesAnalyzed: filesAnalyzed,
                    bytesAnalyzed: byteCount
                ))
            }

            return FileSystemScanResult(
                root: root,
                items: collected,
                issues: issues,
                excludedURLs: excludedURLs,
                entriesAnalyzed: entriesAnalyzed,
                fileCount: filesAnalyzed,
                directoryCount: directoryCount,
                symbolicLinkCount: symbolicLinkCount,
                byteCount: byteCount
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func issue(for error: Error, at url: URL) -> ScanIssue {
        let cocoaError = error as? CocoaError
        let kind: ScanIssue.Kind

        switch cocoaError?.code {
        case .fileReadNoPermission, .fileWriteNoPermission:
            kind = .permissionDenied
        case .fileNoSuchFile:
            kind = .disappeared
        case .fileReadUnknown, .fileReadCorruptFile, .fileReadInapplicableStringEncoding:
            kind = .inputOutput
        case .none:
            kind = .unknown
        default:
            kind = .inaccessible
        }

        return ScanIssue(kind: kind, path: url.path, message: error.localizedDescription)
    }
}
