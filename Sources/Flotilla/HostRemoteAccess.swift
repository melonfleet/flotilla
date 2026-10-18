import SwiftUI
import AppKit
import SwiftTerm
import FlotillaCore

/// SSH, Screen Sharing and Files on a host's page (Kamal, 17 October): macOS's own ways into a
/// Mac, in the page's tab pill, each with a dot for whether the host says it is on.
///
/// None of them is Flotilla's: the SSH tab is this Mac's `/usr/bin/ssh`, Screen Sharing is macOS's
/// app at `vnc://`, Files is Finder at `smb://`. Each signs in with the user's own keys or password,
/// in the tool that asks for it; Flotilla never asks for, stores or logs a credential (Q20). A
/// password typed in the SSH tab passes through Flotilla's terminal view on its way to ssh.

extension RemoteAccess.Service {
    /// The name System Settings gives its switch.
    var settingName: String {
        switch self {
        case .ssh: "Remote Login"
        case .screenSharing: "Screen Sharing"
        case .fileSharing: "File Sharing"
        }
    }

    var connectKind: HostConnect.Kind {
        switch self {
        case .ssh: .ssh
        case .screenSharing: .vnc
        case .fileSharing: .smb
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "apple.terminal"
        case .screenSharing: "rectangle.on.rectangle"
        case .fileSharing: "externaldrive.connected.to.line.below"
        }
    }

    /// What it is, in a sentence, for the page that explains it.
    func purpose(_ host: String) -> String {
        switch self {
        case .ssh:
            "Remote Login lets you open a shell on \(host) over SSH. This tab runs this Mac\u{2019}s own ssh, with your own keys, agent and ~/.ssh/config; a password you type goes to ssh through this tab\u{2019}s terminal, and Flotilla doesn\u{2019}t store or log it."
        case .screenSharing:
            "Screen Sharing shows \(host)\u{2019}s screen in macOS\u{2019}s Screen Sharing app, and lets you control it. Remote Management, for Apple Remote Desktop, includes it."
        case .fileSharing:
            "File Sharing lets Finder mount \(host)\u{2019}s shared folders over SMB, signed in as a user on \(host)."
        }
    }

    /// Where its switch is, on the macOS every host runs (26 and later): the same path throughout.
    var steps: [String] {
        switch self {
        case .ssh:
            ["Turn on Remote Login.",
             "Click \u{24D8} beside it to choose who may sign in."]
        case .screenSharing:
            ["Turn on Screen Sharing — or Remote Management, if the Mac is managed with Apple Remote Desktop.",
             "Click \u{24D8} beside it to choose who may share the screen."]
        case .fileSharing:
            ["Turn on File Sharing.",
             "Click \u{24D8} beside it to choose the shared folders and who may connect."]
        }
    }

    var connectTitle: String {
        switch self {
        case .ssh: "Start SSH Session"
        case .screenSharing: "Open Screen Sharing"
        case .fileSharing: "Open in Finder"
        }
    }

    /// Apple's pages for turning it on, as Apple titles them, with where the switch is.
    var guides: [Guide] {
        switch self {
        case .ssh:
            [.init(title: "Allow a remote computer to access your Mac", url: ExternalLinks.appleRemoteLogin,
                   path: "General ▸ Sharing ▸ Remote Login ⓘ")]
        case .screenSharing:
            [.init(title: "Turn Mac screen sharing on or off", url: ExternalLinks.appleScreenSharing,
                   path: "General ▸ Sharing ▸ Screen Sharing ⓘ"),
             .init(title: "Set up Remote Management", url: ExternalLinks.appleRemoteManagement,
                   path: "General ▸ Sharing ▸ Remote Management ⓘ (not at the same time as Screen Sharing)")]
        case .fileSharing:
            [.init(title: "Set up file sharing on Mac", url: ExternalLinks.appleFileSharing,
                   path: "General ▸ Sharing ▸ File Sharing ⓘ"),
             .init(title: "Share files using SMB", url: ExternalLinks.appleFileSharingSMB,
                   path: "File Sharing ⓘ ▸ Options ▸ “Share files and folders using SMB”")]
        }
    }

    struct Guide {
        let title: String
        let url: URL
        let path: String
    }
}

extension RemoteAccess.State {
    var colour: SwiftUI.Color {
        switch self {
        case .on: Theme.online
        case .off: Theme.danger
        case .unknown: SwiftUI.Color.gray
        }
    }

    var value: String {
        switch self {
        case .on: "on"
        case .off: "off"
        case .unknown: "unknown"
        }
    }
}

