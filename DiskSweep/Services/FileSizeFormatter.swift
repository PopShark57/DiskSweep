import Foundation
import Synchronization

enum FileSizeFormatter {
    /// One configured formatter for every size label, instead of a new `ByteCountFormatter`
    /// per call. `ByteCountFormatter` isn't Sendable, so the shared instance is guarded.
    /// (`ByteCountFormatStyle` was tried first, but it writes "kB", shows bytes, and uses PB,
    /// which changes every label.)
    private static let formatter = Mutex(makeFormatter())

    private static func makeFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }

    static func string(fromByteCount byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 KB" }
        return formatter.withLock { $0.string(fromByteCount: byteCount) }
    }
}
