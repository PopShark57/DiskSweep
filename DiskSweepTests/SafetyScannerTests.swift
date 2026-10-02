import Foundation
import XCTest
@testable import DiskSweep

final class SafetyScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testScannerHonorsDefaultExclusions() async throws {
        let included = root.appendingPathComponent("included.bin")
        try Data(repeating: 1, count: 32).write(to: included)
        try writeFile(relativePath: "node_modules/module.bin")
        try writeFile(relativePath: ".git/objects/object")
        try writeFile(relativePath: "Library.photoslibrary/original.jpg")

        let result = try await FileSystemScanner().scan(root: root)
        XCTAssertEqual(result.items.map(\.url.lastPathComponent), ["included.bin"])
        XCTAssertEqual(result.fileCount, 1)
        XCTAssertGreaterThanOrEqual(result.byteCount, 32)
    }

    func testDirectorySizerCountsNestedFiles() async throws {
        try writeFile(relativePath: "one.bin", byteCount: 11)
        try writeFile(relativePath: "Nested/two.bin", byteCount: 29)

        let result = try await DirectorySizer().size(of: root)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertGreaterThanOrEqual(result.byteCount, 40)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testScannerCancellationPropagatesToDetachedEnumeration() async throws {
        for index in 0..<400 {
            try writeFile(relativePath: "Many/\(index).tmp", byteCount: 1)
        }

        let firstBatch = expectation(description: "received first scan batch")
        firstBatch.assertForOverFulfill = false
        let scanRoot = try XCTUnwrap(root)
        let task = Task {
            try await FileSystemScanner().scan(
                root: scanRoot,
                options: FileSystemScanOptions(batchSize: 1)
            ) { _ in
                firstBatch.fulfill()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        await fulfillment(of: [firstBatch], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLogProviderEmitsOnlyOldIndividualFilesWithoutPreselection() async throws {
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let now = Date()
        let oldLog = try writeFile(
            relativePath: "Home/Library/Logs/Example/old.log",
            byteCount: 31
        )
        let activeLog = try writeFile(
            relativePath: "Home/Library/Logs/Example/active.log",
            byteCount: 17
        )
        let becameActiveLog = try writeFile(
            relativePath: "Home/Library/Logs/Example/became-active.log",
            byteCount: 23
        )
        try setModificationDate(now.addingTimeInterval(-31 * 86_400), for: oldLog)
        try setModificationDate(now.addingTimeInterval(-60 * 60), for: activeLog)
        try setModificationDate(
            now.addingTimeInterval(-31 * 86_400),
            for: becameActiveLog
        )

        let result = await LogProvider(
            homeDirectory: home,
            minimumAge: 30 * 86_400
        ).scan(
            context: ScanContext(homeDirectory: home, now: now),
            progress: { update in
                guard update.phase == .enumerating else { return }
                try? FileManager.default.setAttributes(
                    [.modificationDate: now],
                    ofItemAtPath: becameActiveLog.path
                )
            }
        )

        XCTAssertEqual(result.items.map(\.url), [oldLog])
        XCTAssertTrue(result.items.allSatisfy { $0.kind == .file })
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelectedByDefault })
        XCTAssertTrue(result.items.allSatisfy { $0.risk == .reviewRecommended })
        XCTAssertFalse(result.items.contains { $0.url == activeLog })
        XCTAssertFalse(result.items.contains { $0.url == becameActiveLog })
        XCTAssertFalse(result.items.contains { $0.kind == .directory })
    }

    func testNondeletablePartialDirectoryDoesNotCountAsReclaimable() async throws {
        let included = try writeFile(
            relativePath: "Partial/included.cache",
            byteCount: 101
        )
        let excludedDirectory = root.appendingPathComponent(
            "Partial/Preserve",
            isDirectory: true
        )
        _ = try writeFile(
            relativePath: "Partial/Preserve/important.cache",
            byteCount: 203
        )

        let result = await ProviderSupport.scanChildren(
            providerID: "partial-directory-test",
            location: .temporaryFiles,
            roots: [root],
            context: ScanContext(exclusions: [excludedDirectory]),
            progress: { _ in },
            forceDefaultSelection: false
        )

        let item = try XCTUnwrap(result.items.first { $0.url.lastPathComponent == "Partial" })
        XCTAssertFalse(item.isDeletable)
        XCTAssertGreaterThanOrEqual(item.size, 101)
        XCTAssertTrue(FileManager.default.fileExists(atPath: included.path))
        XCTAssertGreaterThan(result.category.inspectedSize, 0)
        XCTAssertEqual(result.category.totalSize, 0)
    }

    func testXcodeArchivesProviderEmitsIndividualArchivesNotDateContainers() async throws {
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let archives = "Home/Library/Developer/Xcode/Archives"
        let firstArchive = root.appendingPathComponent(
            "\(archives)/2026-08-01/Example 01.xcarchive",
            isDirectory: true
        )
        let secondArchive = root.appendingPathComponent(
            "\(archives)/2026-08-02/Example 02.xcarchive",
            isDirectory: true
        )
        _ = try writeFile(
            relativePath: "\(archives)/2026-08-01/Example 01.xcarchive/Products/app.bin",
            byteCount: 41
        )
        _ = try writeFile(
            relativePath: "\(archives)/2026-08-02/Example 02.xcarchive/dSYMs/symbols.bin",
            byteCount: 59
        )

        let result = await XcodeArchivesProvider(homeDirectory: home).scan(
            context: ScanContext(homeDirectory: home),
            progress: { _ in }
        )

        XCTAssertEqual(Set(result.items.map(\.url)), Set([firstArchive, secondArchive]))
        XCTAssertTrue(result.items.allSatisfy { $0.kind == .directory })
        XCTAssertTrue(result.items.allSatisfy { $0.url.pathExtension == "xcarchive" })
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelectedByDefault })
        XCTAssertFalse(result.items.contains { $0.name == "2026-08-01" })
        XCTAssertEqual(result.items.reduce(0) { $0 + $1.fileCount }, 2)
    }

    func testTemporaryProviderHonorsCancellationAfterFinalEnumerationBatch() async throws {
        let now = Date()
        let oldFile = try writeFile(relativePath: "old.tmp", byteCount: 7)
        try setModificationDate(now.addingTimeInterval(-3 * 86_400), for: oldFile)
        let provider = TemporaryFilesProvider(
            temporaryDirectory: root,
            minimumAge: 2 * 86_400
        )
        let finalBatch = expectation(description: "temporary scan reached final batch")
        finalBatch.assertForOverFulfill = false

        let task = Task {
            await provider.scan(
                context: ScanContext(now: now),
                progress: { update in
                    guard update.phase == .enumerating,
                          update.filesAnalyzed > 0 else { return }
                    finalBatch.fulfill()
                    try? await Task.sleep(for: .seconds(30))
                }
            )
        }

        await fulfillment(of: [finalBatch], timeout: 2)
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.map(\.kind), [.cancelled])
    }

    func testTemporaryProviderDropsFileThatBecomesActiveAfterEnumeration() async throws {
        let now = Date()
        let oldFile = try writeFile(relativePath: "became-active.tmp", byteCount: 13)
        try setModificationDate(now.addingTimeInterval(-3 * 86_400), for: oldFile)
        let provider = TemporaryFilesProvider(
            temporaryDirectory: root,
            minimumAge: 2 * 86_400
        )

        let result = await provider.scan(
            context: ScanContext(now: now),
            progress: { update in
                guard update.phase == .enumerating else { return }
                try? FileManager.default.setAttributes(
                    [.modificationDate: now],
                    ofItemAtPath: oldFile.path
                )
            }
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
    }

    func testTemporaryProviderRejectsRootReplacedBySymbolicLink() async throws {
        let scanRoot = root.appendingPathComponent("RequestedTemp", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scanRoot,
            withIntermediateDirectories: true
        )
        let provider = TemporaryFilesProvider(temporaryDirectory: scanRoot)
        try FileManager.default.removeItem(at: scanRoot)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideFile = outside.appendingPathComponent("private.tmp")
        try Data(repeating: 0x42, count: 19).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: scanRoot,
            withDestinationURL: outside
        )

        let result = await provider.scan(
            context: ScanContext(),
            progress: { _ in }
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testProviderSupportCancellationDoesNotPublishPartialCandidates() async throws {
        for index in 0..<20 {
            try writeFile(relativePath: "Candidates/\(index).cache", byteCount: 3)
        }
        let scanRoot = root.appendingPathComponent("Candidates", isDirectory: true)
        let firstCandidate = expectation(description: "provider emitted progress")
        firstCandidate.assertForOverFulfill = false

        let task = Task {
            await ProviderSupport.scanChildren(
                providerID: "cancelled-provider-test",
                location: .temporaryFiles,
                roots: [scanRoot],
                context: ScanContext(),
                progress: { update in
                    guard update.phase == .enumerating else { return }
                    firstCandidate.fulfill()
                    try? await Task.sleep(for: .seconds(30))
                }
            )
        }

        await fulfillment(of: [firstCandidate], timeout: 2)
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.kind == .cancelled })
    }

    @discardableResult
    private func writeFile(relativePath: String, byteCount: Int = 8) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x7F, count: byteCount).write(to: file)
        return file
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}
