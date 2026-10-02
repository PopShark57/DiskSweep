import Foundation

struct LargeFolderScanResult: Sendable {
    let root: DirectoryNode
    let issues: [ScanIssue]
    let filesAnalyzed: Int
    let bytesAnalyzed: Int64

    func largestFolders(limit: Int = 100) -> [DirectoryNode] {
        guard limit > 0 else { return [] }
        var pending = root.children
        var folders: [DirectoryNode] = []

        while let node = pending.popLast() {
            folders.append(node)
            pending.append(contentsOf: node.children)
        }

        return Array(
            folders.sorted {
                if $0.size == $1.size {
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                return $0.size > $1.size
            }.prefix(limit)
        )
    }
}

struct LargeFolderAnalyzer: Sendable {
    private let progressBatchSize: Int

    init(progressBatchSize: Int = 128) {
        self.progressBatchSize = max(1, progressBatchSize)
    }

    func scan(
        root: URL? = nil,
        minimumRetainedFolderSize: Int64 = 0,
        context: ScanContext,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> LargeFolderScanResult {
        let scanRoot = (root ?? context.homeDirectory).standardizedFileURL
        let minimumSize = max(0, minimumRetainedFolderSize)
        let batchSize = progressBatchSize
        let worker = Task.detached(priority: .utility) {
            var state = FolderBuildState()
            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .preparing,
                    location: nil,
                    path: scanRoot.path,
                    filesAnalyzed: 0,
                    bytesFound: 0
                )
            )

            let node = try await Self.buildDirectory(
                scanRoot,
                isRoot: true,
                minimumRetainedFolderSize: minimumSize,
                context: context,
                progressBatchSize: batchSize,
                state: &state,
                progress: progress
            ) ?? DirectoryNode(
                url: scanRoot,
                name: scanRoot.lastPathComponent,
                size: 0,
                fileCount: 0
            )

            try Task.checkCancellation()
            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .completed,
                    location: nil,
                    path: scanRoot.path,
                    filesAnalyzed: state.filesAnalyzed,
                    bytesFound: state.bytesAnalyzed
                )
            )

            return LargeFolderScanResult(
                root: node,
                issues: state.issues,
                filesAnalyzed: state.filesAnalyzed,
                bytesAnalyzed: state.bytesAnalyzed
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func buildDirectory(
        _ directory: URL,
        isRoot: Bool,
        minimumRetainedFolderSize: Int64,
        context: ScanContext,
        progressBatchSize: Int,
        state: inout FolderBuildState,
        progress: @escaping ScanProgressHandler
    ) async throws -> DirectoryNode? {
        try Task.checkCancellation()

        guard let metadata = AnalyzerFileSystem.metadata(
            for: directory,
            issueSink: &state.issues
        ) else {
            return nil
        }

        guard metadata.isDirectory, !metadata.isSymbolicLink else {
            return nil
        }

        if AnalyzerFileSystem.shouldExclude(
            directory,
            metadata: metadata,
            context: context,
            purpose: .largeFolders,
            isRoot: isRoot
        ) {
            return nil
        }

        let options: FileManager.DirectoryEnumerationOptions = context.showHiddenFiles
            ? []
            : [.skipsHiddenFiles]
        let children: [URL]

        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(AnalyzerFileSystem.resourceKeys),
                options: options
            )
        } catch {
            state.issues.append(AnalyzerFileSystem.issue(for: error, at: directory))
            return DirectoryNode(
                url: directory,
                size: 0,
                fileCount: 0
            )
        }

        var size: Int64 = 0
        var fileCount = 0
        var directoryChildren: [DirectoryNode] = []

        for child in children {
            try Task.checkCancellation()
            guard let childMetadata = AnalyzerFileSystem.metadata(
                for: child,
                issueSink: &state.issues
            ) else {
                continue
            }

            if AnalyzerFileSystem.shouldExclude(
                child,
                metadata: childMetadata,
                context: context,
                purpose: .largeFolders,
                isRoot: false
            ) || childMetadata.isSymbolicLink {
                continue
            }

            if childMetadata.isDirectory {
                if let childNode = try await buildDirectory(
                    child,
                    isRoot: false,
                    minimumRetainedFolderSize: minimumRetainedFolderSize,
                    context: context,
                    progressBatchSize: progressBatchSize,
                    state: &state,
                    progress: progress
                ) {
                    size = AnalyzerFileSystem.addingClamped(size, childNode.size)
                    fileCount += childNode.fileCount
                    if childNode.size >= minimumRetainedFolderSize {
                        directoryChildren.append(childNode)
                    }
                }
                continue
            }

            guard childMetadata.isRegularFile else { continue }
            size = AnalyzerFileSystem.addingClamped(size, childMetadata.size)
            fileCount += 1
            state.filesAnalyzed += 1
            state.bytesAnalyzed = AnalyzerFileSystem.addingClamped(
                state.bytesAnalyzed,
                childMetadata.size
            )

            if state.filesAnalyzed.isMultiple(of: progressBatchSize) {
                await progress(
                    AnalyzerFileSystem.progressValue(
                        phase: .enumerating,
                        location: nil,
                        path: child.path,
                        filesAnalyzed: state.filesAnalyzed,
                        bytesFound: state.bytesAnalyzed
                    )
                )
            }
        }

        directoryChildren.sort {
            if $0.size == $1.size {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.size > $1.size
        }

        return DirectoryNode(
            url: directory,
            name: isRoot && directory.lastPathComponent.isEmpty
                ? directory.path
                : nil,
            size: size,
            fileCount: fileCount,
            children: directoryChildren
        )
    }
}

/// A semantic wrapper for the Disk Usage sidebar. It always anchors the tree
/// at `ScanContext.homeDirectory` while sharing the same cancellable traversal.
struct DiskUsageAnalyzer: Sendable {
    private let folderAnalyzer: LargeFolderAnalyzer

    init(progressBatchSize: Int = 128) {
        folderAnalyzer = LargeFolderAnalyzer(progressBatchSize: progressBatchSize)
    }

    func scanHomeDirectory(
        context: ScanContext,
        minimumRetainedFolderSize: Int64 = 0,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> LargeFolderScanResult {
        try await folderAnalyzer.scan(
            root: context.homeDirectory,
            minimumRetainedFolderSize: minimumRetainedFolderSize,
            context: context,
            progress: progress
        )
    }
}

private struct FolderBuildState: Sendable {
    var issues: [ScanIssue] = []
    var filesAnalyzed = 0
    var bytesAnalyzed: Int64 = 0
}
