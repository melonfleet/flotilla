import Foundation

/// The window's long-running jobs — pulls, builds, sends, pushes — and where the Tasks drawer is
/// (Q63, Kamal, 19 October). Pure value; the app's `TaskCenter` owns the live progress objects and
/// the clock, and asks this what to show.
///
/// It replaced a single "active operation" slot behind a centred sheet. That slot was the bug: Hide
/// set it to nil, so the job kept running while its output went nowhere, and a second job took the
/// slot from the first. Here every task keeps its own entry, by identity, until it is cleared or
/// ages out of the finished list.
public struct TaskBoard: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)

        public var isFinished: Bool { self != .running }
        public var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var title: String
        public var state: State = .running
        public let startedAt: Date
        public var finishedAt: Date?
        /// The newest thing the task said: an output line, or a running step's detail.
        public var latestLine: String?

        public init(id: UUID, title: String, startedAt: Date) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
        }
    }

    /// Where the drawer is. `.task` shows one task's steps and output; `.list` every task.
    public enum Drawer: Equatable, Sendable {
        case hidden
        case task(UUID)
        case list
    }

    /// What the status bar's Tasks item says.
    public enum Headline: Equatable, Sendable {
        /// Nothing to report: the word "Tasks" and no count.
        case quiet
        /// `count` running; `line` is the newest line of the most recently started one.
        case running(count: Int, line: String)
        /// Flagged until the drawer is opened.
        case failed(title: String)
        /// Briefly, after a success.
        case finished(title: String)

        public var text: String {
            switch self {
            case .quiet: "Tasks"
            case .running(_, let line): line
            case .failed(let title): "\(title) failed"
            case .finished(let title): "\(title) finished"
            }
        }
    }

    /// Finished tasks kept for the session's list. Running ones are never dropped.
    public static let finishedLimit = 20
    /// How long "<title> finished" stays on the item.
    public static let finishedFlash: TimeInterval = 4

    public private(set) var entries: [Entry] = []
    public private(set) var drawer: Drawer = .hidden
    /// Failures nobody has seen yet: they arrived while the drawer was down.
    public private(set) var unseenFailures: Set<UUID> = []

    public init() {}

    public func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    /// Running first, newest started first; then finished, newest finished first.
    public var ordered: [Entry] {
        let running = entries.filter { !$0.state.isFinished }.sorted { $0.startedAt > $1.startedAt }
        let finished = entries.filter(\.state.isFinished)
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        return running + finished
    }

    public var runningCount: Int { entries.filter { !$0.state.isFinished }.count }
    public var hasFinished: Bool { entries.contains { $0.state.isFinished } }

    // MARK: - Changes

    /// A new job: it goes in the list and the drawer rises on it.
    public mutating func start(_ id: UUID, title: String, at now: Date) {
        guard entry(id) == nil else { return }
        entries.append(Entry(id: id, title: title, startedAt: now))
        drawer = .task(id)
    }

    public mutating func setLine(_ line: String?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].latestLine = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Marks a task done. The drawer stays where the user left it.
    /// - Returns: ids dropped by the retention cap, so the owner can release them.
    @discardableResult
    public mutating func succeed(_ id: UUID, at now: Date) -> [UUID] {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].state.isFinished
        else { return [] }
        entries[index].state = .succeeded
        entries[index].finishedAt = now
        return trim()
    }

    /// Marks a task failed. With the drawer up it turns to the failure; with it down, the item is
    /// flagged until the drawer is opened.
    @discardableResult
    public mutating func fail(_ id: UUID, reason: String, at now: Date) -> [UUID] {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].state.isFinished
        else { return [] }
        entries[index].state = .failed(reason)
        entries[index].finishedAt = now
        if drawer == .hidden {
            unseenFailures.insert(id)
        } else {
            drawer = .task(id)
        }
        return trim()
    }

    /// Sinks the drawer into the status item. Nothing is cancelled.
    public mutating func minimise() { drawer = .hidden }

    /// The status item's click: the list if the drawer is down or on one task, down if it is the
    /// list already. Opening it is seeing every failure in it.
    public mutating func toggleList() {
        if drawer == .list {
            drawer = .hidden
        } else {
            drawer = .list
            unseenFailures = []
        }
    }

    public mutating func showList() {
        drawer = .list
        unseenFailures = []
    }

    public mutating func show(_ id: UUID) {
        guard entry(id) != nil else { return }
        drawer = .task(id)
        unseenFailures.remove(id)
    }

    /// Removes a finished task. A running one cannot be cleared: it is still doing something.
    /// - Returns: whether it was removed.
    @discardableResult
    public mutating func clear(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state.isFinished
        else { return false }
        entries.remove(at: index)
        forget([id])
        return true
    }

    /// - Returns: the ids removed.
    @discardableResult
    public mutating func clearFinished() -> [UUID] {
        let gone = entries.filter(\.state.isFinished).map(\.id)
        entries.removeAll { $0.state.isFinished }
        forget(gone)
        return gone
    }

    // MARK: - The status item

    public func headline(at now: Date) -> Headline {
        let running = entries.filter { !$0.state.isFinished }
        if let newest = running.max(by: { $0.startedAt < $1.startedAt }) {
            return .running(count: running.count, line: newest.latestLine ?? newest.title)
        }
        if let failed = entries.filter({ unseenFailures.contains($0.id) })
            .max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }) {
            return .failed(title: failed.title)
        }
        if let done = flashing(at: now) { return .finished(title: done.title) }
        return .quiet
    }

    /// When the "finished" flash ends, if one is showing — so the owner knows when to look again.
    public func flashEnds(at now: Date) -> Date? {
        flashing(at: now).flatMap(\.finishedAt).map { $0.addingTimeInterval(Self.finishedFlash) }
    }

    private func flashing(at now: Date) -> Entry? {
        entries.filter { entry in
            guard entry.state == .succeeded, let finished = entry.finishedAt else { return false }
            return now < finished.addingTimeInterval(Self.finishedFlash)
        }
        .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    // MARK: -

    private mutating func trim() -> [UUID] {
        let finished = entries.filter(\.state.isFinished)
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        guard finished.count > Self.finishedLimit else { return [] }
        let gone = finished.dropFirst(Self.finishedLimit).map(\.id)
        entries.removeAll { gone.contains($0.id) }
        forget(gone)
        return gone
    }

    private mutating func forget(_ ids: [UUID]) {
        for id in ids {
            unseenFailures.remove(id)
            if drawer == .task(id) { drawer = entries.isEmpty ? .hidden : .list }
        }
    }
}
