import Foundation

// What the Flotilla Helper is doing, said in one place (DECISIONS Q41, amended 19 October).
//
// The app can read two things about the helper: whether macOS has it registered and approved
// (`HelperRegistration`), and whether a running copy answers (`HelperProbe`). Neither alone says
// whether it works — "approved" was all Settings knew, so a helper that macOS had switched on but
// that never replied looked identical to a healthy one. This is pure, so every state, its wording
// and the buttons it offers are pinned on Linux; the macOS-only code just feeds it.

/// What macOS says about the helper's registration.
public enum HelperRegistration: Sendable, Equatable {
    /// This build is not Developer ID signed, so the helper would refuse it and it the helper.
    case unavailable
    case notInstalled
    /// Registered, waiting for the owner to switch it on in Login Items.
    case awaitingApproval
    case enabled
}

/// What asking a running helper for its version came to.
public enum HelperProbe: Sendable, Equatable {
    case notAsked
    case answered(version: Int)
    case silent
}

public enum HelperHealth: Sendable, Equatable {
    case unavailable
    case notInstalled
    case needsApproval
    /// Approved, and the first probe has not come back.
    case checking
    case notAnswering
    case outOfDate(running: Int, current: Int)
    case running(version: Int)

    public enum Tone: Sendable, Equatable { case good, warning, bad, neutral }

    /// Everything a menu or a settings row may offer. Which of these show is `actions`.
    public enum Action: Sendable, Equatable { case install, remove, restart, reinstall, openLoginItems }

    /// `current` is `HelperInterface.version` — passed in because that module is macOS-only.
    public static func derive(registration: HelperRegistration, probe: HelperProbe, current: Int) -> HelperHealth {
        switch registration {
        case .unavailable: return .unavailable
        case .notInstalled: return .notInstalled
        case .awaitingApproval: return .needsApproval
        case .enabled:
            switch probe {
            case .notAsked: return .checking
            case .silent: return .notAnswering
            case .answered(let version): return version < current ? .outOfDate(running: version, current: current)
                                                                   : .running(version: version)
            }
        }
    }

    public var title: String {
        switch self {
        case .unavailable: "Not available in this build"
        case .notInstalled: "Not installed"
        case .needsApproval: "Needs your approval"
        case .checking: "Checking…"
        case .notAnswering: "Approved but not answering"
        case .outOfDate: "Out of date"
        case .running(let version): "Running (version \(version))"
        }
    }

    /// One plain sentence under the title.
    public var explanation: String {
        switch self {
        case .unavailable:
            "Only a signed copy of Flotilla can use the background service. Creating or deleting a DNS "
                + "domain asks for an administrator password instead."
        case .notInstalled:
            "Flotilla's background service for jobs that need administrator rights: DNS domains and names "
                + "across Macs, installing Apple's container, and installing Flotilla updates on a host. "
                + "Install it and approve it once in Login Items."
        case .needsApproval:
            "Switch on Flotilla in System Settings ▸ General ▸ Login Items & Extensions. Until then, DNS "
                + "changes ask for an administrator password and a host can't do these jobs."
        case .checking:
            "Asking the background service for its version."
        case .notAnswering:
            "macOS has it switched on, but it isn't replying. Restart it; if that doesn't help, reinstall it."
        case .outOfDate(let running, let current):
            "The running copy is version \(running); this Flotilla needs \(current). Restart it to start the "
                + "new one."
        case .running:
            "It runs the jobs that need administrator rights. Flotilla still asks you to confirm each change."
        }
    }

    public var tone: Tone {
        switch self {
        case .running: .good
        case .outOfDate, .notAnswering, .needsApproval: .warning
        case .notInstalled: .bad
        case .unavailable, .checking: .neutral
        }
    }

    /// In the order they should be drawn. Install and Remove never appear together.
    public var actions: [Action] {
        switch self {
        case .unavailable, .checking: []
        case .notInstalled: [.install]
        case .needsApproval: [.openLoginItems, .remove]
        case .notAnswering: [.restart, .reinstall, .remove]
        case .outOfDate, .running: [.restart, .remove]
        }
    }

    /// Whether DNS changes, container installs and host updates can go through it right now.
    public var isUsable: Bool {
        if case .running = self { return true }
        return false
    }
}

/// The two small policies around installing it by itself.
public enum HelperAutoRegister {
    /// A signed build whose helper is not installed registers it at launch — unless the owner pressed
    /// Remove, which stays removed until they press Install.
    public static func shouldRegister(registration: HelperRegistration, removedByOwner: Bool) -> Bool {
        registration == .notInstalled && !removedByOwner
    }
}

/// How long a probe's answer is trusted. Probing starts the daemon if it is not running, so it is
/// asked when something is shown, never on a timer.
public enum HelperProbeCache {
    public static let lifetime: TimeInterval = 30

    public static func isFresh(lastProbe: Date?, now: Date, lifetime: TimeInterval = HelperProbeCache.lifetime) -> Bool {
        guard let lastProbe else { return false }
        let age = now.timeIntervalSince(lastProbe)
        return age >= 0 && age < lifetime
    }
}
