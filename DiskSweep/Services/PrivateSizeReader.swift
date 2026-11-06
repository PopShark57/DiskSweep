import Darwin
import Foundation

/// Reads how many of a file's bytes are not shared with any other file.
///
/// APFS clones (`cp -c`, Finder duplicates) share blocks, so removing a clone frees only its
/// private bytes. `ATTR_CMNEXT_PRIVATESIZE` (macOS 10.15+) reports exactly that. All unsafe
/// buffer handling for it lives here.
enum PrivateSizeReader {
    /// The private (unshared) size in bytes, or `nil` when the volume doesn't report it.
    static func privateSize(of url: URL) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)

        // Layout: u_int32_t length, attribute_set_t returned (5 × u_int32_t), off_t size.
        let lengthSize = MemoryLayout<UInt32>.size
        let returnedSize = MemoryLayout<attribute_set_t>.size
        let bufferSize = lengthSize + returnedSize + MemoryLayout<off_t>.size
        var buffer = [UInt8](repeating: 0, count: bufferSize + 16)

        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return buffer.withUnsafeMutableBytes { raw in
                getattrlist(path, &request, raw.baseAddress, raw.count, options)
            }
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> Int64? in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard Int(length) >= bufferSize else { return nil }
            let returned = raw.loadUnaligned(fromByteOffset: lengthSize, as: attribute_set_t.self)
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let size = raw.loadUnaligned(fromByteOffset: lengthSize + returnedSize, as: off_t.self)
            return max(0, Int64(size))
        }
    }
}
