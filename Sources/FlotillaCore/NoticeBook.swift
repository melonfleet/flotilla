import Foundation

/// Flotilla's notifications (the owner, 10 October): what needs attention, kept as records with a
/// level, a start, an end and what the owner did about them, so a long list is something to work
/// through rather than a wall on Overview.
///
/// The app hands this book what is wrong **now**, as conditions, every few seconds. The book keeps
/// them as notices:
/// - a new condition starts a notice;
/// - one still present keeps its notice, updated;
/// - one that has gone resolves its notice;
/// - one that returns after resolving is a new notice.
///
/// **Dismiss hides a notice until its situation changes**: a dismissed notice leaves Overview and
/// the menu bar but stays in Notifications. If its condition resolves and later returns, it comes
/// back as a new notice. Errors cannot be dismissed, only dealt with. Resolved and dismissed
/// notices are kept for seven days, and at most 500.
public struct NoticeBook: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        case good, info, warning, error
        private var rank: Int { [.good: 0, .info: 1, .warning: 2, .error: 3][self]! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    /// Something wrong now, as the app reports it.
    public struct Condition: Sendable, Equatable {
        /// Stable while it is the same situation: `host-unreachable:<fingerprint>`.
        public let key: String
        public let level: Level
        public let text: String
        public let host: String?
        public let section: String
        public let dismissible: Bool

        public init(key: String, level: Level, text: String, host: String? = nil, section: String,
                    dismissible: Bool) {
            self.key = key; self.level = level; self.text = text; self.host = host
            self.section = section; self.dismissible = dismissible
        }
    }

    public struct Notice: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let key: String
        public var level: Level
        public var text: String
        public var host: String?
        public var section: String
        public var dismissible: Bool
        public let started: Date
        public var lastSeen: Date
        public var resolved: Date?
        public var dismissed: Date?
        /// When it went to Notification Centre, or nil if it hasn't (Q48).
        public var announced: Date?

        public var isActive: Bool { resolved == nil }
        /// On Overview's banner and in the menu bar: active, not dismissed, a warning or an error.
        public var needsAttention: Bool { isActive && dismissed == nil && level >= .warning }

        /// The part before the first ": " — what the banner and the menu show first.
        public var title: String { Self.split(text).title }
        public var detail: String? { Self.split(text).detail }

        public static func split(_ text: String) -> (title: String, detail: String?) {
            guard let colon = text.range(of: ": ") else { return (text, nil) }
            let detail = String(text[colon.upperBound...])
            return (String(text[..<colon.lowerBound]),
                    detail.isEmpty ? nil : detail.prefix(1).uppercased() + detail.dropFirst())
        }
    }

    public private(set) var notices: [Notice]

    public init(notices: [Notice] = []) { self.notices = notices }

    public static let keepFor: TimeInterval = 7 * 24 * 60 * 60
    public static let maxKept = 500
    /// How stale `lastSeen` may be while its notice is still current.
    public static let lastSeenStep: TimeInterval = 60

    /// Brings the book in line with what is wrong now.
    ///
    /// `unsettled` names the hosts whose state isn't known yet — still being checked, as every
    /// host is just after launch. Their notices are left as they are rather than resolved, or a
    /// relaunch would split each one in two: resolved at launch, started again a few seconds later.
    /// - Returns: the notices this call resolved.
    @discardableResult
    public mutating func reconcile(_ current: [Condition], at now: Date, unsettled: Set<String> = []) -> [Notice] {
        let currentKeys = Set(current.map(\.key))
        var resolved: [Notice] = []
        for condition in current {
            if let index = notices.lastIndex(where: { $0.key == condition.key && $0.isActive }) {
                notices[index].level = condition.level
                notices[index].text = condition.text
                notices[index].host = condition.host
                notices[index].section = condition.section
                notices[index].dismissible = condition.dismissible
                // To the minute: a book that changed every few seconds would be rewritten to disk
                // and redrawn — an open menu included — every few seconds for nothing.
                if now.timeIntervalSince(notices[index].lastSeen) >= Self.lastSeenStep { notices[index].lastSeen = now }
                if !condition.dismissible { notices[index].dismissed = nil }
            } else {
                notices.append(Notice(id: "\(condition.key)@\(Int(now.timeIntervalSince1970 * 1000))",
                                      key: condition.key, level: condition.level, text: condition.text,
                                      host: condition.host, section: condition.section,
                                      dismissible: condition.dismissible, started: now, lastSeen: now,
                                      resolved: nil, dismissed: nil, announced: nil))
            }
        }
        for index in notices.indices where notices[index].isActive && !currentKeys.contains(notices[index].key)
            && !(notices[index].host.map(unsettled.contains) ?? false) {
            notices[index].resolved = now
            resolved.append(notices[index])
        }
        prune(at: now)
        return resolved
    }

    /// Hides each dismissible one until its situation changes. Returns how many were dismissed.
    @discardableResult
    public mutating func dismiss(_ ids: Set<String>, at now: Date) -> Int {
        var count = 0
        for index in notices.indices where ids.contains(notices[index].id)
            && notices[index].dismissible && notices[index].dismissed == nil && notices[index].isActive {
            notices[index].dismissed = now
            count += 1
        }
        return count
    }

    /// Records that these went to Notification Centre.
    public mutating func markAnnounced(_ ids: Set<String>, at now: Date) {
        for index in notices.indices where ids.contains(notices[index].id) && notices[index].announced == nil {
            notices[index].announced = now
        }
    }

    /// Brings a dismissed notice back.
    public mutating func restore(_ ids: Set<String>) {
        for index in notices.indices where ids.contains(notices[index].id) { notices[index].dismissed = nil }
    }

    /// Warnings and errors to deal with: errors first, then the newest.
    public var attention: [Notice] {
        notices.filter(\.needsAttention).sorted { a, b in
            a.level != b.level ? a.level > b.level : a.started > b.started
        }
    }

    /// Drops resolved or dismissed notices older than a week, and the oldest beyond 500. An active
    /// notice that has not been dismissed is never dropped.
    public mutating func prune(at now: Date) {
        notices.removeAll { notice in
            let ended = notice.resolved ?? notice.dismissed
            return ended.map { now.timeIntervalSince($0) > Self.keepFor } ?? false
        }
        if notices.count > Self.maxKept {
            let overflow = notices.count - Self.maxKept
            let droppable = notices.enumerated()
                .filter { !($0.element.isActive && $0.element.dismissed == nil) }
                .sorted { ($0.element.resolved ?? $0.element.dismissed ?? $0.element.started)
                        < ($1.element.resolved ?? $1.element.dismissed ?? $1.element.started) }
                .prefix(overflow).map(\.offset)
            for offset in droppable.sorted(by: >) { notices.remove(at: offset) }
        }
    }
}
