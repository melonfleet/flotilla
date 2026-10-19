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
        /// Stopped by the user. Its own state, not a failure: nothing went wrong, so it raises no
        /// notice and does not flag the status item.
        case cancelled

        public var isFinished: Bool { self != .running }
        public var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var title: String
        public let kind: TaskKind
        /// Where it was started: the section, or the Mac it runs on.
        public var origin: String
        public var state: State = .running
        public let startedAt: Date
        public var finishedAt: Date?
        /// The newest thing the task said: an output line, or a running step's detail.
        public var latestLine: String?
        /// The step it is on, for the row's secondary line.
        public var currentStep: String?
        /// How far along, 0...1, for a job that reports it (an image pull does). Not monotonic:
        /// a pull discovers its blob count as it goes. Nil for a job that cannot say.
        public var fraction: Double?
        /// Whether the app holds what Retry would run and what Cancel would stop. The kind says
        /// whether either is *allowed*; this says the call site supplied it.
        public let hasRetryAction: Bool
        public let hasCancelAction: Bool
        /// Cancel was pressed and the child has not ended yet.
        public var cancelRequested = false
        /// Retry has been used: a new task took this one's place.
        public var retried = false

        public init(id: UUID, title: String, kind: TaskKind = .unclassified, origin: String = "",
                    hasRetryAction: Bool = false, hasCancelAction: Bool = false, startedAt: Date) {
            self.id = id
            self.title = title
            self.kind = kind
            self.origin = origin
            self.hasRetryAction = hasRetryAction
            self.hasCancelAction = hasCancelAction
            self.startedAt = startedAt
        }

        /// Cancel is offered while it runs, if its kind allows it, and not twice.
        public var offersCancel: Bool {
            state == .running && kind.canCancel && hasCancelAction && !cancelRequested
        }

        /// Retry is offered on a failed or cancelled job whose kind is safe to repeat, once.
        public var offersRetry: Bool {
            guard kind.canRetry, hasRetryAction, !retried else { return false }
            switch state {
            case .failed, .cancelled: return true
            case .running, .succeeded: return false
            }
        }

        public func elapsed(at now: Date) -> TimeInterval {
            max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
        }
    }

    /// One collapsed row of the drawer's list, as the view draws it.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        public let kind: TaskKind
        public let origin: String
        public let state: State
        public let stateText: String
        public let elapsedText: String
        /// 0...1 while it runs, when the job reports one.
        public let fraction: Double?
        /// Whether this row is the one that just started and is lit for a moment.
        public let isHighlighted: Bool
        /// The short secondary line: the current step, or why it failed.
        public let step: String?
        public let isExpanded: Bool
        public let offersCancel: Bool
        public let isCancelling: Bool
        public let offersRetry: Bool
    }

    /// Where the drawer is: down in the status bar, or up showing the list. One list, always —
    /// a job's steps and output are its row opened, not a different screen.
    public enum Drawer: Equatable, Sendable {
        case hidden
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
    /// Failures that arrived while the drawer was up. Until it goes down, or they are retried or
    /// cleared, it stays up: a later success elsewhere must not sink a failure nobody has dealt with.
    public private(set) var failuresInView: Set<UUID> = []
    /// Rows opened in the list. Kept here, not in the view: the drawer is rebuilt when it is
    /// minimised and raised, and an open row must stay open while lines arrive and after.
    public private(set) var expanded: Set<UUID> = []
    /// A row the list should scroll to; the view clears it once it has.
    public private(set) var revealed: UUID?
    /// The job that just started, lit for a moment so the eye finds its row; the owner clears it.
    public private(set) var highlighted: UUID?
    /// Whether the drawer is up because the user asked for it (the status item, ⌥⌘T, a notice's
    /// button) rather than because a job started. Only the first takes keyboard focus, so Esc
    /// reaches the drawer when it was asked for and a form the user is typing in keeps its focus
    /// when a job merely starts. Kept here, not inferred from the highlight: a reopen during the
    /// highlight is still a reopen.
    public private(set) var openedByUser = false
    /// Whether the folded "N finished" line is open onto the finished rows.
    public private(set) var finishedExpanded = false

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
    public var finishedCount: Int { entries.filter(\.state.isFinished).count }
    public var failedCount: Int { entries.filter(\.state.isFailure).count }

    public func runningRows(at now: Date) -> [Row] {
        ordered.filter { !$0.state.isFinished }.map { row($0, at: now) }
    }

    public func finishedRows(at now: Date) -> [Row] {
        ordered.filter(\.state.isFinished).map { row($0, at: now) }
    }

    // MARK: - Changes

    /// A new job: it goes in the list, collapsed, and the drawer rises on it.
    public mutating func start(_ id: UUID, title: String, kind: TaskKind = .unclassified, origin: String = "",
                               hasRetryAction: Bool = false, hasCancelAction: Bool = false, at now: Date) {
        guard entry(id) == nil else { return }
        entries.append(Entry(id: id, title: title, kind: kind, origin: origin,
                             hasRetryAction: hasRetryAction, hasCancelAction: hasCancelAction, startedAt: now))
        if drawer == .hidden { openedByUser = false }
        drawer = .list
        highlighted = id
    }

    public mutating func clearHighlight(_ id: UUID) { if highlighted == id { highlighted = nil } }

    /// Clamped to 0...1; nil leaves the last figure standing, since a pull's lines without a
    /// percentage are not a step backwards.
    public mutating func setFraction(_ fraction: Double?, for id: UUID) {
        guard let fraction, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].fraction = min(1, max(0, fraction))
    }

    public mutating func setStep(_ step: String?, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = step?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].currentStep = (trimmed?.isEmpty ?? true) ? nil : trimmed
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
        entries[index].cancelRequested = false
        // Collapsed rows stay collapsed (the caret is the only way in); a failure flags its row, which
        // carries the reason as its secondary line. With the drawer down, the status item is flagged.
        if drawer == .hidden { unseenFailures.insert(id) } else { failuresInView.insert(id) }
        return trim()
    }

    /// Asks to stop a task. Nothing changes state yet: the child has to end first, and then
    /// `cancel` records it.
    /// - Returns: whether Cancel was allowed — the caller stops the process only if so.
    @discardableResult
    public mutating func requestCancel(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].offersCancel else { return false }
        entries[index].cancelRequested = true
        return true
    }

    /// Marks a task cancelled: it ended because it was stopped. Not a failure.
    @discardableResult
    public mutating func cancel(_ id: UUID, at now: Date) -> [UUID] {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].state.isFinished
        else { return [] }
        entries[index].state = .cancelled
        entries[index].finishedAt = now
        entries[index].cancelRequested = false
        return trim()
    }

    /// Claims Retry for `id`: it is not offered again and the failure notice goes.
    /// - Returns: whether Retry was offered, so a double click starts one job, not two.
    @discardableResult
    public mutating func retry(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].offersRetry else { return false }
        entries[index].retried = true
        return true
    }

    public mutating func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Opens the list on one task, expanded and scrolled to — where a failure notice's button goes.
    public mutating func reveal(_ id: UUID) {
        guard let target = entry(id) else { return }
        openedByUser = true
        drawer = .list
        if target.state.isFinished { finishedExpanded = true }
        expanded.insert(id)
        revealed = id
        unseenFailures.remove(id)
    }

    public mutating func clearReveal() { revealed = nil }

    /// Whether the drawer should sink by itself now that a job has ended (Kamal, 19 October): it is
    /// up, nothing is still running, the job that ended didn't fail, no failure since it rose is
    /// still waiting (a failure is the one thing to see, so it stays up — however many jobs succeed
    /// after it), and no row is open (someone is reading its output).
    public func shouldAutoMinimise(after ended: UUID) -> Bool {
        guard drawer != .hidden, runningCount == 0, expanded.isEmpty,
              let entry = entry(ended), entry.state.isFinished, !entry.state.isFailure else { return false }
        let waiting = failuresInView.contains { id in
            self.entry(id).map { $0.state.isFailure && !$0.retried } ?? false
        }
        return !waiting
    }

    /// How long a finished drawer stays up before it sinks, so the finish is seen.
    public static let autoMinimiseDelay: TimeInterval = 2

    /// Sinks the drawer into the status item. Nothing is cancelled.
    public mutating func minimise() {
        drawer = .hidden
        openedByUser = false
        failuresInView = []   // put away by hand: seen
    }

    /// Opens or folds the "N finished" line.
    public mutating func toggleFinished() { finishedExpanded.toggle() }

    /// The status item's click: the list if the drawer is down or on one task, down if it is the
    /// list already. Opening it is seeing every failure in it.
    public mutating func toggleList() {
        if drawer == .list {
            minimise()
        } else {
            drawer = .list
            openedByUser = true
            unseenFailures = []
        }
    }

    public mutating func showList() {
        drawer = .list
        openedByUser = true
        unseenFailures = []
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

    // MARK: - Layout

    /// The drawer's width: half the content area, never narrower than a row needs, and never wider
    /// than the area itself — in a narrow window it takes the whole of it.
    public static func drawerWidth(in available: Double, minimum: Double) -> Double {
        guard available > 0 else { return minimum }
        return min(available, max(minimum, (available / 2).rounded()))
    }

    // MARK: - Rows

    public func rows(at now: Date) -> [Row] { ordered.map { row($0, at: now) } }

    public func row(_ entry: Entry, at now: Date) -> Row {
        let step: String? = switch entry.state {
        case .failed(let reason): Self.firstLine(reason) ?? entry.currentStep
        default: entry.currentStep
        }
        return Row(id: entry.id, title: entry.title, kind: entry.kind, origin: entry.origin, state: entry.state,
                   stateText: Self.stateText(entry), elapsedText: Self.elapsedText(entry.elapsed(at: now)),
                   fraction: entry.state == .running ? entry.fraction : nil,
                   isHighlighted: highlighted == entry.id, step: step, isExpanded: expanded.contains(entry.id), offersCancel: entry.offersCancel,
                   isCancelling: entry.cancelRequested && entry.state == .running, offersRetry: entry.offersRetry)
    }

    public static func stateText(_ entry: Entry) -> String {
        switch entry.state {
        case .running: entry.cancelRequested ? "Cancelling" : "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    /// `12s`, `3m 05s`, `1h 02m` — short enough for a row.
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m " + String(format: "%02d", total % 60) + "s" }
        return "\(total / 3600)h " + String(format: "%02d", (total % 3600) / 60) + "m"
    }

    /// The first non-empty line, cut to a length a row can hold.
    public static func firstLine(_ text: String, limit: Int = 140) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }

    // MARK: - Failure notices

    /// A failed job as a notice (`NoticeBook`): the key stays the same for that task and no other.
    public struct FailureNotice: Equatable, Sendable {
        public let task: UUID
        public let key: String
        public let level: NoticeBook.Level
        public let text: String
    }

    public static let noticeKeyPrefix = "task-failed"

    public static func noticeKey(for id: UUID) -> String { "\(noticeKeyPrefix):\(id.uuidString)" }

    public static func task(fromNoticeKey key: String) -> UUID? {
        guard key.hasPrefix(noticeKeyPrefix + ":") else { return nil }
        return UUID(uuidString: String(key.dropFirst(noticeKeyPrefix.count + 1)))
    }

    /// A job that cannot be repeated may have half-applied, so it is an error; one that can is a
    /// warning — Retry is the fix.
    public static func noticeLevel(for kind: TaskKind) -> NoticeBook.Level {
        kind.canRetry ? .warning : .error
    }

    /// "Pull grafana/grafana:13 failed: <why>". The text before the first ": " is what the banner
    /// and Notification Centre lead with; the reason, one line of it, is the detail.
    public static func noticeText(title: String, reason: String) -> String {
        guard let why = firstLine(reason) else { return "\(title) failed" }
        return "\(title) failed: \(why)"
    }

    /// One notice per task that failed and has not been retried or cleared. Retrying or clearing
    /// takes it out of this list, which is what ends the notice.
    public var failureNotices: [FailureNotice] {
        entries.compactMap { entry in
            guard case .failed(let reason) = entry.state, !entry.retried else { return nil }
            return FailureNotice(task: entry.id, key: Self.noticeKey(for: entry.id),
                                 level: Self.noticeLevel(for: entry.kind),
                                 text: Self.noticeText(title: entry.title, reason: reason))
        }
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

    /// The figure the compact status item shows beside the count: the percentage of the newest
    /// running job when it reports one, otherwise how long it has been going.
    public func leadingFigure(at now: Date) -> String? {
        guard let newest = entries.filter({ !$0.state.isFinished }).max(by: { $0.startedAt < $1.startedAt })
        else { return nil }
        if let fraction = newest.fraction { return "\(Int((fraction * 100).rounded()))%" }
        return Self.elapsedText(newest.elapsed(at: now))
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
        if !hasFinished { finishedExpanded = false }
        for id in ids {
            unseenFailures.remove(id)
            failuresInView.remove(id)
            expanded.remove(id)
            if revealed == id { revealed = nil }
            if highlighted == id { highlighted = nil }
        }
    }
}
