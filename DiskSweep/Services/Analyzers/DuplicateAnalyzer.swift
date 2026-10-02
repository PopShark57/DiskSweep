import CryptoKit
import Darwin
import Foundation

struct DuplicateScanDiagnostics: Codable, Hashable, Sendable {
    var sizeCandidateFiles = 0
    var sampledFiles = 0
    var cryptographicallyHashedFiles = 0
    var byteForByteComparisons = 0
    var hardLinkAliasesIgnored = 0
}

struct DuplicateScanResult: Sendable {
    let roots: [URL]
    let groups: [DuplicateGroup]
    let issues: [ScanIssue]
    let filesAnalyzed: Int
    let diagnostics: DuplicateScanDiagnostics

    var reclaimableSize: Int64 {
        groups.reduce(0) {
            AnalyzerFileSystem.addingClamped($0, $1.reclaimableSize)
        }
    }
}

enum DuplicateSelection {
    /// User files are never preselected merely because a scan found them.
    static func defaultSelectedFileIDs(in group: DuplicateGroup) -> Set<FileItem.ID> {
        []
    }

    /// An opt-in convenience for review screens. The deterministically chosen
    /// keeper is never included, so this cannot select every copy.
    static func suggestedSelectedFileIDs(in group: DuplicateGroup) -> Set<FileItem.ID> {
        guard group.files.count > 1 else { return [] }
        let keeper = preferredKeeper(in: group)
        return Set(group.files.lazy.filter { $0.id != keeper?.id }.map(\.id))
    }

    /// Intersects a requested selection with the group and removes a keeper if
    /// the caller attempted to select every copy.
    static func preservingOneCopy(
        _ requested: Set<FileItem.ID>,
        in group: DuplicateGroup
    ) -> Set<FileItem.ID> {
        let validIDs = Set(group.files.map(\.id))
        var selection = requested.intersection(validIDs)
        guard !group.files.isEmpty, selection.count == group.files.count else {
            return selection
        }

        if let keeper = preferredKeeper(in: group) {
            selection.remove(keeper.id)
        }
        return selection
    }

