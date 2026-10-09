import AppKit
import FlotillaCore

/// macOS's own ways into a host — SSH in Terminal, VNC in Screen Sharing, SMB in Finder (DECISIONS
/// Q44) — shared by a host's page and the Hosts table's menus, so the two cannot drift.
///
/// Each app is named, so another app that claims the link (Termius, iTerm) is not used, and each
/// link carries a user: the one the admin typed for that host in Connect as, else the one signed in
/// there — an `ssh://host` link alone would use this Mac's user name. A user name, never a password:
/// those stay with Terminal, Screen Sharing and Finder, which offer to keep them in the Keychain.
@MainActor
enum HostConnect {
    enum Kind: CaseIterable {
        case ssh, vnc, smb

        var title: String {
            switch self {
            case .ssh: "Open in Terminal (SSH)"
            case .vnc: "Share Screen (VNC)"
            case .smb: "Connect to File Sharing (SMB)"
            }
        }

        var scheme: String {
            switch self {
            case .ssh: "ssh"
            case .vnc: "vnc"
            case .smb: "smb"
            }
        }

        var app: String {
            switch self {
            case .ssh: "com.apple.Terminal"
            case .vnc: "com.apple.ScreenSharing"
            case .smb: "com.apple.finder"
            }
        }
    }

    /// Where to reach a host: the address the admin connects to, else its own first address.
    static func address(_ model: AppModel, _ fingerprint: PeerFingerprint) -> String? {
        let peer = model.hostMode.hosts.first { $0.fingerprint == fingerprint }
        if case .address(let address, _)? = peer?.endpoint { return address }
        return model.hostMode.facts[fingerprint]?.ipv4Addresses?.first
    }

    // MARK: Connect as

    private static let storeKey = "connectAs"

    private static var overrides: [String: String] {
        get {
            let text = UserDefaults.standard.string(forKey: storeKey) ?? "{}"
            return (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
        }
        set {
            UserDefaults.standard.set((try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? "{}",
                                      forKey: storeKey)
        }
    }

    /// What the admin typed for this host, or "".
    static func typedUser(_ fingerprint: PeerFingerprint) -> String { overrides[fingerprint.hex] ?? "" }

    static func setTypedUser(_ value: String, for fingerprint: PeerFingerprint) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var all = overrides
        all[fingerprint.hex] = trimmed.isEmpty ? nil : trimmed
        overrides = all
    }

    static func user(_ model: AppModel, _ fingerprint: PeerFingerprint) -> String? {
        let typed = typedUser(fingerprint)
        return typed.isEmpty ? model.hostMode.facts[fingerprint]?.loginUser : typed
    }

    // MARK: Open

    /// Opens `scheme://user@address` in that kind's app.
    static func open(_ kind: Kind, _ model: AppModel, _ fingerprint: PeerFingerprint) {
        guard let address = address(model, fingerprint) else { return }
        var components = URLComponents()
        components.scheme = kind.scheme
        components.host = address
        components.user = user(model, fingerprint)
        guard let url = components.url,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.app) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
