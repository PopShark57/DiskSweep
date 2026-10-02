import Foundation
import XCTest

final class AnalyzerTemporaryDirectory {
    let url: URL

    init(function: StaticString = #function) throws {
        let safeName = String(describing: function)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepTests-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let destination = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        return destination
    }

    @discardableResult
    func file(
        _ relativePath: String,
        data: Data,
        modifiedAt: Date? = nil
    ) throws -> URL {
        let destination = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: destination.path
            )
        }
        return destination
    }

    @discardableResult
    func sparseFile(
        _ relativePath: String,
        logicalSize: UInt64,
        modifiedAt: Date? = nil
    ) throws -> URL {
        let destination = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: nil))
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: logicalSize)
        try handle.close()
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: destination.path
            )
        }
        return destination
    }
}

actor AnalyzerStartSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
