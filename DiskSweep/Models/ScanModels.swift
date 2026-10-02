import Foundation

enum ScanPhase: String, Codable, Hashable, Sendable {
    case idle
    case preparing
    case enumerating
    case hashing
    case finalizing
    case completed
    case cancelled
}

struct ScanProgress: Codable, Hashable, Sendable {
    var phase: ScanPhase
    var location: CleanupLocation?
    var currentPath: String
    var filesAnalyzed: Int
    var bytesFound: Int64
    var completedProviders: Int
    var totalProviders: Int

    static let idle = ScanProgress(
        phase: .idle,
        location: nil,
        currentPath: "",
        filesAnalyzed: 0,
        bytesFound: 0,
        completedProviders: 0,
        totalProviders: 0
    )

    var fractionCompleted: Double? {
        guard totalProviders > 0 else { return nil }
        return min(1, max(0, Double(completedProviders) / Double(totalProviders)))
    }
}

struct ScanIssue: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case permissionDenied
        case disappeared
        case inaccessible
        case cancelled
        case inputOutput
        case unknown
    }

    let id: UUID
    let kind: Kind
    let path: String
    let message: String

    init(id: UUID = UUID(), kind: Kind, path: String, message: String) {
        self.id = id
        self.kind = kind
        self.path = path
        self.message = message
    }
}

struct ScanContext: Sendable {
    let homeDirectory: URL
    let exclusions: [URL]
    let showHiddenFiles: Bool
    let excludedDirectoryNames: Set<String>
    let excludeNodeModulesFromDeepScans: Bool
    let excludeCloudPlaceholders: Bool
    let excludePhotoLibraries: Bool
    let excludeTimeMachineBackups: Bool
    let excludePackageContents: Bool
    let now: Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        exclusions: [URL] = [],
        showHiddenFiles: Bool = false,
        excludedDirectoryNames: Set<String> = [".git", ".svn"],
        excludeNodeModulesFromDeepScans: Bool = true,
        excludeCloudPlaceholders: Bool = true,
        excludePhotoLibraries: Bool = true,
        excludeTimeMachineBackups: Bool = true,
        excludePackageContents: Bool = true,
        now: Date = Date()
    ) {
        self.homeDirectory = homeDirectory
        self.exclusions = exclusions
        self.showHiddenFiles = showHiddenFiles
        self.excludedDirectoryNames = excludedDirectoryNames
        self.excludeNodeModulesFromDeepScans = excludeNodeModulesFromDeepScans
        self.excludeCloudPlaceholders = excludeCloudPlaceholders
        self.excludePhotoLibraries = excludePhotoLibraries
        self.excludeTimeMachineBackups = excludeTimeMachineBackups
        self.excludePackageContents = excludePackageContents
        self.now = now
    }
}
