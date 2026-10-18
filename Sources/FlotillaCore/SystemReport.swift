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

    /// The TCP ports something listens on for other Macs, from `netstat -anL -p tcp` — which lists
    /// every listening socket, launchd's and root's included, without admin rights. Loopback-only
    /// listeners (`127.0.0.1.8021`, `::1.8021`) are left out: no other Mac can reach them. Nil when
    /// the output is not that table, so a failed read is not mistaken for "nothing listens".
    ///
    /// This is how a host tells its admin whether Remote Login, Screen Sharing and File Sharing are
    /// on (17 October). Their launchd switches alone miss cases: File Sharing is absent from
    /// `print-disabled` until it has been turned on once, and Remote Management serves screen
    /// sharing through its own agent rather than `com.apple.screensharing`'s switch. All three are
    /// socket-activated, so launchd holds the port whenever the service is on, whichever switch
    /// turned it on — and the port is what the admin's Mac will actually connect to.
    public static func listeningPorts(_ output: String) -> Set<Int>? {
        guard output.contains("Current listen queue sizes") else { return nil }
        var ports: Set<Int> = []
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
            // `0/0/128        *.22`: queue sizes, then the local address with its port after the last dot.
            guard fields.count >= 2, fields[0].contains("/"), let dot = fields[1].lastIndex(of: ".") else { continue }
            let address = fields[1][..<dot]
            guard let port = Int(fields[1][fields[1].index(after: dot)...]) else { continue }
            if address.hasPrefix("127.") || address == "::1" { continue }
            ports.insert(port)
        }
        return ports
    }

    /// Whether a sharing service is on: its port has a listener, when the listeners could be read;
    /// else what its launchd switch says, with a service the list does not name taken as off.
    public static func sharingOn(_ service: RemoteAccess.Service, listening: Set<Int>?, printDisabled: String) -> Bool {
        if let listening { return listening.contains(service.port) }
        return serviceEnabled(service.launchdLabel, in: printDisabled) ?? false
    }

    public static let netstatTool = "/usr/sbin/netstat"
    public static let netstatListenersArguments = ["-anL", "-p", "tcp"]

    /// Remote Login (SSH) and Screen Sharing, by their launchd labels.
    public static let remoteLoginLabel = "com.openssh.sshd"
    public static let screenSharingLabel = "com.apple.screensharing"
    public static let fileSharingLabel = "com.apple.smbd"
}
