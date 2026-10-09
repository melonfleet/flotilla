import Foundation

/// Reading a Mac's own settings from the tools that report them without admin rights, for a host's
/// System tab (the owner, 9 October). Parsing only — the app runs the tools.
public enum SystemReport {

    /// `pmset -g`'s "Currently in use" block: how and when this Mac sleeps.
    public struct PowerSettings: Sendable, Equatable, Codable {
        /// Minutes of idle before the Mac sleeps; 0 is never.
        public var sleepMinutes: Int?
        public var displaySleepMinutes: Int?
        public var diskSleepMinutes: Int?
        /// Power Nap.
        public var powerNap: Bool?
        /// Wake for network access (`womp`).
        public var wakeOnNetwork: Bool?
        /// Start up automatically after a power failure (`autorestart`); absent on most laptops.
        public var autoRestart: Bool?
        /// What is keeping the Mac awake now, as `pmset` names it: `["Claude", "powerd"]`.
        public var sleepPreventedBy: [String]

        public init(sleepMinutes: Int? = nil, displaySleepMinutes: Int? = nil, diskSleepMinutes: Int? = nil,
                    powerNap: Bool? = nil, wakeOnNetwork: Bool? = nil, autoRestart: Bool? = nil,
                    sleepPreventedBy: [String] = []) {
            self.sleepMinutes = sleepMinutes; self.displaySleepMinutes = displaySleepMinutes
            self.diskSleepMinutes = diskSleepMinutes; self.powerNap = powerNap; self.wakeOnNetwork = wakeOnNetwork
            self.autoRestart = autoRestart; self.sleepPreventedBy = sleepPreventedBy
        }

        /// From `pmset -g`. Settings it does not print stay nil.
        public static func parse(_ output: String) -> PowerSettings {
            var settings = PowerSettings()
            for raw in output.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let rest = parts[1].trimmingCharacters(in: .whitespaces)
                let number = Int(rest.prefix { $0.isNumber })
                switch key {
                case "sleep":
                    settings.sleepMinutes = number
                    if let open = rest.range(of: "(sleep prevented by "), let close = rest.range(of: ")", range: open.upperBound..<rest.endIndex) {
                        settings.sleepPreventedBy = rest[open.upperBound..<close.lowerBound]
                            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                case "displaysleep": settings.displaySleepMinutes = number
                case "disksleep": settings.diskSleepMinutes = number
                case "powernap": settings.powerNap = number.map { $0 != 0 }
                case "womp": settings.wakeOnNetwork = number.map { $0 != 0 }
                case "autorestart": settings.autoRestart = number.map { $0 != 0 }
                default: break
                }
            }
            return settings
        }
    }

    /// `launchctl print-disabled system`'s answer for one service: true when it is switched on,
    /// false when off, nil when the list does not name it (macOS's default then applies).
    public static func serviceEnabled(_ label: String, in printDisabled: String) -> Bool? {
        for raw in printDisabled.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"\(label)\"") else { continue }
            if line.hasSuffix("=> enabled") { return true }
            if line.hasSuffix("=> disabled") { return false }
        }
        return nil
    }

    /// Whether the macOS firewall is on, from `socketfilterfw --getglobalstate`: "(State = 1)" is
    /// on, 2 is on and blocking everything, 0 is off. Nil when the output says neither.
    public static func firewallEnabled(_ output: String) -> Bool? {
        guard let range = output.range(of: "(State = ") else { return nil }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        return Int(digits).map { $0 > 0 }
    }

    public static let firewallTool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// Remote Login (SSH) and Screen Sharing, by their launchd labels.
    public static let remoteLoginLabel = "com.openssh.sshd"
    public static let screenSharingLabel = "com.apple.screensharing"
    public static let fileSharingLabel = "com.apple.smbd"
}
