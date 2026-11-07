import Darwin
import Foundation

/// Permanent removal that can't be redirected by a symbolic link swapped in after validation.
///
/// It opens the approved root, walks to the target one component at a time with
/// `openat(…, O_NOFOLLOW)`, checks that the target is still the validated object (device and
/// inode), and removes it relative to its parent's descriptor. Folders are emptied the same
/// way, depth first, never following a link (a link inside is removed as a link) and never
/// leaving the target's volume. Moves to the Trash keep using `FileManager.trashItem`.
enum SecureRemoval {
    static func removeItem(_ validated: ValidatedCleanupTarget) throws {
        let rootComponents = validated.approvedRoot.standardizedFileURL.pathComponents
        let targetComponents = validated.deletionURL.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            throw SafetyValidationError.outsideApprovedRoots(validated.deletionURL.path)
        }
        let relative = Array(targetComponents.dropFirst(rootComponents.count))
        let path = validated.deletionURL.path
        let device = dev_t(truncatingIfNeeded: validated.identity.device)

        var directory = validated.approvedRoot.withUnsafeFileSystemRepresentation { rootPath -> Int32 in
            guard let rootPath else { return -1 }
            return open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { throw SafetyValidationError.targetChanged(path) }
        defer { close(directory) }

        for component in relative.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            // ELOOP or ENOTDIR here means a folder on the way was replaced, often by a link.
            guard next >= 0 else { throw SafetyValidationError.targetChanged(path) }
            close(directory)
            directory = next
        }

        let name = relative[relative.count - 1]
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw errno == ENOENT
                ? SafetyValidationError.targetDoesNotExist(path)
                : SafetyValidationError.cannotInspect(path)
        }
        guard UInt64(information.st_dev) == validated.identity.device,
              UInt64(information.st_ino) == validated.identity.inode else {
            throw SafetyValidationError.targetChanged(path)
        }

        switch information.st_mode & S_IFMT {
        case S_IFREG:
            guard unlinkat(directory, name, 0) == 0 else { throw posixError(path) }
        case S_IFDIR:
            try removeDirectory(
                named: name,
                in: directory,
                expectedInode: information.st_ino,
                device: device,
                path: path
            )
        default:
            throw SafetyValidationError.unsupportedFileType(path)
        }
    }

    private static func removeDirectory(
        named name: String,
        in parent: Int32,
        expectedInode: ino_t,
        device: dev_t,
        path: String
    ) throws {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SafetyValidationError.targetChanged(path) }
        defer { close(directory) }

        var information = stat()
        guard fstat(directory, &information) == 0,
              information.st_ino == expectedInode,
              information.st_dev == device else {
            throw SafetyValidationError.targetChanged(path)
        }

        for child in try entryNames(of: directory, path: path) {
            try Task.checkCancellation()
            var childInformation = stat()
            guard fstatat(directory, child, &childInformation, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw posixError(path)
            }
            if childInformation.st_mode & S_IFMT == S_IFDIR {
                guard childInformation.st_dev == device else {
                    throw SafetyValidationError.volumeBoundary(path)
                }
                try removeDirectory(
                    named: child,
                    in: directory,
                    expectedInode: childInformation.st_ino,
                    device: device,
                    path: path
                )
            } else if unlinkat(directory, child, 0) != 0, errno != ENOENT {
                // Files, and symbolic links themselves; a link's target is never touched.
                throw posixError(path)
            }
        }

        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posixError(path) }
    }

    private static func entryNames(of directory: Int32, path: String) throws -> [String] {
        let listing = dup(directory)
        guard listing >= 0, let stream = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            throw SafetyValidationError.cannotInspect(path)
        }
        defer { closedir(stream) }

        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func posixError(_ path: String) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code.rawValue),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
