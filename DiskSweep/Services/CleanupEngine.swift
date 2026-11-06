import Foundation

struct CleanupAuthorization: Sendable {
    let providerID: String
    let location: CleanupLocation
    let allowedRoots: [URL]
    let requiresSnapshot: Bool

    init(
        providerID: String,
        location: CleanupLocation,
        allowedRoots: [URL],
        requiresSnapshot: Bool = false
    ) {
        self.providerID = providerID
        self.location = location
        self.allowedRoots = allowedRoots
        self.requiresSnapshot = requiresSnapshot
    }

    init(provider: any CleanupProvider) {
        self.init(
            providerID: provider.id,
            location: provider.location,
            allowedRoots: provider.allowedRoots,
            requiresSnapshot: true
        )
    }
}

/// The cleanup operation the view model depends on, so tests can observe exactly which items
/// a review would clean without touching the filesystem.
protocol CleanupPerforming: Sendable {
    func clean(
        _ items: [CleanupItem],
        providers: [any CleanupProvider],
        disposition: CleanupDisposition?,
        exclusions: [URL]
    ) async -> CleanupResult
}

actor CleanupEngine: CleanupPerforming {
    private let safetyValidator: SafetyValidator
    private let diskService: DiskService
    private let snapshots: CleanupSnapshotRegistry

    init(
        safetyValidator: SafetyValidator = SafetyValidator(),
        diskService: DiskService = DiskService(),
        snapshots: CleanupSnapshotRegistry = .shared
    ) {
        self.safetyValidator = safetyValidator
        self.diskService = diskService
        self.snapshots = snapshots
    }

    func clean(
        _ items: [CleanupItem],
        providers: [any CleanupProvider],
        disposition: CleanupDisposition? = nil,
        exclusions: [URL] = []
    ) async -> CleanupResult {
        await clean(
            items,
            authorizations: providers.map(CleanupAuthorization.init(provider:)),
            disposition: disposition,
            exclusions: exclusions
        )
    }

    func clean(
        _ items: [CleanupItem],
        authorizations: [CleanupAuthorization],
        disposition: CleanupDisposition? = nil,
        exclusions: [URL] = []
    ) async -> CleanupResult {
        let startedAt = Date()
        let before = await capacitySnapshot()
        let authorizationMap = Dictionary(
            authorizations.map { ($0.providerID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let validator = safetyValidator

        let orderedItems = deduplicated(items).sorted {
            $0.url.standardizedFileURL.pathComponents.count
                < $1.url.standardizedFileURL.pathComponents.count
        }
        var cleaned: [CleanedItemRecord] = []
        var failures: [CleanupFailure] = []
        var removedDirectories: [URL] = []

        for item in orderedItems {
            if Task.isCancelled {
                break
            }

            if removedDirectories.contains(where: {
                item.url.standardizedFileURL.isStrictDescendant(of: $0)
            }) {
                continue
            }

            guard item.isDeletable else {
                failures.append(Self.failure(for: item, reason: "This item is informational and is not marked as deletable."))
                continue
            }

            guard let authorization = authorizationMap[item.providerID] else {
                failures.append(Self.failure(for: item, reason: "The cleanup provider did not supply an allowlisted root."))
                continue
            }

            guard authorization.location == item.location else {
                failures.append(Self.failure(for: item, reason: "The item does not match its cleanup provider's category."))
                continue
            }

            let itemDisposition = Self.disposition(for: item, requested: disposition)
            let permittedNestedNames = item.location.permittedNestedNames
            let scanSnapshot = snapshots.snapshot(
                providerID: item.providerID,
                itemID: item.id
            )
            if authorization.requiresSnapshot, scanSnapshot == nil {
                failures.append(Self.failure(for: item, reason: "The scan-time file identity is unavailable. Rescan before cleaning this item."))
                continue
            }

            do {
                let deletionTask = Task.detached(priority: .utility) {
                    let firstValidation = try validator.validate(
                        item.url,
                        location: item.location,
                        allowedRoots: authorization.allowedRoots
                    )
                    guard Self.matchesScannedMetadata(
                        item,
                        identity: firstValidation.identity
                    ) else {
                        throw SafetyValidationError.targetChanged(item.url.path)
                    }
                    if let scanSnapshot,
                       !Self.identity(
                           firstValidation.identity,
                           matches: scanSnapshot.identity,
                           policy: item.location.identityMatching
                       ) {
                        throw SafetyValidationError.targetChanged(item.url.path)
                    }

                    try Task.checkCancellation()

                    // This second check is deliberately adjacent to the filesystem mutation.
                    var validated = try validator.revalidate(
                        firstValidation,
                        location: item.location,
                        allowedRoots: authorization.allowedRoots
                    )
                    try Log.signposter.withIntervalSignpost("Validate contents") {
                        try validator.validateDirectoryContents(
                            validated,
                            exclusionRoots: (scanSnapshot?.exclusionRoots ?? []) + exclusions,
                            permittedNestedNames: permittedNestedNames
                        )
                    }
                    try Self.requireStillQualifies(validated, location: item.location)
                    validated = try validator.revalidate(
                        validated,
                        location: item.location,
                        allowedRoots: authorization.allowedRoots
                    )
                    try Task.checkCancellation()

                    let manager = FileManager()
                    switch itemDisposition {
                    case .permanent:
                        try manager.removeItem(at: validated.deletionURL)
                    case .trash:
                        try manager.trashItem(
                            at: validated.deletionURL,
                            resultingItemURL: nil
                        )
                    }

                    return validated
                }
                let outcome = try await withTaskCancellationHandler {
                    try await deletionTask.value
                } onCancel: {
                    deletionTask.cancel()
                }

                cleaned.append(CleanedItemRecord(
                    name: item.name,
                    location: item.location,
                    bytes: item.size,
                    fileCount: item.fileCount,
                    disposition: itemDisposition
                ))
                if outcome.identity.kind == .directory {
                    removedDirectories.append(outcome.deletionURL)
                }
            } catch is CancellationError {
                snapshots.remove(
                    providerID: item.providerID,
                    itemID: item.id
                )
                break
            } catch {
                failures.append(Self.failure(for: item, reason: error.localizedDescription))
            }
            snapshots.remove(
                providerID: item.providerID,
                itemID: item.id
            )
        }

        let after = await capacitySnapshot()
        Log.cleanup.info(
            "Cleanup finished: \(cleaned.count, privacy: .public) cleaned, \(failures.count, privacy: .public) not cleaned"
        )
        return CleanupResult(
            startedAt: startedAt,
            finishedAt: Date(),
            availableBefore: before.available,
            availableAfter: after.available,
            availableBeforeExcludingPurgeable: before.excludingPurgeable,
            availableAfterExcludingPurgeable: after.excludingPurgeable,
            cleanedItems: cleaned,
            failures: failures
        )
    }

    private static func failure(for item: CleanupItem, reason: String) -> CleanupFailure {
        Log.cleanupRefused(item, reason: reason)
        return CleanupFailure(itemName: item.name, path: item.url.path, reason: reason)
    }

    private func capacitySnapshot() async -> (available: Int64, excludingPurgeable: Int64?) {
        guard let statistics = try? await diskService.statistics() else { return (0, nil) }
        return (statistics.available, statistics.availableExcludingPurgeable)
    }

    /// How an item is removed. The review sheet shows this same value, so what it says
    /// matches what the engine does: Trash items are always deleted permanently; user files
    /// and Trash-first developer folders follow the request and default to the Trash;
    /// everything else, such as caches, is deleted permanently.
    static func disposition(
        for item: CleanupItem,
        requested: CleanupDisposition?
    ) -> CleanupDisposition {
        if item.location == .trash { return .permanent }
        if item.location.defaultsToTrash || item.risk == .userFiles {
            return requested ?? .trash
        }
        return .permanent
    }

    /// Locations chosen by rules rather than by a fixed folder repeat those rules right before
    /// removal, because a marker, a newer version, or an emulator may have changed since the scan.
    private static func requireStillQualifies(
        _ validated: ValidatedCleanupTarget,
        location: CleanupLocation
    ) throws {
        let url = validated.deletionURL
        switch location {
        case .projectArtifacts:
            if ProjectArtifactRules.kind(ofDirectory: url) == nil {
                throw SafetyValidationError.unrecognizedProjectArtifact(url.path)
            }
        case .staleIDEVersions:
            if !StaleIDEVersionRules.isRemovable(url, approvedRoot: validated.approvedRoot) {
                throw SafetyValidationError.noLongerQualifies(url.path)
            }
        case .electronAppCaches:
            if !ElectronAppCacheRules.isCacheFolder(url, inApplication: validated.approvedRoot) {
                throw SafetyValidationError.noLongerQualifies(url.path)
            }
        case .androidSystemImages:
            if !AndroidSystemImageRules.isRemovable(url, approvedRoot: validated.approvedRoot) {
                throw SafetyValidationError.noLongerQualifies(url.path)
            }
        default:
            break
        }
    }

    private func deduplicated(_ items: [CleanupItem]) -> [CleanupItem] {
        var paths: Set<String> = []
        return items.filter {
            paths.insert($0.url.standardizedFileURL.path).inserted
        }
    }

    /// Compares a target with its scan-time identity under the location's policy.
    static func identity(
        _ current: FileIdentity,
        matches scanned: FileIdentity,
        policy: CleanupLocation.IdentityMatching
    ) -> Bool {
        switch policy {
        case .strict:
            current == scanned
        case .stableObject:
            current.device == scanned.device
                && current.inode == scanned.inode
                && current.kind == scanned.kind
        }
    }

    private static func matchesScannedMetadata(
        _ item: CleanupItem,
        identity: FileIdentity
    ) -> Bool {
        guard identity.kind == item.kind else { return false }

        // An active cache folder's modification time changes whenever its app adds an entry;
        // for those locations the folder only has to be the same object (see
        // `CleanupLocation.identityMatching`). Files are always checked.
        let skipsFolderTimestamp = item.kind == .directory
            && item.location.identityMatching == .stableObject
        if !skipsFolderTimestamp,
           let modifiedAt = item.modifiedAt,
           Int64(modifiedAt.timeIntervalSince1970) != identity.modificationTime {
            return false
        }

        if item.kind == .file,
           item.size != identity.byteSize,
           item.size != identity.allocatedByteSize {
            return false
        }

        return true
    }
}
