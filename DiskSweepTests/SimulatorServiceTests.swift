import Foundation
import XCTest
@testable import DiskSweep

/// Records commands instead of running them, so no test ever runs simctl.
private actor RecordingRunner: ProcessRunning {
    var calls: [[String]] = []
    let output: Data
    let status: Int32

    init(output: Data = Data(), status: Int32 = 0) {
        self.output = output
        self.status = status
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> (status: Int32, output: Data, errorOutput: Data) {
        XCTAssertEqual(executable.path, "/usr/bin/xcrun")
        calls.append(arguments)
        return (status, output, Data("boom".utf8))
    }
}

final class SimulatorServiceTests: XCTestCase {
    private let listing = Data("""
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
          {"udid": "A", "name": "iPhone 14", "isAvailable": false,
           "availabilityError": "runtime profile not found"},
          {"udid": "B", "name": "iPad Air", "isAvailable": true}
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-9-0": [
          {"udid": "C", "name": "Apple Watch", "isAvailable": false}
        ]
      }
    }
    """.utf8)

    func testParsesOnlyUnavailableDevices() throws {
        let devices = try SimulatorService.parseUnavailable(listing)
        XCTAssertEqual(devices.map(\.udid), ["A", "C"])
        XCTAssertEqual(devices.first?.runtime, "iOS 16.4")
        XCTAssertEqual(devices.first?.reason, "runtime profile not found")
        XCTAssertThrowsError(try SimulatorService.parseUnavailable(Data("not json".utf8)))
    }

    func testUsesFixedArgumentsAndReportsFailures() async throws {
        let runner = RecordingRunner(output: listing)
        let service = SimulatorService(runner: runner)

        let devices = try await service.unavailableSimulators()
        try await service.deleteUnavailableSimulators()

        XCTAssertEqual(devices.count, 2)
        let calls = await runner.calls
        XCTAssertEqual(calls, [
            ["simctl", "list", "devices", "unavailable", "-j"],
            ["simctl", "delete", "unavailable"]
        ])

        let failing = SimulatorService(runner: RecordingRunner(status: 72))
        do {
            try await failing.deleteUnavailableSimulators()
            XCTFail("A non-zero status must throw")
        } catch let error as SimulatorServiceError {
            XCTAssertTrue(error.localizedDescription.contains("boom"))
        }
    }

    @MainActor
    func testViewModelChecksThenDeletesThroughSimctlOnly() async throws {
        let runner = RecordingRunner(output: listing)
        let suite = "DiskSweepSimulatorTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSweepSimulatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let model = AppViewModel(
            homeDirectory: sandbox,
            temporaryDirectory: sandbox,
            standardProviders: [],
            settings: SettingsStore(userDefaults: UserDefaults(suiteName: suite)!),
            history: CleanupHistoryStore(fileURL: sandbox.appendingPathComponent("h.json")),
            permissions: PermissionManager(homeDirectory: sandbox),
            runningApps: { [] },
            simulatorService: SimulatorService(runner: runner)
        )

        model.checkUnavailableSimulators()
        await model.waitForSimulatorCheck()
        guard case let .found(devices) = model.simulatorCheck else {
            return XCTFail("Expected devices, got \(model.simulatorCheck)")
        }
        XCTAssertEqual(devices.count, 2)

        model.deleteUnavailableSimulators()
        await model.waitForSimulatorCheck()
        while model.simulatorCheck == .notChecked { await Task.yield() }
        await model.waitForSimulatorCheck()

        let calls = await runner.calls
        XCTAssertEqual(calls, [
            SimulatorService.listArguments,
            SimulatorService.deleteArguments,
            SimulatorService.listArguments
        ])
    }
}
