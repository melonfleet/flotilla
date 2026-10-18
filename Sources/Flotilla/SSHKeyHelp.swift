import SwiftUI
import AppKit
import FlotillaCore

/// Whether this Mac's user has an SSH key, and which hosts Flotilla has seen one copied to — what
/// the SSH tab's key card says (Kamal, 18 October).
///
/// What is read is a public key file's *existence*, by name, and the key types `ssh-add -L`
/// prints; nothing is opened and nothing is kept but those (`SSHKeySetup`). "Copied" is only what
/// Flotilla saw: an `ssh-copy-id` it ran that ended with 0, for that host and user, this run. Any
/// other way of knowing a key works would mean signing in to find out, which the page does not do
/// behind the user's back.
@MainActor
@Observable
final class SSHKeyState {
    private(set) var status: SSHKeySetup.Status?
    private(set) var copied: Set<String> = []

    /// `~/.ssh` of the user Flotilla runs as.
    nonisolated static var sshDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").path
    }

    func refresh() async {
        status = await Blocking.run { Self.read() }
    }

    func recordCopied(host: String, user: String?) { copied.insert(Self.copyKey(host, user)) }
    func isCopied(host: String, user: String?) -> Bool { copied.contains(Self.copyKey(host, user)) }

    private static func copyKey(_ host: String, _ user: String?) -> String { "\(user ?? "")@\(host)" }

    /// Blocking: runs `ssh-add -L` (bounded at five seconds) and checks eleven file names.
    nonisolated private static func read() -> SSHKeySetup.Status {
        let directory = sshDirectory
        return SSHKeySetup.status(sshDirectory: directory, agent: agent()) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    nonisolated private static func agent() -> SSHKeySetup.Agent {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHKeySetup.agentExecutable)
        process.arguments = SSHKeySetup.agentArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .unavailable }
        // A wedged agent socket must not hold the read forever.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationReason == .exit else { return .unavailable }
        return SSHKeySetup.parseAgent(output: String(decoding: data.prefix(256_000), as: UTF8.self),
                                      exitCode: process.terminationStatus)
    }
}

/// The SSH tab's key card: whether a session will ask for a password, and — behind "Set Up SSH
/// Key…" — the three visible steps that make one, put it on the host, and try it.
///
/// Each step is a button with a sentence saying what it will run, and runs it in the SSH tab's own
/// terminal, where the user answers its prompts. Flotilla never stores or logs a password or a
/// passphrase and never reads a private key (Q20): ssh-keygen asks for the passphrase and
/// ssh-copy-id for the host's password in the PTY, and the keystrokes pass through Flotilla's
/// terminal view on the way — which is what the card says, rather than "never sees" (Kyle, 18
/// October).
struct SSHKeyCard: View {
    let keys: SSHKeyState
    let hostName: String
    /// The validated address and user, when there is an argv at all.
    let host: String?
    let user: String?
    let outcome: SessionOutcome?
    let makeKey: () -> Void
    let copyKey: (String) -> Void
    let tryIt: () -> Void

    @State private var settingUp = false

    private var status: SSHKeySetup.Status? { keys.status }
    private var copied: Bool { host.map { keys.isCopied(host: $0, user: user) } ?? false }
    private var who: String { user.map { "\($0)\u{2019}s" } ?? "your" }

    var body: some View {
        DetailCard(title: "Sign in with an SSH key", minHeight: nil) {
            summary
            if let outcome { SessionOutcomeNote(outcome: outcome) }
            // Kept open across a step: the step's terminal replaced this card while it ran.
            if settingUp || copied || outcome != nil {
                steps
            } else if status != nil {
                Button("Set Up SSH Key\u{2026}") { settingUp = true }
                    .accessibilityHint("Shows the steps; nothing runs until you click one")
            }
            Divider().padding(.vertical, 2)
            byHand
        }
    }

