import Foundation

struct FileItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let kind: FileItemKind
    let createdAt: Date?
    let modifiedAt: Date?
    let accessedAt: Date?
    let contentTypeIdentifier: String?
    let isHidden: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        size: Int64,
        kind: FileItemKind,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        accessedAt: Date? = nil,
        contentTypeIdentifier: String? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = max(0, size)
        self.kind = kind
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.accessedAt = accessedAt
        self.contentTypeIdentifier = contentTypeIdentifier
        self.isHidden = isHidden
    }

    var fileExtension: String {
        let value = url.pathExtension
        return value.isEmpty ? "—" : value.lowercased()
    }
}

struct DirectoryNode: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let fileCount: Int
    var children: [DirectoryNode]

    init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        size: Int64,
        fileCount: Int,
        children: [DirectoryNode] = []
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = max(0, size)
        self.fileCount = max(0, fileCount)
        self.children = children
    }
}

struct DuplicateGroup: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fingerprint: String
    let fileSize: Int64
    let files: [FileItem]

    init(
        id: UUID = UUID(),
        fingerprint: String,
        fileSize: Int64,
        files: [FileItem]
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.fileSize = max(0, fileSize)
        self.files = files
    }

    var reclaimableSize: Int64 {
        guard files.count > 1 else { return 0 }
        return fileSize * Int64(files.count - 1)
    }
}

