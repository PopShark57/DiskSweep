import Foundation

struct LargeFileScanResult: Sendable {
    let root: URL
    let threshold: Int64
    let files: [FileItem]
    let issues: [ScanIssue]
    let filesAnalyzed: Int
    let bytesAnalyzed: Int64

    var matchedBytes: Int64 {
        files.reduce(0) { AnalyzerFileSystem.addingClamped($0, $1.size) }
    }
}

struct LargeFileAnalyzer: Sendable {
    static let defaultThreshold: Int64 = 100 * 1_024 * 1_024

    private let progressBatchSize: Int

    init(progressBatchSize: Int = 128) {
        self.progressBatchSize = max(1, progressBatchSize)
    }

    func scan(
        root: URL? = nil,
        threshold: Int64 = LargeFileAnalyzer.defaultThreshold,
        context: ScanContext,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> LargeFileScanResult {
        let scanRoot = (root ?? context.homeDirectory).standardizedFileURL
        let effectiveThreshold = max(0, threshold)
        let batchSize = progressBatchSize
        let worker = Task.detached(priority: .utility) {
            let enumeration = try await AnalyzerFileSystem.enumerateFiles(
                roots: [scanRoot],
                minimumSize: effectiveThreshold,
                context: context,
                purpose: .largeFiles,
                progressLocation: nil,
                progressBatchSize: batchSize,
                progress: progress
            )

            try Task.checkCancellation()
            let files = enumeration.files.sorted {
                if $0.size == $1.size {
                    return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
                return $0.size > $1.size
            }

            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .completed,
                    location: nil,
                    path: scanRoot.path,
                    filesAnalyzed: enumeration.filesAnalyzed,
                    bytesFound: files.reduce(0) {
                        AnalyzerFileSystem.addingClamped($0, $1.size)
                    }
                )
            )

            return LargeFileScanResult(
                root: scanRoot,
                threshold: effectiveThreshold,
                files: files,
                issues: enumeration.issues,
                filesAnalyzed: enumeration.filesAnalyzed,
                bytesAnalyzed: enumeration.bytesAnalyzed
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
