import Foundation

/// Puts items that a cleanup moved to the Trash back where they were.
///
/// It never overwrites anything: an item is restored only when it is still in a Trash
/// folder, its original folder still exists, and nothing has taken its original name.
struct TrashRestorer: Sendable {
    struct Outcome: Sendable, Equatable {
        var restored: [String] = []
        var notRestored: [(name: String, reason: String)] = []

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.restored == rhs.restored
                && lhs.notRestored.map(\.name) == rhs.notRestored.map(\.name)
        }
    }

    func restore(_ items: [TrashedItem]) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager()

        for item in items {
            let trashURL = URL(fileURLWithPath: item.trashPath).standardizedFileURL
            let originalURL = URL(fileURLWithPath: item.originalPath).standardizedFileURL

            guard Self.isInsideTrash(trashURL) else {
                outcome.notRestored.append((item.name, "The recorded Trash location isn't in a Trash folder."))
                continue
            }
            guard (try? SafetyValidator.captureIdentity(at: trashURL)) != nil else {
                outcome.notRestored.append((item.name, "It's no longer in the Trash."))
                continue
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(
                atPath: originalURL.deletingLastPathComponent().path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                outcome.notRestored.append((item.name, "Its original folder no longer exists."))
                continue
            }
            if case .some = try? SafetyValidator.captureIdentity(at: originalURL) {
                outcome.notRestored.append((item.name, "Something else now uses its original name, so DiskSweep left both in place."))
                continue
            }

            do {
                // moveItem refuses to replace an existing item, so a file that appears at the
                // original path in the meantime is still never overwritten.
                try manager.moveItem(at: trashURL, to: originalURL)
                outcome.restored.append(item.name)
            } catch {
                outcome.notRestored.append((item.name, error.localizedDescription))
            }
        }

        if !outcome.notRestored.isEmpty {
            Log.cleanup.error("Put Back left \(outcome.notRestored.count, privacy: .public) items in the Trash")
        }
        return outcome
    }

    /// The user's `~/.Trash` or a volume's `.Trashes` folder.
    static func isInsideTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.dropLast().contains {
            $0 == ".Trash" || $0 == ".Trashes"
        }
    }
}
