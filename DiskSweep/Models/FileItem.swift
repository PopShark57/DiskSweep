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
    /// A bundle such as an app, a virtual machine, or a sparse bundle, sized as one item.
    /// Packages are shown but never offered for cleanup.
    let isPackage: Bool
    /// Bytes not shared with any other file (APFS clones share blocks). Removing the file
    /// frees about this much. `nil` when not measured.
    let uniqueSize: Int64?

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
        isHidden: Bool = false,
        isPackage: Bool = false,
        uniqueSize: Int64? = nil
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
        self.isPackage = isPackage
        self.uniqueSize = uniqueSize.map { max(0, $0) }
    }

    /// A copy with its unique size measured with `PrivateSizeReader`. Packages and
    /// directories keep `nil`.
    func measuringUniqueSize() -> FileItem {
        guard kind == .file, !isPackage else { return self }
        return FileItem(
            id: id, url: url, name: name, size: size, kind: kind,
            createdAt: createdAt, modifiedAt: modifiedAt, accessedAt: accessedAt,
            contentTypeIdentifier: contentTypeIdentifier, isHidden: isHidden,
            isPackage: isPackage, uniqueSize: PrivateSizeReader.privateSize(of: url)
        )
    }

    /// True when much of the file is shared with clones, so removing it frees less.
    var isMostlyShared: Bool {
        guard let uniqueSize, size > 0 else { return false }
        return uniqueSize * 10 < size * 9
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
    /// A bundle sized as one leaf, such as an app or a virtual machine.
    let isPackage: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        name: String? = nil,
        size: Int64,
        fileCount: Int,
        children: [DirectoryNode] = [],
        isPackage: Bool = false
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = max(0, size)
        self.fileCount = max(0, fileCount)
        self.children = children
        self.isPackage = isPackage
    }
}

extension DirectoryNode {
    /// Bytes in this folder that no listed child accounts for: files stored directly in it,
    /// plus subfolders too small to be listed. Shown so the rows add up to the folder total.
    var unlistedSize: Int64 {
        max(0, size - children.reduce(0) { $0 + $1.size })
    }
}

/// One slice of the Disk Usage chart.
struct DiskUsageSlice: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case otherFolders
        case filesInFolder
    }

    let id: String
    let name: String
    let size: Int64
    let kind: Kind

    /// The largest children, then the rest merged into one "Other folders" slice, then the
    /// space no listed child accounts for. Slices add up to the folder's size.
    static func slices(for node: DirectoryNode, maximumFolders: Int = 7) -> [DiskUsageSlice] {
        let sorted = node.children.sorted { $0.size > $1.size }
        var slices = sorted.prefix(max(0, maximumFolders)).map {
            DiskUsageSlice(id: $0.url.path, name: $0.name, size: $0.size, kind: .folder)
        }
        let rest = sorted.dropFirst(max(0, maximumFolders)).reduce(Int64(0)) { $0 + $1.size }
        if rest > 0 {
            slices.append(DiskUsageSlice(id: "other-folders", name: "Other folders", size: rest, kind: .otherFolders))
        }
        if node.unlistedSize > 0 {
            slices.append(DiskUsageSlice(
                id: "files-in-folder",
                name: "Files in this folder",
                size: node.unlistedSize,
                kind: .filesInFolder
            ))
        }
        return slices.filter { $0.size > 0 }
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