    private static func preferredKeeper(in group: DuplicateGroup) -> FileItem? {
        group.files.min {
            let lhsDepth = $0.url.standardizedFileURL.pathComponents.count
            let rhsDepth = $1.url.standardizedFileURL.pathComponents.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}

struct DuplicateAnalyzer: Sendable {
    private let sampleByteCount: Int
    private let readChunkByteCount: Int
    private let progressBatchSize: Int

    init(
        sampleByteCount: Int = 64 * 1_024,
        readChunkByteCount: Int = 1_024 * 1_024,
        progressBatchSize: Int = 32
    ) {
        self.sampleByteCount = max(1, sampleByteCount)
        self.readChunkByteCount = max(1, readChunkByteCount)
        self.progressBatchSize = max(1, progressBatchSize)
    }

    func scan(
        root: URL,
        minimumFileSize: Int64 = 1,
        context: ScanContext,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> DuplicateScanResult {
        try await scan(
            roots: [root],
            minimumFileSize: minimumFileSize,
            context: context,
            progress: progress
        )
    }

    func scan(
        roots: [URL]? = nil,
        minimumFileSize: Int64 = 1,
        context: ScanContext,
        progress: @escaping ScanProgressHandler = { _ in }
    ) async throws -> DuplicateScanResult {
        let scanRoots = (roots ?? [context.homeDirectory]).map(\.standardizedFileURL)
        let effectiveMinimumSize = max(1, minimumFileSize)
        let sampleSize = sampleByteCount
        let chunkSize = readChunkByteCount
        let batchSize = progressBatchSize
        let worker = Task.detached(priority: .utility) {
            let enumeration = try await AnalyzerFileSystem.enumerateFiles(
                roots: scanRoots,
                minimumSize: effectiveMinimumSize,
                context: context,
                purpose: .duplicates,
                progressLocation: nil,
                progressBatchSize: max(64, batchSize),
                emitFinalizingProgress: false,
                progress: progress
            )

            try Task.checkCancellation()
            var issues = enumeration.issues
            var diagnostics = DuplicateScanDiagnostics()
            let filesBySize = Dictionary(grouping: enumeration.files, by: \.size)
            var duplicateGroups: [DuplicateGroup] = []
            var hashingProgress = 0

            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .hashing,
                    location: nil,
                    path: scanRoots.first?.path ?? "",
                    filesAnalyzed: enumeration.filesAnalyzed,
                    bytesFound: 0
                )
            )

            for (fileSize, sameSizeFiles) in filesBySize.sorted(by: { $0.key > $1.key }) {
                try Task.checkCancellation()
                guard sameSizeFiles.count > 1 else { continue }

                let uniqueFiles = Self.removingHardLinkAliases(
                    from: sameSizeFiles,
                    diagnostics: &diagnostics
                )
                guard uniqueFiles.count > 1 else { continue }
                diagnostics.sizeCandidateFiles += uniqueFiles.count

                var sampledGroups: [PartialSampleSignature: [FileItem]] = [:]
                for file in uniqueFiles {
                    try Task.checkCancellation()
                    do {
                        let signature = try Self.partialSampleSignature(
                            for: file.url,
                            fileSize: fileSize,
                            sampleByteCount: sampleSize
                        )
                        sampledGroups[signature, default: []].append(file)
                        diagnostics.sampledFiles += 1
                    } catch {
                        try Self.rethrowIfCancelled(error)
                        issues.append(AnalyzerFileSystem.issue(for: error, at: file.url))
                    }
                }

                for sampleMatches in sampledGroups.values where sampleMatches.count > 1 {
                    try Task.checkCancellation()
                    var cryptographicGroups: [String: [FileItem]] = [:]

                    for file in sampleMatches {
                        try Task.checkCancellation()
                        do {
                            let fingerprint = try Self.sha256(
                                for: file.url,
                                chunkByteCount: chunkSize
                            )
                            cryptographicGroups[fingerprint, default: []].append(file)
                            diagnostics.cryptographicallyHashedFiles += 1
                            hashingProgress += 1

                            if hashingProgress.isMultiple(of: batchSize) {
                                await progress(
                                    AnalyzerFileSystem.progressValue(
                                        phase: .hashing,
                                        location: nil,
                                        path: file.url.path,
                                        filesAnalyzed: enumeration.filesAnalyzed,
                                        bytesFound: duplicateGroups.reduce(0) {
                                            AnalyzerFileSystem.addingClamped(
                                                $0,
                                                $1.reclaimableSize
                                            )
                                        }
                                    )
                                )
                            }
                        } catch {
                            try Self.rethrowIfCancelled(error)
                            issues.append(AnalyzerFileSystem.issue(for: error, at: file.url))
                        }
                    }

                    for (fingerprint, hashMatches) in cryptographicGroups
                        where hashMatches.count > 1 {
                        let confirmedClusters = try Self.confirmedClusters(
                            hashMatches,
                            chunkByteCount: chunkSize,
                            diagnostics: &diagnostics,
                            issues: &issues
                        )

                        for cluster in confirmedClusters where cluster.count > 1 {
                            let sortedFiles = cluster.sorted {
                                $0.url.path.localizedStandardCompare($1.url.path)
                                    == .orderedAscending
                            }
                            duplicateGroups.append(
                                DuplicateGroup(
                                    fingerprint: fingerprint,
                                    fileSize: fileSize,
                                    files: sortedFiles
                                )
                            )
                        }
                    }
                }
            }

            try Task.checkCancellation()
            duplicateGroups.sort {
                if $0.reclaimableSize == $1.reclaimableSize {
                    return ($0.files.first?.url.path ?? "")
                        .localizedStandardCompare($1.files.first?.url.path ?? "")
                        == .orderedAscending
                }
                return $0.reclaimableSize > $1.reclaimableSize
            }

            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .finalizing,
                    location: nil,
                    path: scanRoots.first?.path ?? "",
                    filesAnalyzed: enumeration.filesAnalyzed,
                    bytesFound: duplicateGroups.reduce(0) {
                        AnalyzerFileSystem.addingClamped($0, $1.reclaimableSize)
                    }
                )
            )

            let result = DuplicateScanResult(
                roots: scanRoots,
                groups: duplicateGroups,
                issues: issues,
                filesAnalyzed: enumeration.filesAnalyzed,
                diagnostics: diagnostics
            )

            await progress(
                AnalyzerFileSystem.progressValue(
                    phase: .completed,
                    location: nil,
                    path: scanRoots.first?.path ?? "",
                    filesAnalyzed: enumeration.filesAnalyzed,
                    bytesFound: result.reclaimableSize
                )
            )
            return result
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func defaultSelection(in group: DuplicateGroup) -> Set<FileItem.ID> {
        DuplicateSelection.defaultSelectedFileIDs(in: group)
    }

    func suggestedSelection(in group: DuplicateGroup) -> Set<FileItem.ID> {
        DuplicateSelection.suggestedSelectedFileIDs(in: group)
    }

    func selectionPreservingOneCopy(
        _ requested: Set<FileItem.ID>,
        in group: DuplicateGroup
    ) -> Set<FileItem.ID> {
        DuplicateSelection.preservingOneCopy(requested, in: group)
    }

    private static func removingHardLinkAliases(
        from files: [FileItem],
        diagnostics: inout DuplicateScanDiagnostics
    ) -> [FileItem] {
        let identities = files.map { file in
            (file: file, identity: physicalIdentity(for: file.url))
        }
        let identityCounts = Dictionary(
            grouping: identities.compactMap(\.identity),
            by: { $0 }
        ).mapValues(\.count)

        return identities.compactMap { entry in
            guard let identity = entry.identity else { return entry.file }
            if identityCounts[identity, default: 0] > 1 {
                diagnostics.hardLinkAliasesIgnored += 1
                return nil
            }
            return entry.file
        }
    }

    private static func physicalIdentity(for url: URL) -> PhysicalFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return PhysicalFileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func partialSampleSignature(
        for url: URL,
        fileSize: Int64,
        sampleByteCount: Int
    ) throws -> PartialSampleSignature {
        try Task.checkCancellation()
        let handle = try noFollowFileHandle(for: url)
        defer { try? handle.close() }

        let maximumOffset = max(0, fileSize - Int64(sampleByteCount))
        let middleOffset = max(0, min(maximumOffset, fileSize / 2 - Int64(sampleByteCount / 2)))
        let offsets = Array(Set<Int64>([0, middleOffset, maximumOffset])).sorted()
        var samples: [UInt64] = []

        for offset in offsets {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let remaining = max(0, fileSize - offset)
            let readCount = min(sampleByteCount, Int(clamping: remaining))
            let data = try handle.read(upToCount: readCount) ?? Data()
            samples.append(fnv1a64(data, seed: UInt64(bitPattern: offset)))
        }

        return PartialSampleSignature(samples: samples)
    }

    private static func sha256(for url: URL, chunkByteCount: Int) throws -> String {
        try Task.checkCancellation()
        let handle = try noFollowFileHandle(for: url)
        defer { try? handle.close() }
        var hasher = SHA256()

        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: chunkByteCount), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func confirmedClusters(
        _ files: [FileItem],
        chunkByteCount: Int,
        diagnostics: inout DuplicateScanDiagnostics,
        issues: inout [ScanIssue]
    ) throws -> [[FileItem]] {
        var clusters: [[FileItem]] = []

        fileLoop: for file in files {
            try Task.checkCancellation()

            for index in clusters.indices {
                do {
                    diagnostics.byteForByteComparisons += 1
                    if try filesAreIdentical(
                        file.url,
                        clusters[index][0].url,
                        chunkByteCount: chunkByteCount
                    ) {
                        clusters[index].append(file)
                        continue fileLoop
                    }
                } catch {
                    try rethrowIfCancelled(error)
                    issues.append(AnalyzerFileSystem.issue(for: error, at: file.url))
                    continue fileLoop
                }
            }

            clusters.append([file])
        }

        return clusters
    }

    private static func filesAreIdentical(
        _ lhsURL: URL,
        _ rhsURL: URL,
        chunkByteCount: Int
    ) throws -> Bool {
        let lhs = try noFollowFileHandle(for: lhsURL)
        defer { try? lhs.close() }
        let rhs = try noFollowFileHandle(for: rhsURL)
        defer { try? rhs.close() }

        while true {
            try Task.checkCancellation()
            let lhsData = try lhs.read(upToCount: chunkByteCount) ?? Data()
            let rhsData = try rhs.read(upToCount: chunkByteCount) ?? Data()
            if lhsData != rhsData { return false }
            if lhsData.isEmpty { return true }
        }
    }

    private static func noFollowFileHandle(for url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fnv1a64(_ data: Data, seed: UInt64) -> UInt64 {
        var hash = 14_695_981_039_346_656_037 ^ seed
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= UInt64(data.count)
        return hash
    }

    private static func rethrowIfCancelled(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
    }
}

private struct PartialSampleSignature: Hashable, Sendable {
    let samples: [UInt64]
}

private struct PhysicalFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}
