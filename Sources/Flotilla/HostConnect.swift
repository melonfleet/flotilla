import AppKit
import FlotillaCore
import FlotillaNet

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

        /// Apple's instructions for turning it on, and their title as Apple gives it.
        var guide: URL {
            switch self {
            case .ssh: ExternalLinks.appleRemoteLogin
            case .vnc: ExternalLinks.appleScreenSharing
            case .smb: ExternalLinks.appleFileSharing
            }
        }

        var guideTitle: String {
            switch self {
            case .ssh: "Allow a remote computer to access your Mac"
            case .vnc: "Turn Mac screen sharing on or off"
            case .smb: "Set up file sharing on Mac"
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

    /// Where to reach a host — the wire's own rule, with a Bonjour name turned into the host's
    /// `.local` host name (`RemoteAccess.address`), so the SSH tab, Terminal, Screen Sharing and
    /// Finder all go where Flotilla goes.
    static func address(_ model: AppModel, _ fingerprint: PeerFingerprint) -> String? {
        let hostMode = model.hostMode
        let peer = hostMode.hosts.first { $0.fingerprint == fingerprint }
        let advertised = hostMode.discovered.first { $0.fingerprintHint == WireTLS.fingerprintHint(fingerprint) }
        return RemoteAccess.address(advertised: advertised.flatMap { PeerEndpoint($0.endpoint) },
                                    typed: peer?.address, last: peer?.endpoint, facts: hostMode.facts[fingerprint])
    }

    // MARK: Connect as

    /// What the admin typed for this host, or "". Kept with the host in the book (`Peer.connectAs`).
    static func typedUser(_ model: AppModel, _ fingerprint: PeerFingerprint) -> String {
        model.hostMode.hosts.first { $0.fingerprint == fingerprint }?.connectAs ?? ""
    }

    static func setTypedUser(_ value: String, _ model: AppModel, for fingerprint: PeerFingerprint) {
        model.hostMode.setConnectAs(fingerprint, value.trimmingCharacters(in: .whitespaces))
    }

    /// The typed user, else the one signed in there. Nil when neither is known — then ssh decides.
    static func user(_ model: AppModel, _ fingerprint: PeerFingerprint) -> String? {
        let typed = typedUser(model, fingerprint)
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
