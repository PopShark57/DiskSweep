import Foundation

typealias DirectorySizeProgressHandler = @Sendable (DirectorySizeProgress) async -> Void

struct DirectorySizeProgress: Sendable {
    let currentURL: URL
    let entriesAnalyzed: Int
    let filesAnalyzed: Int
    let bytesFound: Int64
}

struct DirectorySizeResult: Sendable {
    let url: URL
    let byteCount: Int64
    let fileCount: Int
    let directoryCount: Int
    let issues: [ScanIssue]
    let excludedURLs: [URL]
}

struct DirectorySizer: Sendable {
    private let scanner = FileSystemScanner()

    func size(
        of url: URL,
        exclusions: [URL] = [],
        includeHiddenFiles: Bool = false,
        skipPackages: Bool = true,
        batchSize: Int = 256,
        onProgress: DirectorySizeProgressHandler? = nil
    ) async throws -> DirectorySizeResult {
        let options = FileSystemScanOptions(
            recursive: true,
            includeFiles: true,
            includeDirectories: true,
            includeSymbolicLinks: false,
            includeHiddenFiles: includeHiddenFiles,
            skipPackages: skipPackages,
            skipCloudPlaceholders: true,
            collectItems: false,
            batchSize: batchSize,
            exclusionURLs: exclusions
        )

        let result = try await scanner.scan(root: url, options: options) { batch in
            guard let onProgress else { return }
            await onProgress(DirectorySizeProgress(
                currentURL: batch.currentURL,
                entriesAnalyzed: batch.entriesAnalyzed,
                filesAnalyzed: batch.filesAnalyzed,
                bytesFound: batch.bytesAnalyzed
            ))
        }

        return DirectorySizeResult(
            url: result.root,
            byteCount: result.byteCount,
            fileCount: result.fileCount,
            directoryCount: result.directoryCount,
            issues: result.issues,
            excludedURLs: result.excludedURLs
        )
    }
}
