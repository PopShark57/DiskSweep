import Foundation
@testable import DiskSweep

/// A cleanup provider for view-model tests. It never touches the filesystem: items point at
/// paths that don't exist, so nothing can be cleaned through it by accident.
struct FakeCleanupProvider: CleanupProvider {
    struct ItemSpec: Sendable {
        let name: String
        let size: Int64
        var isDeletable = true
    }

    let id: String
    let location: CleanupLocation
    let allowedRoots: [URL]
    let itemSpecs: [ItemSpec]
    /// How long `scan` waits before returning. The wait honors cancellation unless
    /// `ignoresCancellation` is set.
    let delay: Duration
    /// When set, `scan` keeps waiting for the whole delay after it is cancelled, the way a
    /// provider in the middle of a slow filesystem call would.
    let ignoresCancellation: Bool
    let events: FakeProviderEvents?

    init(
        id: String,
        location: CleanupLocation,
        allowedRoots: [URL] = [],
        items: [ItemSpec] = [],
        delay: Duration = .zero,
        ignoresCancellation: Bool = false,
        events: FakeProviderEvents? = nil
    ) {
        self.id = id
        self.location = location
        self.allowedRoots = allowedRoots.isEmpty
            ? [URL(fileURLWithPath: "/nonexistent/disksweep-fake/\(id)", isDirectory: true)]
            : allowedRoots
        self.itemSpecs = items
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.events = events
    }

    @concurrent
    func scan(
        context: ScanContext,
        progress: @escaping ScanProgressHandler
    ) async -> ProviderScanResult {
        await events?.started(id)
        if delay > .zero {
            if ignoresCancellation {
                let delay = delay
                await Task.detached { try? await Task.sleep(for: delay) }.value
            } else {
                try? await Task.sleep(for: delay)
            }
        }
        await events?.finished(id)

        let root = allowedRoots[0]
        let items = itemSpecs.map { spec in
            CleanupItem(
                providerID: id,
                location: location,
                name: spec.name,
                url: root.appendingPathComponent(spec.name),
                size: spec.size,
                kind: .file,
                risk: location.risk,
                explanation: "Fake item",
                isDeletable: spec.isDeletable
            )
        }
        return ProviderScanResult(location: location, items: items, issues: [])
    }
}

/// Records the order in which fake providers start and finish.
actor FakeProviderEvents {
    private(set) var log: [String] = []
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func started(_ id: String) {
        log.append("start:\(id)")
        resume("start:\(id)")
    }

    func finished(_ id: String) {
        log.append("finish:\(id)")
        resume("finish:\(id)")
    }

    /// Waits until the given event, such as `start:a`, has happened.
    func wait(for event: String) async {
        if log.contains(event) { return }
        await withCheckedContinuation { continuation in
            waiters.append((event, continuation))
        }
    }

    private func resume(_ event: String) {
        let ready = waiters.filter { $0.0 == event }
        waiters.removeAll { $0.0 == event }
        ready.forEach { $0.1.resume() }
    }
}

/// A one-shot gate a test opens to let an operation continue.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
