import Foundation

enum FileItemKind: String, Codable, Hashable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

struct CleanupItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let providerID: String
    let location: CleanupLocation
    let name: String
    let url: URL
    let size: Int64
    let fileCount: Int
    let kind: FileItemKind
    let modifiedAt: Date?
    let risk: CleanupRisk
    let explanation: String
    /// A short, item-specific note shown under the item's path, such as how to rebuild it.
    let detail: String?
    let isSelectedByDefault: Bool
    let isDeletable: Bool
    let children: [CleanupItem]

    init(
        id: UUID = UUID(),
        providerID: String,
        location: CleanupLocation,
        name: String,
        url: URL,
        size: Int64,
        fileCount: Int = 1,
        kind: FileItemKind,
        modifiedAt: Date? = nil,
        risk: CleanupRisk,
        explanation: String,
        detail: String? = nil,
        isSelectedByDefault: Bool? = nil,
        isDeletable: Bool = true,
        children: [CleanupItem] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.location = location
        self.name = name
        self.url = url
        self.size = max(0, size)
        self.fileCount = max(0, fileCount)
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.risk = risk
        self.explanation = explanation
        self.detail = detail
        self.isSelectedByDefault = isSelectedByDefault ?? risk.isSelectedByDefault
        self.isDeletable = isDeletable
        self.children = children
    }
}

struct CleanupCategory: Identifiable, Codable, Hashable, Sendable {
    var id: CleanupLocation { location }
    let location: CleanupLocation
    var items: [CleanupItem]
    var issues: [ScanIssue]
    var scannedAt: Date

    var name: String { location.name }
    var explanation: String { location.explanation }
    var risk: CleanupRisk { location.risk }
    var inspectedSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 {
        items.filter(\.isDeletable).reduce(0) { $0 + $1.size }
    }
    var fileCount: Int {
        items.filter(\.isDeletable).reduce(0) { $0 + $1.fileCount }
    }
}
