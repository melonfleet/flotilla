import Foundation

// The first-run setup assistant (option A, decided 13 October; Iris, `research/FIRST-RUN.md`):
// five steps and a Finish, in a window of their own. What is decided here is the part that can be
// wrong without anyone seeing it — the order, the numbering, which steps may be skipped, what each
// online check contacts, and what Overview's checklist asks of each role — so it lives where it can
// be tested. The window is `SetupAssistantView`.

/// One screen of the assistant, in order.
public enum SetupStep: Int, CaseIterable, Sendable, Comparable {
    case welcome, appearance, greta, prepare, onlineChecks, finish

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The five that count. Finish is where they lead, not a sixth question.
    public static let counted: [SetupStep] = [.welcome, .appearance, .greta, .prepare, .onlineChecks]

    /// The name in the list down the left.
    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Make It Yours"
        case .greta: "Greta"
        case .prepare: "Prepare This Mac"
        case .onlineChecks: "Online Checks"
        case .finish: "Finish"
        }
    }

    /// 1 to 5, or nil for Finish.
    public var number: Int? { Self.counted.firstIndex(of: self).map { $0 + 1 } }

    /// "Step 2 of 5" — and on Finish, no count, because there is nothing left to count.
    public var progressLabel: String {
        guard let number else { return "All set" }
        return "Step \(number) of \(Self.counted.count)"
    }
}

/// Where the assistant has got to. Back keeps what was done; only Continue (or Not now) marks a
/// step done, so the tick in the list means the step was answered, not merely seen.
public struct SetupFlow: Sendable, Equatable {
    public private(set) var step: SetupStep
    public private(set) var done: Set<SetupStep>

    public init(step: SetupStep = .welcome, done: Set<SetupStep> = []) {
        self.step = step
        self.done = done
    }

    public var canGoBack: Bool { step != .welcome }
    public var isFinished: Bool { step == .finish }

    /// Marks this step answered and moves to the next. On Finish it stays put; the window closes.
    public mutating func advance() {
        done.insert(step)
        if let next = SetupStep(rawValue: step.rawValue + 1) { step = next }
    }

    public mutating func goBack() {
        if let previous = SetupStep(rawValue: step.rawValue - 1) { step = previous }
    }
}

/// What this Mac needs before the assistant's Prepare step has anything to offer.
public struct SetupContext: Sendable, Equatable {
    public var role: RunMode
    public var needsContainer: Bool
    public var gretaAvailable: Bool
    public var helperOn: Bool

    public init(role: RunMode, needsContainer: Bool, gretaAvailable: Bool, helperOn: Bool) {
        self.role = role
        self.needsContainer = needsContainer
        self.gretaAvailable = gretaAvailable
        self.helperOn = helperOn
    }

    /// Whether a step offers **Not now** beside Continue. Only where the step's own offer is
    /// optional (Iris): installing `container` on an admin Mac, the helper on a host, and Greta
    /// when she can't run yet. Never a global Skip — that would silently choose a network role.
    ///
    /// A host's Local Network request is not optional, and Not now on its Prepare step still saves
    /// the role: a host that isn't listening isn't a host.
    public func offersNotNow(on step: SetupStep) -> Bool {
        switch step {
        case .greta: !gretaAvailable
        case .prepare: role == .host ? !helperOn : needsContainer
        case .welcome, .appearance, .onlineChecks, .finish: false
        }
    }

    /// The online checks this role is asked about. A host is updated by its admin (Q38), so it has
    /// no Sparkle check to agree to.
    public var onlineChecks: [SetupOnlineCheck] {
        role == .host ? [.suggestionsLibrary] : [.appUpdates, .suggestionsLibrary]
    }
}

/// The two things Flotilla reaches the internet for by itself, each asked separately and each
/// saying exactly what it contacts.
public enum SetupOnlineCheck: String, CaseIterable, Sendable {
    case appUpdates, suggestionsLibrary

    /// The setting each answers. Both default on; setting Sparkle's explicitly also answers the
    /// question Sparkle would otherwise ask at the second launch.
    public var settingName: String {
        switch self {
        case .appUpdates: SettingsKeys.automaticUpdateChecks.name
        case .suggestionsLibrary: SettingsKeys.suggestionLibraryUpdates.name
        }
    }

    public var title: String {
        switch self {
        case .appUpdates: "Check for Flotilla updates automatically"
        case .suggestionsLibrary: "Check daily for new suggestions"
        }
    }

