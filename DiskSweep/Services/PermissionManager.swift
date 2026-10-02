import AppKit
import Foundation
import Observation

enum FullDiskAccessStatus: String, Codable, Hashable, Sendable {
    case likelyGranted
    case likelyRestricted
    case unknown

    var title: String {
        switch self {
        case .likelyGranted:
            "Full Disk Access Appears Enabled"
        case .likelyRestricted:
            "Full Disk Access May Be Limited"
        case .unknown:
            "Full Disk Access Status Unknown"
        }
    }

    var explanation: String {
        switch self {
        case .likelyGranted:
            "DiskSweep could read a macOS-protected folder. macOS does not provide an API that conclusively reports Full Disk Access status."
        case .likelyRestricted:
            "Some folders are protected by macOS. DiskSweep will skip inaccessible items and can still clean locations you allow."
        case .unknown:
            "macOS does not provide an API that conclusively reports Full Disk Access status. DiskSweep checks access only when it scans and skips anything unavailable."
        }
    }
}

/// Reports a conservative Full Disk Access estimate and opens the corresponding System Settings pane.
/// It never modifies permissions or attempts to bypass macOS privacy controls.
@MainActor
@Observable
final class PermissionManager {
    private(set) var fullDiskAccessStatus: FullDiskAccessStatus = .unknown

    var statusTitle: String { fullDiskAccessStatus.title }
    var explanation: String { fullDiskAccessStatus.explanation }

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let protectedDirectoryCandidates: [URL]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        protectedDirectoryCandidates = [
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            home.appendingPathComponent("Library/Mail", isDirectory: true)
        ]
        refreshStatus()
    }

    func refreshStatus() {
        var foundProtectedDirectory = false
        var encounteredPermissionDenial = false

        for directory in protectedDirectoryCandidates
        where fileManager.fileExists(atPath: directory.path) {
            foundProtectedDirectory = true

            do {
                // Reading the directory listing is a bounded, local probe. Names are discarded
                // immediately and are never stored or transmitted.
                _ = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
                fullDiskAccessStatus = .likelyGranted
                return
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                encounteredPermissionDenial = true
            } catch {
                // An unavailable or transiently busy directory cannot establish permission state.
                continue
            }
        }

        if encounteredPermissionDenial {
            fullDiskAccessStatus = .likelyRestricted
        } else if foundProtectedDirectory {
            fullDiskAccessStatus = .unknown
        } else {
            fullDiskAccessStatus = .unknown
        }
    }

    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else {
            return false
        }

        return NSWorkspace.shared.open(settingsURL)
    }
}
