import Foundation

/// What a host's System tab recommends about its Energy settings (the owner, 10 October; Iris's
/// power research, DECISIONS Q44). Recommended, never changed: Flotilla does not touch Energy
/// settings, and a remote admin cannot. Shown quietly on every Mac's System tab — not an attention
/// item.
public enum EnergyAdvice {
    public enum State: Sendable, Equatable { case good, recommended, unknown }

    /// Which Apple guide explains the setting.
    public enum Guide: String, Sendable, Equatable {
        case energyDesktop, batteryLaptop, wakeForNetwork, loginItems, autoLogin, fileVault
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let state: State
        /// Why, when it is not as recommended — or what the setting is for.
        public let detail: String?
        public let guide: Guide
    }

    public struct Inputs: Sendable, Equatable {
        public var power: SystemReport.PowerSettings?
        public var hasBattery: Bool?
        public var fileVault: Bool?
        public var autoLogin: Bool?
        public var launchesAtLogin: Bool?

        public init(power: SystemReport.PowerSettings? = nil, hasBattery: Bool? = nil, fileVault: Bool? = nil,
                    autoLogin: Bool? = nil, launchesAtLogin: Bool? = nil) {
            self.power = power; self.hasBattery = hasBattery; self.fileVault = fileVault
            self.autoLogin = autoLogin; self.launchesAtLogin = launchesAtLogin
        }
    }

    public static func items(_ inputs: Inputs) -> [Item] {
        let laptop = inputs.hasBattery == true
        var items: [Item] = []

        let sleep = inputs.power?.sleepMinutes
        items.append(Item(
            id: "sleep",
            title: laptop ? "Don't sleep on the power adapter when the display is off" : "Don't sleep when the display is off",
            state: sleep.map { $0 == 0 ? .good : .recommended } ?? .unknown,
            detail: sleep.flatMap { $0 == 0 ? nil
                : "Sleeps after \($0) min idle. Flotilla keeps a host awake while it runs, but not when Flotilla isn't open." },
            guide: laptop ? .batteryLaptop : .energyDesktop))

        let wake = inputs.power?.wakeOnNetwork
        items.append(Item(
            id: "wake", title: "Wake for network access",
            state: wake.map { $0 ? .good : .recommended } ?? .unknown,
            detail: "Helps the Mac answer after it sleeps; not a guarantee it will.",
            guide: .wakeForNetwork))

        // Desktops only: a laptop has a battery to ride out a power cut, and no such setting.
        if !laptop {
            let restart = inputs.power?.autoRestart
            items.append(Item(
                id: "restart", title: "Start up automatically after a power failure",
                state: restart.map { $0 ? .good : .recommended } ?? .unknown,
                detail: nil, guide: .energyDesktop))
        }

        let login = inputs.launchesAtLogin
        items.append(Item(
            id: "login", title: "Open Flotilla at login",
            state: login.map { $0 ? .good : .recommended } ?? .unknown,
            detail: login == false ? "Settings ▸ General ▸ Launch at login." : nil,
            guide: .loginItems))
        return items
    }

    /// The warning beside the recommendations: after a power cut or restart the Mac waits at the
    /// login screen — FileVault on, or automatic login off — so Flotilla, which runs in someone's
    /// session, does not start until someone signs in. Nil when automatic login would bring it back,
    /// or when it cannot be told.
    public static func restartWarning(_ inputs: Inputs) -> (text: String, guide: Guide)? {
        if inputs.fileVault == true {
            return ("FileVault is on, so after a restart or power cut this Mac waits at the login screen, and Flotilla "
                    + "won't start until someone signs in.", .fileVault)
        }
        if inputs.autoLogin == false {
            return ("Automatic login is off, so after a restart or power cut this Mac waits at the login screen, and "
                    + "Flotilla won't start until someone signs in.", .autoLogin)
        }
        return nil
    }
}
