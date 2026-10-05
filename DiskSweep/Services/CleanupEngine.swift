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

actor CleanupEngine {
    private let safetyValidator: SafetyValidator
    private let diskService: DiskService

    init(
        safetyValidator: SafetyValidator = SafetyValidator(),
        diskService: DiskService = DiskService()
    ) {
        self.safetyValidator = safetyValidator
        self.diskService = diskService
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
        let availableBefore = await availableCapacity()
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
                Self.isStrictDescendant(item.url.standardizedFileURL, of: $0)
            }) {
                continue
            }

            guard item.isDeletable else {
                failures.append(CleanupFailure(
                    itemName: item.name,
                    path: item.url.path,
                    reason: "This item is informational and is not marked as deletable."
                ))
                continue
            }

            guard let authorization = authorizationMap[item.providerID] else {
                failures.append(CleanupFailure(
                    itemName: item.name,
                    path: item.url.path,
                    reason: "The cleanup provider did not supply an allowlisted root."
                ))
                continue
            }

            guard authorization.location == item.location else {
                failures.append(CleanupFailure(
                    itemName: item.name,
                    path: item.url.path,
                    reason: "The item does not match its cleanup provider's category."
                ))
                continue
            }

            let itemDisposition = resolvedDisposition(
                for: item,
                requested: disposition
            )
            let isProjectArtifact = item.location == .projectArtifacts
            let permittedNestedNames = isProjectArtifact
                ? ProjectArtifactRules.permittedNestedNames
                : []
            let scanSnapshot = CleanupSnapshotRegistry.shared.snapshot(
                providerID: item.providerID,
                itemID: item.id
            )
            if authorization.requiresSnapshot, scanSnapshot == nil {
                failures.append(CleanupFailure(
                    itemName: item.name,
                    path: item.url.path,
                    reason: "The scan-time file identity is unavailable. Rescan before cleaning this item."
                ))
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
                       firstValidation.identity != scanSnapshot.identity {
                        throw SafetyValidationError.targetChanged(item.url.path)
                    }

                    try Task.checkCancellation()

                    // This second check is deliberately adjacent to the filesystem mutation.
                    var validated = try validator.revalidate(
                        firstValidation,
                        location: item.location,
                        allowedRoots: authorization.allowedRoots
                    )
                    try validator.validateDirectoryContents(
                        validated,
                        exclusionRoots: (scanSnapshot?.exclusionRoots ?? []) + exclusions,
                        permittedNestedNames: permittedNestedNames
                    )
                    if isProjectArtifact,
                       ProjectArtifactRules.kind(ofDirectory: validated.deletionURL) == nil {
                        throw SafetyValidationError.unrecognizedProjectArtifact(
                            validated.deletionURL.path
                        )
                    }
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
                CleanupSnapshotRegistry.shared.remove(
                    providerID: item.providerID,
                    itemID: item.id
                )
                break
            } catch {
                failures.append(CleanupFailure(
                    itemName: item.name,
                    path: item.url.path,
                    reason: error.localizedDescription
                ))
            }
            CleanupSnapshotRegistry.shared.remove(
                providerID: item.providerID,
                itemID: item.id
            )
        }

        let availableAfter = await availableCapacity()
        return CleanupResult(
            startedAt: startedAt,
            finishedAt: Date(),
            availableBefore: availableBefore,
            availableAfter: availableAfter,
            cleanedItems: cleaned,
            failures: failures
        )
    }

    private func availableCapacity() async -> Int64 {
        (try? await diskService.statistics())?.available ?? 0
    }

    private func resolvedDisposition(
        for item: CleanupItem,
        requested: CleanupDisposition?
    ) -> CleanupDisposition {
        if item.location == .trash { return .permanent }
        if item.location == .downloads
            || item.location == .projectArtifacts
            || item.risk == .userFiles {
            return requested ?? .trash
        }
        return .permanent
    }

    private func deduplicated(_ items: [CleanupItem]) -> [CleanupItem] {
        var paths: Set<String> = []
        return items.filter {
            paths.insert($0.url.standardizedFileURL.path).inserted
        }
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func matchesScannedMetadata(
        _ item: CleanupItem,
        identity: FileIdentity
    ) -> Bool {
        guard identity.kind == item.kind else { return false }

        if let modifiedAt = item.modifiedAt,
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
