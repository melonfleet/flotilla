import SwiftUI
import AppKit
import FlotillaCore
import FlotillaTrust

extension RunMode {
    /// "Admin" rather than "client": the Mac you manage the fleet from. The stored value keeps the
    /// name the Jamf reference documents.
    var title: String {
        switch self {
        case .client: "Admin"
        case .host: "Host"
        case .both: "Admin"
        }
    }

    var explanation: String {
        switch self {
        case .client, .both: "Manage other Macs from here. This Mac runs its own containers too."
        case .host: "Let an admin Mac manage this Mac. It runs its own containers either way."
        }
    }
}

/// Settings ▸ Host Mode (the owner, 7 October): how this Mac is used, its identity, and — by role —
/// listening for an admin, the pairing code, the enrolment key a host was given, and the fleet
/// enrolment key an admin hands out.
struct HostModePane: View {
    let model: AppModel
    @State private var revealKey = false
    @State private var pastedKey = ""
    @State private var pasteProblem: String?
    @State private var confirmingRotate = false
    @State private var pendingRemoval: Peer?
    @State private var now = Date()

    private var hostMode: HostModeController { model.hostMode }
    private var store: SettingsStore { model.settingsStore }

    var body: some View {
        Group {
            thisMac
            if hostMode.isHost { hostSection; adminsSection }
            if hostMode.isAdmin { fleetKeySection }
        }
        .confirmationDialog("Replace the fleet enrolment key?", isPresented: $confirmingRotate,
                            titleVisibility: .visible) {
            Button("Replace Key", role: .destructive) { hostMode.rotateEnrolmentKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Macs given the old key can no longer ask to join. Macs already enrolled stay "
                 + "enrolled. Update the key in your configuration profile.")
        }
        .confirmationDialog("Stop trusting “\(pendingRemoval?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { peer in
            // Revoked, not forgotten: the record is what keeps its enrolment key from letting it back.
            Button("Remove", role: .destructive) { hostMode.revoke(peer.fingerprint) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("That Mac can no longer manage this one, and any connection from it closes now. "
                 + "Its enrolment key won’t let it back; Allow Again or a new code pairing will.")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        // Silent and harmless: a key in the login Keychain, so the fingerprint is there to see.
        .onAppear { hostMode.ensureIdentity() }
    }

    // MARK: This Mac

    private var thisMac: some View {
        SwiftUI.Section("This Mac") {
            SettingRow(store: store, key: SettingsKeys.mode, title: "Use this Mac as") { binding in
                Picker("", selection: binding) {
                    ForEach(RunMode.offered, id: \.rawValue) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            LabeledContent("Identity") {
                if let identity = hostMode.identity {
                    HStack(spacing: 6) {
                        Text(Self.shortFingerprint(identity.fingerprint))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        IconActionButton(systemImage: "doc.on.doc", label: "Copy fingerprint",
                                         help: "Copy this Mac's full fingerprint") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(identity.fingerprint.hex, forType: .string)
                        }
                    }
                } else if let problem = hostMode.identityProblem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Host

    private var hostSection: some View {
        SwiftUI.Section("Host") {
            LabeledContent("Status") { listenerStatus }
            SettingRow(store: store, key: SettingsKeys.hostListenPort, title: "Port") { binding in
                TextField("", value: binding, format: .number.grouping(.never))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
            }
            SettingRow(store: store, key: SettingsKeys.bonjourEnabled, title: "Let admin Macs on this network find it") { binding in
                Toggle("", isOn: binding).labelsHidden()
            }
            SettingRow(store: store, key: SettingsKeys.keepAwakeAsHost, title: "Keep this Mac awake for its admin") { binding in
                Toggle("", isOn: binding).labelsHidden()
            }

            // The owner's decision (7 October): an admin Mac is the owner of the hosts it manages, so
            // nothing on a host is held back from it. Said here, where a host is about to pair.
            Label("An admin Mac you pair with controls this Mac’s containers fully — including their "
                  + "settings, environment variables and file paths. Pair only with your own admin Mac.",
                  systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(Theme.warning).lineLimit(3)
            LabeledContent("Pairing code") { pairingCode }

            LabeledContent("Enrolment key") { hostEnrolmentKey }
            if let status = hostMode.enrolmentStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var listenerStatus: some View {
        switch hostMode.listener {
        case .off: Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .starting: Label("Starting…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .listening(let port):
            Label("Listening on port \(String(port))", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.online)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).lineLimit(2)
        }
    }

    @ViewBuilder
    private var pairingCode: some View {
        if let code = hostMode.pairingCode, code.isUsable(at: now) {
            HStack(spacing: 10) {
                Text(code.display)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(Self.remaining(code, now: now)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Hide") { hostMode.hidePairingCode() }
            }
        } else {
            HStack {
                Text("Type it on the admin Mac to pair.").font(.caption).foregroundStyle(.secondary)
                Button("Show Code") { hostMode.showPairingCode() }
                    .disabled(hostMode.listener == .off)
            }
        }
    }

    @ViewBuilder
    private var hostEnrolmentKey: some View {
        if let problem = hostMode.managedEnrolmentKeyProblem {
            Text("From your organisation, but unusable: \(problem)")
                .font(.caption).foregroundStyle(Theme.warning).lineLimit(3)
        } else if let (key, source) = hostMode.hostEnrolmentKey {
            HStack(spacing: 8) {
                Text(Self.masked(key.text)).font(.system(size: 11, design: .monospaced))
                Text(source == .profile ? "set by your organisation" : "pasted")
                    .font(.caption).foregroundStyle(.secondary)
                if source == .pasted { Button("Remove") { hostMode.removePastedEnrolmentKey() } }
            }
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    TextField("", text: $pastedKey, prompt: Text("FLT1-…"))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 220)
                        .accessibilityLabel("Fleet enrolment key")
                    Button("Save") {
                        do {
                            try hostMode.setPastedEnrolmentKey(pastedKey)
                            pastedKey = ""
                            pasteProblem = nil
                        } catch {
                            pasteProblem = "\(error)"
                        }
                    }
                    .disabled(pastedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let pasteProblem {
                    Text(pasteProblem).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                }
            }
        }
    }

    private var adminsSection: some View {
        SwiftUI.Section("Admin Macs trusted by this Mac") {
            if hostMode.admins.isEmpty {
                Text("None yet. Show a pairing code, or enrol with the key your organisation provides.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(hostMode.admins) { admin in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(admin.displayName)
                        Text(admin.isTrusted ? (admin.method == .enrolmentKey ? "Enrolled by key" : "Paired by code")
                                             : "Removed — its enrolment key no longer lets it in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if admin.isTrusted {
                        IconActionButton(systemImage: "trash", label: "Remove \(admin.displayName)",
                                         help: "Stop trusting this admin Mac", destructive: true) {
                            pendingRemoval = admin
                        }
                    } else {
                        Button("Allow Again") { hostMode.allowAgain(admin.fingerprint) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Admin

    private var fleetKeySection: some View {
        SwiftUI.Section("Fleet enrolment key") {
            if let key = hostMode.adminKey {
                LabeledContent("Key") {
                    HStack(spacing: 6) {
                        Text(revealKey ? key.text : Self.masked(key.text))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        IconActionButton(systemImage: revealKey ? "eye.slash" : "eye",
                                         label: revealKey ? "Hide key" : "Show key",
                                         help: revealKey ? "Hide the key" : "Show the whole key") { revealKey.toggle() }
                        IconActionButton(systemImage: "doc.on.doc", label: "Copy key", help: "Copy the key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key.text, forType: .string)
                        }
                        Button("Replace…") { confirmingRotate = true }
                    }
                }
                Text("Put this in the configuration profile your hosts receive, as the managed "
                     + "preference enrolmentKey in dev.melonfleet.Flotilla, with mode set to host. "
                     + "Each Mac that uses it appears in Hosts waiting for your approval.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Lets managed Macs ask to join without anyone at their keyboard. You approve each one.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create Key") { hostMode.rotateEnrolmentKey() }
                }
            }
        }
    }

    // MARK: Formatting

    static func shortFingerprint(_ fingerprint: PeerFingerprint) -> String {
        let hex = fingerprint.hex.uppercased()
        return stride(from: 0, to: 24, by: 4).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<hex.index(from, offsetBy: 4)])
        }.joined(separator: " ") + " …"
    }

    /// The prefix and the last group: enough to recognise, not enough to use.
    static func masked(_ text: String) -> String {
        let groups = text.split(separator: "-")
        guard groups.count > 2 else { return text }
        return "\(groups[0])-\(groups[1])-••••••-\(groups.last!)"
    }

    static func remaining(_ code: PairingCode, now: Date) -> String {
        let left = max(0, Int(PairingCode.lifetime - now.timeIntervalSince(code.issuedAt)))
        return String(format: "%d:%02d left", left / 60, left % 60)
    }
}
