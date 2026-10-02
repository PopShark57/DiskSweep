import Foundation

enum DiskServiceError: Error, LocalizedError, Sendable {
    case volumeUnavailable(String)
    case invalidCapacity(String)

    var errorDescription: String? {
        switch self {
        case let .volumeUnavailable(path):
            "Disk statistics are unavailable for \(path)."
        case let .invalidCapacity(path):
            "The volume at \(path) reported an invalid capacity."
        }
    }
}

struct DiskService: Sendable {
    func statistics(
        for requestedURL: URL = URL(fileURLWithPath: "/", isDirectory: true),
        reclaimable: Int64 = 0
    ) async throws -> DiskStatistics {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()

            let url = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
            let keys: Set<URLResourceKey> = [
                .volumeNameKey,
                .volumeURLKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ]

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw DiskServiceError.volumeUnavailable(url.path)
            }

            let mountURL = (values.volume ?? url)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var capacity = values.volumeTotalCapacity.map(Int64.init) ?? 0
            var available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init)
                ?? 0

            if capacity <= 0 || available < 0 {
                let attributes = try? FileManager.default.attributesOfFileSystem(
                    forPath: mountURL.path
                )
                capacity = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? capacity
                available = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? available
            }

            guard capacity > 0 else {
                throw DiskServiceError.invalidCapacity(mountURL.path)
            }

            available = min(capacity, max(0, available))
            let used = max(0, capacity - available)
            let fallbackName = mountURL.path == "/"
                ? "Macintosh HD"
                : mountURL.lastPathComponent

            return DiskStatistics(
                volumeName: values.volumeName?.isEmpty == false
                    ? values.volumeName!
                    : fallbackName,
                mountURL: mountURL,
                capacity: capacity,
                used: used,
                available: available,
                reclaimable: max(0, reclaimable)
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