    @ViewBuilder
    private var summary: some View {
        if copied {
            Label("Signed in with your SSH key: Flotilla put it on \(hostName).", systemImage: "key.fill")
                .font(.callout)
        } else if let status {
            if status.hasKey {
                Label("You have an SSH key. Until \(hostName) has it too, ssh asks for \(who) password each time.",
                      systemImage: "key").font(.callout).lineLimit(3)
            } else {
                Label("You\u{2019}ll be asked for \(who) password each time. An SSH key lets you go straight in.",
                      systemImage: "key.slash").font(.callout).lineLimit(3)
            }
        } else {
            Label("Looking for your SSH key\u{2026}", systemImage: "key").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Make a key") {
                if status?.pathIsSafe == false {
                    Label(SSHKeySetup.unsafePathExplanation, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.warning).lineLimit(4)
                } else if let name = status?.keyToCopy {
                    Label("You have one: ~/.ssh/\(name)", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.online)
                } else if let name = status?.privateKeyWithoutPublic {
                    // Never offer to make a key over one that exists (Kyle, 18 October).
                    Text("You have a private key, ~/.ssh/\(name), but not its public half, \(name).pub, so there\u{2019}s nothing to copy. Flotilla won\u{2019}t make a new key beside it. To recreate the public half, run ssh-keygen -y -f ~/.ssh/\(name) > ~/.ssh/\(name).pub in Terminal.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                } else if status?.hasKey == true {
                    Text("Your keys are in the SSH agent only, not in ~/.ssh, so Flotilla can\u{2019}t choose one to copy. Copy one by hand, below, or make a new one here.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    if status?.canMakeKey == true { makeKeyButton }
                } else if status?.canMakeKey == true {
                    makeKeyButton
                }
            }
            step(2, "Put it on \(hostName)") {
                if status?.pathIsSafe == false {
                    Text("Not from Flotilla, for the reason above.").font(.caption).foregroundStyle(.secondary)
                } else if let name = status?.keyToCopy, let host {
                    let destination = user.map { "\($0)@\(host)" } ?? host
                    Text("Runs ssh-copy-id in this tab. ssh asks for \(who) password on \(hostName) once, and adds your public key to that account\u{2019}s ~/.ssh/authorized_keys. Your private key stays on this Mac. Your passphrase and password go to ssh through this terminal; Flotilla doesn\u{2019}t store or log them.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(5)
                    SessionCommandLine(text: "ssh-copy-id -i ~/.ssh/\(name) \(destination)")
                    Button("Copy Key to \(hostName)") { copyKey(name) }
                } else {
                    Text("Once you have a key.").font(.caption).foregroundStyle(.secondary)
                }
            }
            step(3, "Try it") {
                Text("Starts an SSH session. It should go straight in; if your key has a passphrase, ssh asks for that instead.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if copied {
                    Button("Try It", action: tryIt).buttonStyle(.borderedProminent)
                } else {
                    Button("Try It", action: tryIt)
                }
            }
        }
    }

    private var makeKeyButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs ssh-keygen in this tab and saves the key as ~/.ssh/\(SSHKeySetup.keygenKeyName). It asks for a passphrase, which protects the key on this Mac. Your passphrase and password go to ssh through this terminal; Flotilla doesn\u{2019}t store or log them.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(5)
            SessionCommandLine(text: (["ssh-keygen"] + SSHKeySetup.keygenType
                                      + ["-f", "~/.ssh/" + SSHKeySetup.keygenKeyName]).joined(separator: " "))
            Button("Make a Key", action: makeKey)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                content()
            }
        }
    }

    /// The same, by hand, and where it is documented. OpenSSH's own manual pages: Apple has no
    /// current guide to SSH keys (its one is for the retired Server app), and the man pages are the
    /// tools' own documentation. `ssh-copy-id` is not part of OpenBSD's OpenSSH, so it has no page
    /// there; `man ssh-copy-id` is on every Mac.
    private var byHand: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("By hand, in Terminal").font(.callout.weight(.semibold))
            Text("Run ssh-keygen -t ed25519 to make a key, then ssh-copy-id \(user.map { "\($0)@" } ?? "")\(host ?? "<host>") to put it on \(hostName) — see man ssh-copy-id. After that, ssh signs in with the key.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            ForEach(Self.guides, id: \.1) { title, url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(title, systemImage: "arrow.up.forward.square").foregroundStyle(Theme.link)
                }
                .buttonStyle(.link)
                .help(url.absoluteString)
                .accessibilityHint("Opens in your browser")
            }
        }
    }

    private static let guides: [(String, URL)] = [
        ("ssh-keygen(1) — making a key", ExternalLinks.opensshKeygen),
        ("ssh(1) — how keys sign you in", ExternalLinks.opensshAuthentication),
    ]
}
