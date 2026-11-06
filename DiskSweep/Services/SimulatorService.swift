import Foundation

/// A simulator whose runtime is gone, as reported by `simctl`.
struct UnavailableSimulator: Hashable, Sendable, Identifiable {
    let udid: String
    let name: String
    let runtime: String
    let reason: String?

    var id: String { udid }
}

enum SimulatorServiceError: Error, LocalizedError, Sendable {
    case toolFailed(status: Int32, message: String)
    case timedOut
    case unreadableOutput

    var errorDescription: String? {
        switch self {
        case let .toolFailed(status, message):
            message.isEmpty
                ? String(localized: "simctl failed with status \(status). Xcode may not be installed or selected.")
                : String(localized: "simctl failed: \(message)")
        case .timedOut:
            String(localized: "simctl didn't finish in time.")
        case .unreadableOutput:
            String(localized: "simctl's output couldn't be read.")
        }
    }
}

/// Runs a command with fixed arguments, never through a shell.
protocol ProcessRunning: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> (status: Int32, output: Data, errorOutput: Data)
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> (status: Int32, output: Data, errorOutput: Data) {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            // Read while running so a large output can't fill the pipe and stall the tool.
            async let outputData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let errorData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value

            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning {
                if ContinuousClock.now >= deadline || Task.isCancelled {
                    process.terminate()
                    throw Task.isCancelled ? CancellationError() : SimulatorServiceError.timedOut
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return (process.terminationStatus, await outputData, await errorData)
        }.value
    }
}

/// Finds and removes simulators whose runtime is no longer installed. Uses `simctl` rather
/// than deleting paths, because simulator data and runtimes are managed by CoreSimulator.
struct SimulatorService: Sendable {
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    static let listArguments = ["simctl", "list", "devices", "unavailable", "-j"]
    static let deleteArguments = ["simctl", "delete", "unavailable"]

    let runner: any ProcessRunning
    var timeout: Duration = .seconds(120)

    init(runner: any ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    func unavailableSimulators() async throws -> [UnavailableSimulator] {
        let result = try await runner.run(Self.xcrun, arguments: Self.listArguments, timeout: timeout)
        guard result.status == 0 else {
            throw SimulatorServiceError.toolFailed(
                status: result.status,
                message: String(decoding: result.errorOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try Self.parseUnavailable(result.output)
    }

    func deleteUnavailableSimulators() async throws {
        let result = try await runner.run(Self.xcrun, arguments: Self.deleteArguments, timeout: timeout)
        guard result.status == 0 else {
            throw SimulatorServiceError.toolFailed(
                status: result.status,
                message: String(decoding: result.errorOutput, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        Log.cleanup.info("Deleted unavailable simulators with simctl")
    }

    static func parseUnavailable(_ data: Data) throws -> [UnavailableSimulator] {
        struct Listing: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let isAvailable: Bool?
                let availabilityError: String?
            }
            let devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw SimulatorServiceError.unreadableOutput
        }
        return listing.devices
            .flatMap { runtime, devices in
                devices
                    .filter { $0.isAvailable == false }
                    .map {
                        UnavailableSimulator(
                            udid: $0.udid,
                            name: $0.name,
                            runtime: Self.runtimeName(runtime),
                            reason: $0.availabilityError
                        )
                    }
            }
            .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → `iOS 17.0`.
    static func runtimeName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }
}
