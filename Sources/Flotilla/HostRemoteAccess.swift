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
/// **The argv is two validated strings, and Flotilla's key when it has one.**
/// `RemoteAccess.sshArguments` takes the host's address and the Connect as user, refuses anything
/// that could be an option, a second destination or a shell fragment, and returns `-l <user> <host>`
/// — with `-i ~/.ssh/flotilla_ed25519 -o IdentitiesOnly=yes` in front while that key exists, checked
/// when the button is clicked. It runs with no shell between, and nothing else is added. **No
/// credential passes through Flotilla:** ssh asks for a password, if it wants one, inside the
/// terminal — Flotilla's SwiftTerm view, which writes the keystrokes to ssh's PTY and keeps them
/// nowhere (`TerminalSessionStore`); the user's own keys and agent are theirs. Flotilla's transport
/// is not involved, and this session carries no Flotilla command (DECISIONS #2, amended 17 October).
struct HostSSHTab: View {
    let model: AppModel
    let fingerprint: PeerFingerprint
    let hostName: String

    /// How the last thing this tab ran ended: a session, or a key step.
    @State private var outcome: SessionOutcome?
    /// Which of them it was, so the note sits in the card it belongs to.
    @State private var outcomeFromKeySetup = false
    @State private var connectingAnyway = false

    private var store: TerminalSessionStore { model.sshTerminals }
    private var keys: SSHKeyState { model.sshKeys }
    private var key: String { fingerprint.hex }
    private var state: RemoteAccess.State { RemoteAccess.state(of: .ssh, in: model.hostMode.facts[fingerprint]) }
    private var address: String? { HostConnect.address(model, fingerprint) }
    private var user: String? { HostConnect.user(model, fingerprint) }
    private var sshDirectory: String { SSHKeyState.sshDirectory }

    /// Flotilla's key, if its private half exists now: one `stat`.
    private var identity: SSHKeySetup.Identity? {
        .present(sshDirectory: sshDirectory) { FileManager.default.fileExists(atPath: $0) }
    }

