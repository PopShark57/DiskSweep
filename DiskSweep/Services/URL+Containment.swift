import Foundation

/// Path-containment checks shared by the scanner, providers, analyzers, the safety validator,
/// and the cleanup engine. Keeping one implementation means every safety comparison uses the
/// same rule: compare the standardized path components, never string prefixes, so
/// `/a/bc` is not inside `/a/b`.
extension URL {
    /// The receiver is `root` itself or anywhere below it.
    func isSameOrDescendant(of root: URL) -> Bool {
        Self.hasPrefix(
            standardizedFileURL.pathComponents,
            root.standardizedFileURL.pathComponents
        ) { $0 == $1 }
    }

    /// The receiver is below `root`, but is not `root` itself.
    func isStrictDescendant(of root: URL) -> Bool {
        let candidate = standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidate.count > rootComponents.count
            && Self.hasPrefix(candidate, rootComponents) { $0 == $1 }
    }

    /// Like `isSameOrDescendant(of:)`, comparing each component case-insensitively, which
    /// matches how the default APFS volume resolves names.
    func isSameOrDescendantIgnoringCase(of root: URL) -> Bool {
        Self.hasPrefix(
            standardizedFileURL.pathComponents,
            root.standardizedFileURL.pathComponents
        ) { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    private static func hasPrefix(
        _ components: [String],
        _ prefix: [String],
        matches: (String, String) -> Bool
    ) -> Bool {
        guard components.count >= prefix.count else { return false }
        return zip(components, prefix).allSatisfy(matches)
    }
}
