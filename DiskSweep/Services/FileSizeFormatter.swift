import Foundation

enum FileSizeFormatter {
    static func string(fromByteCount byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: byteCount)
    }
}