/// Screen Sharing's and Files' page — what a click shows when the service is off, unknown, or on
/// but with no address yet — and the SSH tab's page in the same states.
struct RemoteAccessPage: View {
    let model: AppModel
    let fingerprint: PeerFingerprint
    let service: RemoteAccess.Service
    let hostName: String
    /// The SSH tab's "Start SSH Session anyway", which opens its own session rather than a URL.
    var connect: (() -> Void)?

    private var state: RemoteAccess.State { RemoteAccess.state(of: service, in: model.hostMode.facts[fingerprint]) }
    private var address: String? { HostConnect.address(model, fingerprint) }

    /// The pill's tooltip for a service in a state.
    static func help(_ service: RemoteAccess.Service, _ state: RemoteAccess.State, hostName: String) -> String {
        switch state {
        case .on: "\(service.settingName) is on at \(hostName)"
        case .off: "\(service.settingName) is off at \(hostName) — click for how to turn it on"
        case .unknown: "\(hostName) hasn\u{2019}t said whether \(service.settingName) is on"
        }
    }

    var body: some View {
        SessionStartPage(systemImage: service.systemImage, title: title, statusColour: state.colour,
                         statusLine: stateLine, purpose: service.purpose(hostName)) {
            if state == .on {
                DetailCard(title: service.connectTitle, minHeight: nil) { actions }
            } else {
                DetailCard(title: "To turn it on, at \(hostName)", minHeight: nil) {
                    step(1, "Open System Settings ▸ General ▸ Sharing\(macOSNote).")
                    ForEach(Array(service.steps.enumerated()), id: \.offset) { index, text in
                        step(index + 2, text)
                    }
                }
                DetailCard(title: "Apple’s instructions", minHeight: nil) {
                    ForEach(service.guides, id: \.url) { guide in
                        VStack(alignment: .leading, spacing: 1) {
                            Button {
                                NSWorkspace.shared.open(guide.url)
                            } label: {
                                Label(guide.title, systemImage: "arrow.up.forward.square")
                                    .foregroundStyle(Theme.link)
                            }
                            .buttonStyle(.link)
                            .help(guide.url.absoluteString)
                            .accessibilityLabel("Apple: \(guide.title)")
                            .accessibilityHint("Opens in your browser")
                            Text(guide.path).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                DetailCard(title: "Already on?", minHeight: nil) { actions }
            }
        }
    }

    private var title: String {
        switch service {
        case .ssh: "SSH"
        case .screenSharing: "Screen Sharing"
        case .fileSharing: "Files"
        }
    }

    private var stateLine: String {
        switch state {
        case .on: "\(service.settingName) is on at \(hostName)."
        case .off: "\(service.settingName) is off at \(hostName)."
        case .unknown: "\(hostName) hasn\u{2019}t said whether \(service.settingName) is on — its Flotilla may be older than this one, or still reading its settings."
        }
    }

    private var macOSNote: String {
        model.hostMode.facts[fingerprint]?.macOSVersion.map { " (it runs macOS \($0))" } ?? ""
    }

    @ViewBuilder
    private var actions: some View {
        if address == nil {
            Label("Flotilla doesn’t have a network address for \(hostName) yet.", systemImage: "network.slash")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            // Off or unknown: still offered, quietly — the report is a port check, and a
            // user's own ssh config may use another port.
            let label = state == .on ? service.connectTitle : "\(service.connectTitle) anyway"
            if state != .on {
                Text("The report is a port check, so you can still try.").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if state == .on {
                    Button(label, action: open).buttonStyle(.borderedProminent)
                } else {
                    Button(label, action: open)
                }
            }
            .accessibilityLabel("\(label) at \(hostName)")
        }
    }

    private func open() {
        if let connect { connect() } else { HostConnect.open(service.connectKind, model, fingerprint) }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(3)
        }
    }
}

/// An SSH session to a host, inside the window, in a real PTY — the container Terminal tab's
/// machinery (`TerminalSessionStore`, `ShellStrip`, `TerminalSurface`) around this Mac's own
/// `/usr/bin/ssh`.
///
/// **The argv is two validated strings.** `RemoteAccess.sshArguments` takes the host's address and
/// the Connect as user, refuses anything that could be an option, a second destination or a shell
/// fragment, and returns `-l <user> <host>`. It runs with no shell between, and nothing else is
/// added. **No credential passes through Flotilla:** ssh asks for a password, if it wants one,
/// inside the terminal — Flotilla's SwiftTerm view, which writes the keystrokes to ssh's PTY and
/// keeps them nowhere (`TerminalSessionStore`); keys and the agent are the user's. Flotilla's transport is not involved, and this session carries no
/// Flotilla command (DECISIONS #2, amended 17 October).
struct HostSSHTab: View {
    let model: AppModel
    let fingerprint: PeerFingerprint
    let hostName: String

    /// How the last thing this tab ran ended: a session, ssh-keygen or ssh-copy-id.
    @State private var outcome: SessionOutcome?
    /// Which of them it was, so the note sits in the card it belongs to.
    @State private var outcomeFromKeySetup = false
    @State private var connectingAnyway = false

    private var store: TerminalSessionStore { model.sshTerminals }
    private var key: String { fingerprint.hex }
    private var state: RemoteAccess.State { RemoteAccess.state(of: .ssh, in: model.hostMode.facts[fingerprint]) }
    private var address: String? { HostConnect.address(model, fingerprint) }
    private var user: String? { HostConnect.user(model, fingerprint) }

    /// The exact argv, or why there is none.
    private var argv: Result<[String], RemoteAccess.ArgumentProblem>? {
        guard let address else { return nil }
        return Result { () throws(RemoteAccess.ArgumentProblem) in try RemoteAccess.sshArguments(host: address, user: user) }
    }

    var body: some View {
        Group {
            if let current = store.current(for: key) {
                // A session already running for this host — ssh, or a key step — is the tab.
                VStack(spacing: 0) {
                    ShellStrip(store: store, subjectID: key, current: current,
                               newShellHelp: "Open another SSH session to \(hostName)", onOpen: openSession)
                    Divider()
                    TerminalSurface(store: store, session: current)
                }
            } else if state != .on && !connectingAnyway {
                RemoteAccessPage(model: model, fingerprint: fingerprint, service: .ssh, hostName: hostName) {
                    connectingAnyway = true
                    openSession()
                }
            } else {
                startPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clicking the tab shows this page and nothing more (Kamal, 18 October): the session starts
        // from its button. What is read on the way in is whether a key exists, read-only.
        .task { await model.sshKeys.refresh() }
    }

    /// No session: what will run, as whom, the button that runs it, and the key help.
    private var startPage: some View {
        SessionStartPage(systemImage: RemoteAccess.Service.ssh.systemImage, title: "SSH",
                         statusColour: state.colour, statusLine: statusLine,
                         purpose: RemoteAccess.Service.ssh.purpose(hostName)) {
            DetailCard(title: "Start SSH Session", minHeight: nil) {
                if let outcome, !outcomeFromKeySetup { SessionOutcomeNote(outcome: outcome) }
                HStack(spacing: 8) {
                    Text("Connect as").font(.callout).foregroundStyle(.secondary)
                    TextField(model.hostMode.facts[fingerprint]?.loginUser ?? NSUserName(), text: connectAs)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 200)
                }
                switch argv {
                case .success(let arguments)?:
                    SessionCommandLine(text: ([RemoteAccess.sshExecutable] + arguments).joined(separator: " "))
                    Text("Uses this Mac\u{2019}s ssh with your own keys, agent and ~/.ssh/config. If \(hostName) asks for a password, it goes to ssh through this terminal; Flotilla doesn\u{2019}t store or log it.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Button("Start SSH Session", action: openSession).buttonStyle(.borderedProminent)
                        .accessibilityLabel("Start SSH Session to \(hostName)")
                case .failure(let problem)?:
                    Label(problem.description, systemImage: "xmark.octagon").font(.callout).foregroundStyle(Theme.danger)
                case nil:
                    Label("Flotilla doesn\u{2019}t have a network address for \(hostName) yet.", systemImage: "network.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SSHKeyCard(keys: model.sshKeys, hostName: hostName,
                       host: validatedHost, user: validatedUser,
                       outcome: outcomeFromKeySetup ? outcome : nil,
                       makeKey: makeKey, copyKey: copyKey, tryIt: openSession)
        }
    }

    private var statusLine: String {
        switch state {
        case .on: "Remote Login is on at \(hostName)."
        case .off: "Remote Login is off at \(hostName), by its report; you chose to try anyway."
        case .unknown: "\(hostName) hasn\u{2019}t said whether Remote Login is on."
        }
    }

    /// The host and user only once `sshArguments` accepted them: the key steps take nothing ssh
    /// itself would not.
    private var validatedHost: String? {
        guard case .success? = argv else { return nil }
        return address
    }

    private var validatedUser: String? {
        guard case .success? = argv, let user, !user.isEmpty else { return nil }
        return user
    }

    private var connectAs: Binding<String> {
        Binding(get: { HostConnect.typedUser(model, fingerprint) },
                set: { HostConnect.setTypedUser($0, model, for: fingerprint) })
    }

    private var environment: [String] {
        RemoteAccess.sshEnvironment(base: SwiftTerm.Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                                    inherited: ProcessInfo.processInfo.environment)
    }

    private func openSession() {
        outcome = nil
        guard let argv else { return }
        switch argv {
        case .failure(let problem):
            show(.problem(problem.description), keySetup: false)
            // Without the value: the error log goes into support bundles.
            model.record("Refused to open SSH to a host: \(problem)", subsystem: "terminal")
        case .success(let arguments):
            let host = hostName
            store.open(containerID: key, executable: RemoteAccess.sshExecutable, argv: arguments,
                       environment: environment) { code, lastLines in
                switch code {
                case nil, 0?: break
                case 255?:
                    // ssh's own code for "could not connect or sign in".
                    show(.problem("ssh couldn\u{2019}t connect to \(host) or sign in.", output: lastLines), keySetup: false)
                case let code?:
                    show(.problem("The session ended with status \(code).", output: lastLines), keySetup: false)
                }
            }
        }
    }

    /// `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519` in this tab's terminal, where it asks for a
    /// passphrase. Only while no default identity exists in `~/.ssh`, private or public — checked
    /// again here rather than trusting a status read before the click.
    private func makeKey() {
        outcome = nil
        let directory = SSHKeyState.sshDirectory
        let status = SSHKeySetup.status(sshDirectory: directory, agent: .unavailable) {
            FileManager.default.fileExists(atPath: $0)
        }
        guard status.canMakeKey else {
            show(.problem(status.pathIsSafe ? "There\u{2019}s already a key in ~/.ssh, so Flotilla won\u{2019}t make another."
                                            : SSHKeySetup.unsafePathExplanation), keySetup: true)
            Task { await model.sshKeys.refresh() }
            return
        }
        let arguments: [String]
        do { arguments = try SSHKeySetup.keygenArguments(sshDirectory: directory) } catch {
            show(.problem(error.description), keySetup: true)
            return
        }
        let session = store.open(containerID: key, executable: SSHKeySetup.keygenExecutable,
                                 argv: arguments, environment: environment) { code, lastLines in
            Task {
                await model.sshKeys.refresh()
                if code == 0, model.sshKeys.status?.keyToCopy != nil {
                    show(.done("Your key is made. Next, put it on \(hostName)."), keySetup: true)
                } else if code == 0 {
                    show(.problem("ssh-keygen finished, but there\u{2019}s no key in the usual place in ~/.ssh — it may have been saved somewhere else.", output: lastLines), keySetup: true)
                } else {
                    show(.problem("ssh-keygen ended without making a key (status \(code.map(String.init) ?? "unknown")).", output: lastLines), keySetup: true)
                }
            }
        }
        store.rename(session, in: key, to: "ssh-keygen")
    }

    /// `ssh-copy-id -i ~/.ssh/<name> [user@]host` in this tab's terminal, where ssh asks for the
    /// host's password once.
    private func copyKey(_ publicKey: String) {
        outcome = nil
        guard let host = validatedHost else { return }
        let user = validatedUser
        let arguments: [String]
        do {
            arguments = try SSHKeySetup.copyIDArguments(sshDirectory: SSHKeyState.sshDirectory, publicKey: publicKey,
                                                        host: host, user: user)
        } catch {
            show(.problem(error.description), keySetup: true)
            model.record("Refused to copy an SSH key to a host: \(error)", subsystem: "terminal")
            return
        }
        let name = hostName
        let session = store.open(containerID: key, executable: SSHKeySetup.copyIDExecutable, argv: arguments,
                                 environment: environment) { code, lastLines in
            if code == 0 {
                model.sshKeys.recordCopied(host: host, user: user)
                show(.done("Your key is on \(name). Try it: the next session should go straight in.", output: lastLines), keySetup: true)
            } else {
                show(.problem("ssh-copy-id couldn\u{2019}t put your key on \(name) (status \(code.map(String.init) ?? "unknown")).", output: lastLines), keySetup: true)
            }
        }
        store.rename(session, in: key, to: "ssh-copy-id")
    }

    private func show(_ value: SessionOutcome, keySetup: Bool) {
        outcome = value
        outcomeFromKeySetup = keySetup
    }
}