    /// The hosts it contacts, by name.
    public var contacts: [String] {
        switch self {
        case .appUpdates: ["melonfleet.github.io", "github.com"]
        case .suggestionsLibrary: ["raw.githubusercontent.com"]
        }
    }

    public var detail: String {
        switch self {
        case .appUpdates:
            "Reads Flotilla's update feed at melonfleet.github.io once a day. An update you choose to install "
                + "downloads from Flotilla's releases on github.com. The request names Flotilla's version and nothing about this Mac."
        case .suggestionsLibrary:
            "Fetches the suggestions library from raw.githubusercontent.com once a day. The request carries "
                + "nothing about this Mac, and a library is used only if its signature verifies."
        }
    }
}

/// Greta's state as the assistant describes it — `SystemLanguageModel.availability`, mapped by the
/// app (FoundationModels is not Foundation). The wording is Iris's, except `modelNotReady`, which
/// names the language mismatch first as Greta's own message does: macOS reports a Mac whose language
/// differs from Siri's as not ready, and that never clears by itself.
public enum GretaAvailability: Sendable, Equatable {
    case available, appleIntelligenceOff, deviceNotEligible, modelNotReady, unknown

    public var isAvailable: Bool { self == .available }

    /// A short state for Finish's summary.
    public var summary: String {
        switch self {
        case .available: "Ready"
        case .appleIntelligenceOff: "Waiting for Apple Intelligence"
        case .deviceNotEligible: "Not available on this Mac"
        case .modelNotReady: "Waiting for Apple's model"
        case .unknown: "Not available right now"
        }
    }

    public var message: String {
        switch self {
        case .available:
            "Greta is ready. She runs on this Mac, answers questions, and prepares drafts for you to review."
        case .appleIntelligenceOff:
            "Greta needs Apple Intelligence, which is currently off. Turn it on in System Settings; Flotilla will "
                + "notice when it becomes available."
        case .deviceNotEligible:
            "Greta isn't available on this Mac. Flotilla otherwise works normally, and it won't send your questions "
                + "or fleet information to a cloud model."
        case .modelNotReady:
            "Apple's on-device model isn't ready yet. If macOS and Siri use different languages it never will be: "
                + "check System Settings ▸ General ▸ Language & Region, and Apple Intelligence & Siri. Otherwise macOS "
                + "prepares it automatically, and Greta will become available when it is ready."
        case .unknown:
            "Greta isn't available right now. Try again later."
        }
    }

    /// Whether the step offers to open Apple Intelligence & Siri in System Settings.
    public var offersSettings: Bool { self == .appleIntelligenceOff || self == .modelNotReady }
}

/// Overview's Get started card, after the assistant: a checklist that depends on the role
/// (Iris). An admin's first jobs are on this Mac and its hosts; a host's are being found and paired.
public enum GetStartedItem: String, CaseIterable, Sendable {
    case runContainer, addHost, trySuggestion, pairWithAdmin, checkReachable

    public static func items(for role: RunMode) -> [GetStartedItem] {
        switch role {
        case .client: [.runContainer, .addHost, .trySuggestion]
        case .host: [.pairWithAdmin, .checkReachable, .runContainer]
        }
    }

    /// What the app knows that ticks an item.
    public struct Facts: Sendable, Equatable {
        public var containerCount: Int
        public var hostCount: Int
        public var adminCount: Int
        public var listening: Bool

        public init(containerCount: Int, hostCount: Int, adminCount: Int, listening: Bool) {
            self.containerCount = containerCount
            self.hostCount = hostCount
            self.adminCount = adminCount
            self.listening = listening
        }
    }

    /// Whether it is done, or nil when nothing records it — trying a suggestion leaves no trace a
    /// stack started by hand doesn't, so it is never ticked rather than ticked on a guess.
    public func isDone(_ facts: Facts) -> Bool? {
        switch self {
        case .runContainer: facts.containerCount > 0
        case .addHost: facts.hostCount > 0
        case .pairWithAdmin: facts.adminCount > 0
        case .checkReachable: facts.listening
        case .trySuggestion: nil
        }
    }

    /// Whether every item that can be ticked is.
    public static func allDone(for role: RunMode, _ facts: Facts) -> Bool {
        items(for: role).allSatisfy { $0.isDone(facts) ?? true }
    }
}
