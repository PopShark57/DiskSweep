import Foundation

enum DownloadsCategory: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case diskImages
    case archives
    case installers
    case videos
    case images
    case documents
    case other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .diskImages: "Disk Images"
        case .archives: "ZIP / Archives"
        case .installers: "Installers"
        case .videos: "Videos"
        case .images: "Images"
        case .documents: "Documents"
        case .other: "Other"
        }
    }

    static func classify(_ file: FileItem) -> DownloadsCategory {
        let fileExtension = file.url.pathExtension.lowercased()

        if diskImageExtensions.contains(fileExtension) { return .diskImages }
        if archiveExtensions.contains(fileExtension) { return .archives }
        if installerExtensions.contains(fileExtension) { return .installers }
        if videoExtensions.contains(fileExtension) { return .videos }
        if imageExtensions.contains(fileExtension) { return .images }
        if documentExtensions.contains(fileExtension) { return .documents }
        return .other
    }

    private static let diskImageExtensions: Set<String> = [
        "dmg", "iso", "img", "sparseimage", "sparsebundle"
    ]
    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "cab", "gz", "lha", "rar", "tar", "tbz", "tbz2",
        "tgz", "txz", "xz", "zip", "zst"
    ]
    private static let installerExtensions: Set<String> = [
        "installer", "mpkg", "pkg"
    ]
    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg",
        "mts", "webm", "wmv"
    ]
    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "dng", "gif", "heic", "heif", "jpeg", "jpg", "png",
        "raw", "svg", "tif", "tiff", "webp"
    ]
    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "epub", "key", "md", "numbers", "odt", "pages",
        "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx"
    ]
}

struct DownloadsFilter: Codable, Hashable, Sendable {
    var olderThan: TimeInterval?
    var largerThan: Int64?

    init(olderThan: TimeInterval? = nil, largerThan: Int64? = nil) {
        self.olderThan = olderThan.map { max(0, $0) }
        self.largerThan = largerThan.map { max(0, $0) }
    }

    static let all = DownloadsFilter()
    static let olderThan30Days = DownloadsFilter(olderThan: 30 * 24 * 60 * 60)
    static let olderThan90Days = DownloadsFilter(olderThan: 90 * 24 * 60 * 60)
    static let olderThanOneYear = DownloadsFilter(olderThan: 365 * 24 * 60 * 60)
    static let largerThan100MB = DownloadsFilter(largerThan: 100 * 1_024 * 1_024)
    static let largerThan1GB = DownloadsFilter(largerThan: 1_024 * 1_024 * 1_024)

    func matches(_ file: FileItem, relativeTo referenceDate: Date) -> Bool {
        if let olderThan {
            guard let date = file.modifiedAt ?? file.createdAt,
                  referenceDate.timeIntervalSince(date) > olderThan else {
                return false
            }
        }

        if let largerThan, file.size <= largerThan {
            return false
        }

        return true
    }
}

struct DownloadsGroup: Identifiable, Sendable {
    var id: DownloadsCategory { category }
    let category: DownloadsCategory
    let files: [FileItem]

    var totalSize: Int64 {
        files.reduce(0) { AnalyzerFileSystem.addingClamped($0, $1.size) }
    }
}

struct DownloadsAnalysis: Sendable {
    let root: URL
    let allFiles: [FileItem]
    let groups: [DownloadsGroup]
    let filter: DownloadsFilter
    let issues: [ScanIssue]
    let scannedAt: Date

    var filteredFiles: [FileItem] {
        groups.flatMap(\.files)
    }

    var totalSize: Int64 {
        groups.reduce(0) { AnalyzerFileSystem.addingClamped($0, $1.totalSize) }
    }

    /// Downloads are user-created content and therefore never preselected.
    var defaultSelectedFileIDs: Set<FileItem.ID> { [] }

    subscript(category: DownloadsCategory) -> DownloadsGroup? {
        groups.first { $0.category == category }
    }

    func applying(_ newFilter: DownloadsFilter) -> DownloadsAnalysis {
        DownloadsAnalysis.make(
            root: root,
            files: allFiles,
            filter: newFilter,
            issues: issues,
            scannedAt: scannedAt
        )
    }

    fileprivate static func make(
        root: URL,
        files: [FileItem],
        filter: DownloadsFilter,
        issues: [ScanIssue],
        scannedAt: Date
    ) -> DownloadsAnalysis {
        let matchingFiles = files.filter { filter.matches($0, relativeTo: scannedAt) }
        let grouped = Dictionary(grouping: matchingFiles, by: DownloadsCategory.classify)
        let groups = DownloadsCategory.allCases.map { category in
            DownloadsGroup(
                category: category,
                files: (grouped[category] ?? []).sorted {
                    if $0.size == $1.size {
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    return $0.size > $1.size
                }
            )
        }

        return DownloadsAnalysis(
            root: root,
            allFiles: files,
            groups: groups,
            filter: filter,
            issues: issues,
            scannedAt: scannedAt
        )
    }
}

struct DownloadsAnalyzer: Sendable {
    private let progressBatchSize: Int

    init(progressBatchSize: Int = 128) {
        self.progressBatchSize = max(1, progressBatchSize)
    }

    func scan(
        context: ScanContext,
        filter: DownloadsFilter = .all,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> DownloadsAnalysis {
        try await scan(
            root: context.homeDirectory.appendingPathComponent("Downloads", isDirectory: true),
            context: context,
            filter: filter,
            progress: progress
        )
    }

    func scan(
        root: URL,
        context: ScanContext,
        filter: DownloadsFilter = .all,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> DownloadsAnalysis {
        let scanRoot = root.standardizedFileURL
        CleanupSnapshotRegistry.shared.replace(
            providerID: DownloadsProvider.analysisSnapshotProviderID,
            snapshots: [:]
        )
        let batchSize = progressBatchSize
        let worker = Task.detached(priority: .utility) {
            let enumeration = try await AnalyzerFileSystem.enumerateFiles(
                roots: [scanRoot],
                minimumSize: 0,
                context: context,
                purpose: .downloads,
                progressLocation: .downloads,
                progressBatchSize: batchSize,
                progress: progress
            )

            try Task.checkCancellation()
            let allFiles = enumeration.files.sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
            let analysis = DownloadsAnalysis.make(
                root: scanRoot,
                files: allFiles,
                filter: filter,
                issues: enumeration.issues,
                scannedAt: context.now
            )

            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .completed,
                    location: .downloads,
                    path: scanRoot.path,
                    filesAnalyzed: enumeration.filesAnalyzed,
                    bytesFound: analysis.totalSize
                )
            )
            return analysis
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