    /// The exact argv, or why there is none.
    private var argv: Result<[String], RemoteAccess.ArgumentProblem>? {
        guard let address else { return nil }
        let identity = identity
        return Result { () throws(RemoteAccess.ArgumentProblem) in
            try RemoteAccess.sshArguments(host: address, user: user, identity: identity)
        }
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
        // from its button. What is read on the way in is which keys exist, read-only.
        .task { await keys.refresh() }
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
                    SessionCommandLine(text: homeAbbreviated(([RemoteAccess.sshExecutable] + arguments).joined(separator: " ")))
                    Text(arguments.first == "-i"
                         ? "Uses this Mac\u{2019}s ssh with Flotilla\u{2019}s key and your ~/.ssh/config. If \(hostName) asks for a password, it goes to ssh through this terminal; Flotilla doesn\u{2019}t store or log it."
                         : "Uses this Mac\u{2019}s ssh with your own keys, agent and ~/.ssh/config. If \(hostName) asks for a password, it goes to ssh through this terminal; Flotilla doesn\u{2019}t store or log it.")
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
            SSHKeyCard(keys: keys, hostName: hostName, hostKey: key,
                       host: validatedHost, user: validatedUser,
                       busyElsewhere: keys.running(otherThan: key),
                       outcome: outcomeFromKeySetup ? outcome : nil,
                       actions: SSHKeyActions(
                           makeKey: makeKey, copyKey: copyKey, tryIt: openSession,
                           archiveName: archiveName, regenerate: regenerate, removeFromHost: removeFromHost,
                           copyToOtherHost: copyToOtherHost, hostName: otherHostName))
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

    // MARK: Make, copy

    /// `ssh-keygen -t ed25519 -C flotilla -f ~/.ssh/flotilla_ed25519` in this tab's terminal, where
    /// it asks for a passphrase. Only while neither half of Flotilla's key exists — checked again
    /// here rather than trusting a status read before the click. The user's own keys are other files.
    private func makeKey() {
        outcome = nil
        guard let op = beginKeyOperation() else { return }
        let status = SSHKeyState.files()
        guard status.canMakeKey else {
            keys.end(op)
            show(.problem(status.pathIsSafe ? "Flotilla already has a key in ~/.ssh, so it won\u{2019}t make another. Use Regenerate Key to replace it."
                                            : SSHKeySetup.unsafePathExplanation), keySetup: true)
            Task { await keys.refresh() }
            return
        }
        runKeygen(op, snapshot: nil, stopped: "ssh-keygen was closed before it finished.") { made, _, code, lastLines in
            keys.end(op)
            if made {
                show(.done("Flotilla\u{2019}s key is made. Next, put it on \(hostName).", output: lastLines), keySetup: true)
            } else {
                show(.problem("ssh-keygen ended without making Flotilla\u{2019}s key (status \(code.map(String.init) ?? "unknown")).", output: lastLines), keySetup: true)
            }
        }
    }

    // MARK: The key lock

    /// The app-wide key lock for this host's step, or nil — having said which host has it — while
    /// any key step runs anywhere (Kyle, 18 October). Every key step takes it, and whoever ends the
    /// step releases it: its last callback, a refusal before anything ran, or `stopped`.
    private func beginKeyOperation() -> UUID? {
        if let op = keys.begin(host: key, hostName: hostName) { return op }
        show(.problem("Key setup is running for \(keys.running(otherThan: key) ?? hostName). Finish or close it there first."), keySetup: true)
        return nil
    }

    /// A key step's session closed before it ended: the lock goes, and the page says what that left.
    private func stopped(_ op: UUID, _ message: String) -> () -> Void {
        { [keys] in
            keys.end(op)
            show(.problem(message), keySetup: true)
            Task { await keys.refresh() }
        }
    }

    /// Runs ssh-keygen for Flotilla's key, then says whether both halves are there now. With a
    /// `snapshot` (Regenerate), what ssh-keygen left at Flotilla's paths is read the moment it exits,
    /// while the lock still keeps every other key step out, and handed on for the rollback.
    private func runKeygen(_ op: UUID, snapshot: SSHKeySetup.KeygenSnapshot?, stopped message: String,
                           then: @escaping (_ made: Bool, _ output: SSHKeySetup.KeygenOutput?, _ code: Int32?, _ lastLines: String) -> Void) {
        let arguments: [String]
        do { arguments = try SSHKeySetup.keygenArguments(sshDirectory: sshDirectory) } catch {
            keys.end(op)
            show(.problem(error.description), keySetup: true)
            return
        }
        let session = store.open(containerID: key, executable: SSHKeySetup.keygenExecutable,
                                 argv: arguments, environment: environment, onClose: stopped(op, message)) { code, lastLines in
            let output = snapshot.map { SSHKeySetup.keygenOutput(after: $0, stamp: SSHKeyState.stamp) }
            Task {
                await keys.refresh()
                then(code == 0 && SSHKeyState.files().hasFlotillaKey, output, code, lastLines)
            }
        }
        store.rename(session, in: key, to: "ssh-keygen")
    }

    /// `ssh-copy-id -i ~/.ssh/flotilla_ed25519.pub [user@]host` in this tab's terminal, where ssh asks
    /// for the host's password once.
    private func copyKey() {
        outcome = nil
        guard let host = validatedHost, let op = beginKeyOperation() else { return }
        runCopy(op, to: host, user: validatedUser, hostKey: key, name: hostName,
                stopped: "ssh-copy-id was closed before it finished.") { ok, code, lastLines in
            keys.end(op)
            if ok {
                show(.done("Flotilla\u{2019}s key is on \(hostName). Try it: the next session should go straight in.", output: lastLines), keySetup: true)
            } else {
                show(.problem("ssh-copy-id couldn\u{2019}t put Flotilla\u{2019}s key on \(hostName) (status \(code.map(String.init) ?? "unknown")).", output: lastLines), keySetup: true)
            }
        }
    }

    /// Runs ssh-copy-id for Flotilla's key to one host, in this tab, and records it on success.
    private func runCopy(_ op: UUID, to host: String, user: String?, hostKey: String, name: String, stopped message: String,
                         then: @escaping (_ ok: Bool, _ code: Int32?, _ lastLines: String) -> Void) {
        let arguments: [String]
        do {
            arguments = try SSHKeySetup.copyIDArguments(sshDirectory: sshDirectory, host: host, user: user)
        } catch {
            keys.end(op)
            show(.problem(error.description), keySetup: true)
            model.record("Refused to copy an SSH key to a host: \(error)", subsystem: "terminal")
            return
        }
        let session = store.open(containerID: key, executable: SSHKeySetup.copyIDExecutable, argv: arguments,
                                 environment: environment, onClose: stopped(op, message)) { code, lastLines in
            if code == 0 { keys.recordCopied(host: hostKey, user: user) }
            then(code == 0, code, lastLines)
        }
        store.rename(session, in: key, to: hostKey == key ? "ssh-copy-id" : "ssh-copy-id \(name)")
    }

    // MARK: Regenerate

    private func archiveName() -> String? {
        SSHKeySetup.archiveName(sshDirectory: sshDirectory, date: Date(), timeZone: .current) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// Kamal's design (18 October), in order, each step in this tab's terminal and each only after
    /// the one before succeeded:
    /// 1. rename — never delete — the current pair to `flotilla_ed25519.old-<date>[-n]`;
    /// 2. ssh-keygen for the new key; if it ends without one, the old pair is renamed back;
    /// 3. ssh-copy-id of the new key to this host;
    /// 4. if asked, remove the old key's lines from this host's `authorized_keys`, signed in with
    ///    the new key, by a script that first checks the new key's line is there.
    /// Then the other hosts Flotilla knows had the old key are offered a copy each.
    private func regenerate(removeOldFromHost: Bool) {
        outcome = nil
        guard let host = validatedHost, let op = beginKeyOperation() else { return }
        // From here every way out releases the lock: a refusal below, the chain's last step, or a
        // step's session being closed.
        var started = false
        defer { if !started { keys.end(op) } }
        let user = validatedUser
        let status = SSHKeyState.files()
        guard status.canRegenerate else {
            show(.problem(status.pathIsSafe ? "There\u{2019}s no key of Flotilla\u{2019}s in ~/.ssh to regenerate."
                                            : SSHKeySetup.unsafePathExplanation), keySetup: true)
            return
        }
        let oldBody = status.flotillaKeyBody
        let others = keys.hosts(with: oldBody, excluding: .init(host: key, user: user))
        let moves: [(from: String, to: String)]
        do {
            guard let archive = archiveName() else {
                show(.problem("Flotilla couldn\u{2019}t find a free name to set the old key aside under, so it changed nothing."), keySetup: true)
                return
            }
            moves = try SSHKeySetup.archiveMoves(sshDirectory: sshDirectory, archive: archive) {
                FileManager.default.fileExists(atPath: $0)
            }
        } catch {
            show(.problem(error.description), keySetup: true)
            return
        }
        if let failure = SSHKeyState.move(moves) {
            show(.problem("Flotilla couldn\u{2019}t set the old key aside (\(failure.reason))"
                          + (failure.stranded.isEmpty ? ", so it changed nothing." : "." + failure.whereThingsAre)), keySetup: true)
            Task { await keys.refresh() }
            return
        }
        let archived = moves.first.map { homeAbbreviated($0.to) } ?? "~/.ssh"
        // What the old pair is now, and that both of Flotilla's paths are empty: anything there after
        // ssh-keygen is this run's.
        let archivedFiles = moves.compactMap { SSHKeyState.stamp($0.to) }
        guard archivedFiles.count == moves.count,
              let snapshot = SSHKeySetup.KeygenSnapshot(sshDirectory: sshDirectory, archived: archivedFiles,
                                                        stamp: SSHKeyState.stamp) else {
            show(.problem("Something else is at ~/.ssh/\(SSHKeySetup.flotillaKeyName) now, so Flotilla didn\u{2019}t run ssh-keygen. Your previous key is at \(locate(moves, archivedFiles))."),
                 keySetup: true)
            Task { await keys.refresh() }
            return
        }
        started = true
        // Closed mid-passphrase: ssh-keygen is being stopped, not finished, so nothing is removed or
        // renamed back underneath it.
        runKeygen(op, snapshot: snapshot,
                  stopped: "ssh-keygen was closed before it finished, so Flotilla changed nothing more. Your previous key is at \(archived); if ssh-keygen left part of a new key, Regenerate Key sets it aside.") { made, output, code, lastLines in
            guard made else {
                // Nothing whole to use: take away exactly what this ssh-keygen made, and put the old
                // pair back. The lock is still held, so nothing else has written there since.
                let undo = rollBack(moves, archivedFiles: archivedFiles, output: output)
                keys.end(op)
                Task { await keys.refresh() }
                show(.problem("ssh-keygen ended without making a new key (status \(code.map(String.init) ?? "unknown")). " + undo,
                              output: lastLines), keySetup: true)
                return
            }
            keys.setOldKeyHosts(others)
            runCopy(op, to: host, user: user, hostKey: key, name: hostName,
                    stopped: "ssh-copy-id was closed before it finished. The new key is made; click Copy Key to put it on \(hostName). The old key is in \(archived).") { ok, code, lastLines in
                guard ok else {
                    keys.end(op)
                    show(.problem("The new key is made, but ssh-copy-id couldn\u{2019}t put it on \(hostName) (status \(code.map(String.init) ?? "unknown")). Click Copy Key to try again. The old key is in \(archived).",
                                  output: lastLines), keySetup: true)
                    return
                }
                guard removeOldFromHost, let oldBody else {
                    keys.end(op)
                    show(.done("The new key is on \(hostName). The old one is in \(archived) on this Mac, and still in \(hostName)\u{2019}s authorized_keys.",
                               output: lastLines), keySetup: true)
                    return
                }
                // Never the unguarded removal: without the new key's body the script cannot check
                // the new key is there first, so nothing runs.
                guard let newBody = SSHKeyState.files().flotillaKeyBody else {
                    keys.end(op)
                    show(.problem("The new key is on \(hostName), but Flotilla can\u{2019}t read its public half, so it left the old key there too.",
                                  output: lastLines), keySetup: true)
                    return
                }
                runRemoval(op, host: host, user: user, remove: oldBody, keep: newBody,
                           stopped: "The removal was closed before it finished. The new key is on \(hostName); the old one may still be in its authorized_keys.") { removal, lastLines in
                    keys.end(op)
                    if removal.succeeded {
                        show(.done("The new key is on \(hostName), and the old one is off it. The old key is in \(archived) on this Mac. "
                                   + removal.description(host: hostName), output: lastLines), keySetup: true)
                    } else {
                        // "Works" only when the script ran: it signed in with the new key and no other.
                        show(.problem("The new key is on \(hostName)\(removal.signedIn ? " and works" : ""), but the old one is still there. "
                                      + removal.description(host: hostName), output: lastLines), keySetup: true)
                    }
                }
            }
        }
    }

    /// After an ssh-keygen that left no whole pair (Kyle, 18 October): removes each half this
    /// ssh-keygen made — the exact inode found at its path the moment it exited, never "recent and
    /// the user's" — then renames the old pair back, never over anything. Says what happened, and
    /// where the previous key is whenever it is not back in place.
    private func rollBack(_ moves: [(from: String, to: String)], archivedFiles: [SSHKeySetup.FileStamp],
                          output: SSHKeySetup.KeygenOutput?) -> String {
        guard let output else { return "Your previous key is at \(locate(moves, archivedFiles))." }
        var left = output.foreign
        var removed: [String] = []
        var setAside: [String] = []
        for (path, file) in output.made.sorted(by: { $0.key < $1.key }) {
            switch SSHKeyState.remove(path, ifStill: file) {
            case .removed: removed.append(path)
            case .notMade, .failed(_, setAside: nil): left.append(path)
            case .setAside(let aside), .failed(_, setAside: let aside?): setAside.append(aside)
            }
        }
        let tidied = removed.isEmpty ? "" : "Flotilla removed the half-made \(removed.map(homeAbbreviated).joined(separator: " and ")). "
        let moved = setAside.isEmpty ? "" : "A file that turned up at Flotilla\u{2019}s key path is now \(setAside.map(homeAbbreviated).joined(separator: " and ")); Flotilla didn\u{2019}t delete it. "
        guard left.isEmpty else {
            model.record("Regenerate couldn't restore the old SSH key: a file it didn't make is in the way", subsystem: "terminal")
            return tidied + moved + "\(left.map(homeAbbreviated).joined(separator: " and ")) isn\u{2019}t something this run made, so Flotilla left it and couldn\u{2019}t put the old key back. Your previous key is at \(locate(moves, archivedFiles))."
        }
        if let failure = SSHKeyState.move(moves.map { (from: $0.to, to: $0.from) }) {
            model.record("Regenerate couldn't restore the old SSH key: \(failure.reason)", subsystem: "terminal")
            return tidied + moved + "Flotilla couldn\u{2019}t put the old key back (\(failure.reason)). Your previous key is at \(locate(moves, archivedFiles))."
        }
        return tidied + moved + "The old key is back in place."
    }

    /// Where the old pair's files are now — at the archive name or back at Flotilla's — found by
    /// file identity rather than assumed, for "Your previous key is at …".
    private func locate(_ moves: [(from: String, to: String)], _ archivedFiles: [SSHKeySetup.FileStamp]) -> String {
        zip(moves, archivedFiles).map { move, file in
            let at = [move.to, move.from].first { path in
                SSHKeyState.stamp(path).map { $0.device == file.device && $0.inode == file.inode } ?? false
            }
            return homeAbbreviated(at ?? move.to)
        }.joined(separator: " and ")
    }

    // MARK: Remove

    /// Takes Flotilla's key off this host's `authorized_keys`, by its exact body, keeping a backup.
    /// The key on this Mac is not touched.
    private func removeFromHost() {
        outcome = nil
        guard let host = validatedHost, let op = beginKeyOperation() else { return }
        let user = validatedUser
        let status = SSHKeyState.files()
        guard status.canRemoveFromHost, let body = status.flotillaKeyBody else {
            keys.end(op)
            show(.problem("Flotilla can\u{2019}t read its public key, so it can\u{2019}t find its line on \(hostName)."), keySetup: true)
            return
        }
        runRemoval(op, host: host, user: user, remove: body, keep: nil,
                   stopped: "The removal was closed before it finished; Flotilla\u{2019}s key may still be on \(hostName).") { removal, lastLines in
            keys.end(op)
            if removal.succeeded || removal == .notThere || removal == .noAuthorizedKeys {
                keys.forget(host: key, user: user, keyBody: body)
            }
            show(removal.succeeded ? .done(removal.description(host: hostName), output: lastLines)
                                   : .problem(removal.description(host: hostName), output: lastLines), keySetup: true)
        }
    }

    /// `ssh … <removalCommand>` in this tab's terminal. With `keep` (Regenerate), public-key sign-in
    /// only, and the script refuses unless `keep`'s line is there; nil only for Remove Key from This
    /// Host, which removes the current key on purpose.
    private func runRemoval(_ op: UUID, host: String, user: String?, remove: String, keep: String?, stopped message: String,
                            then: @escaping (SSHKeySetup.RemovalOutcome, String) -> Void) {
        let arguments: [String]
        do {
            arguments = try SSHKeySetup.removalArguments(sshDirectory: sshDirectory, host: host, user: user,
                                                         remove: remove, keep: keep)
        } catch {
            then(.other(nil), error.description)
            model.record("Refused to remove an SSH key from a host: \(error)", subsystem: "terminal")
            return
        }
        let session = store.open(containerID: key, executable: RemoteAccess.sshExecutable, argv: arguments,
                                 environment: environment, onClose: stopped(op, message)) { code, lastLines in
            then(SSHKeySetup.RemovalOutcome(exitCode: code), lastLines)
        }
        store.rename(session, in: key, to: "remove old key")
    }

    // MARK: Other hosts

    private func otherPeer(_ entry: SSHKeyHosts.Entry) -> PeerFingerprint? {
        model.hostMode.hosts.first { $0.fingerprint.hex == entry.host }?.fingerprint
    }

    private func otherHostName(_ entry: SSHKeyHosts.Entry) -> String {
        otherPeer(entry).map { model.hostMode.hostName(.peer($0), local: model.hostLabel) } ?? "a host no longer paired"
    }

    /// "Copy to minimac too": ssh-copy-id of the new key to a host that had the old one, at its
    /// current address, as the user it was copied for — both through the same validators.
    private func copyToOtherHost(_ entry: SSHKeyHosts.Entry) {
        outcome = nil
        let name = otherHostName(entry)
        guard let peer = otherPeer(entry), let address = HostConnect.address(model, peer) else {
            show(.problem("Flotilla doesn\u{2019}t have an address for \(name) now."), keySetup: true)
            return
        }
        guard let op = beginKeyOperation() else { return }
        runCopy(op, to: address, user: entry.user, hostKey: entry.host, name: name,
                stopped: "ssh-copy-id was closed before it finished.") { ok, code, lastLines in
            keys.end(op)
            if ok {
                show(.done("The new key is on \(name) too.", output: lastLines), keySetup: true)
            } else {
                show(.problem("ssh-copy-id couldn\u{2019}t put the new key on \(name) (status \(code.map(String.init) ?? "unknown")).", output: lastLines), keySetup: true)
            }
        }
    }

    private func show(_ value: SessionOutcome, keySetup: Bool) {
        outcome = value
        outcomeFromKeySetup = keySetup
    }
}
