import SwiftUI
import Network
import FlotillaCore

/// Hosts ▸ Add (PLAN.md Phase B, B3b): pick a Mac found on this network or type its address, then
/// pair — with the code it shows, or with this admin's fleet enrolment key. Pairing by code ends
/// with both Macs showing the same four words (`PairingWordsSheet`).
struct AddHostView: View {
    let model: AppModel
    /// Set when pairing a host from an imported file (Q34): where it should be and the key it must
    /// present. Pairing stops before it starts if a different key answers.
    var importing: HostModeController.ImportedHost? = nil
    let dismiss: () -> Void

    private enum Target: Hashable { case discovered(String), address, imported }

    @State private var target: Target?
    @State private var address = ""
    @State private var port = String(WireProtocol.defaultPort)
    @State private var code = ""
    @State private var working = false
    @State private var outcome: HostModeController.AddHostOutcome?
    /// The header's guard registration: Back and ✕ (and a Skip) ask about this form alone.
    @State private var formToken = UUID()

    private var hostMode: HostModeController { model.hostMode }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: importing.map { "Pair \($0.name)" } ?? "Add Host", systemImage: "plus",
                       hasUnsavedChanges: false, onBack: dismiss, token: formToken,
                       actions: FormActions(
                           .keepsChanges(importing == nil ? "Add Host" : "Pair",
                                         isDisabled: endpoint == nil || working || (code.isEmpty && hostMode.adminKey == nil)) { add() },
                           isWorking: working, workingHelp: "Connecting…"))
            Divider()
            if working {
                FormBand {
                    Text("Connecting…").foregroundStyle(.secondary)
                }
            }
            FormScaffold {
                VStack(alignment: .leading, spacing: 20) {
                    if let importing {
                        importedFields(importing)
                    } else {
                        hostFields
                    }
                    FormSectionHeader(title: "Pairing")
                    FormField("Code", help: codeHelp, optional: hostMode.adminKey != nil) {
                        TextField("", text: $code, prompt: Text("ABCD-EFGH"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    if let outcome { result(outcome) }
                }
            } preview: {
                railPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Something chosen from the start: the first Mac found, or the address field when none is.
        .onAppear {
            if importing != nil { target = .imported }
            if target == nil { target = hostMode.discovered.first.map { .discovered($0.name) } ?? .address }
        }
    }

    @ViewBuilder
    private var hostFields: some View {
        FormSectionHeader(title: "Which Mac")
        FormField("Which Mac",
                  help: FieldHelp(
                      "Choose a nearby host, or choose By address to enter one yourself.",
                      detail: "On the host Mac, open Flotilla’s Settings ▸ Hosts and Fleet and set “Use this Mac as” to Host. "
                          + "Bonjour lists hosts that advertise on this network; an address is useful "
                          + "across subnets or over Tailscale.",
                      example: "By address: mini-1.local",
                      warning: "Discovery is not trust. Pair only with Macs you own; pairing gives "
                          + "this admin full control of their containers, settings, environment variables and file paths.")) {
            if hostMode.discovered.isEmpty {
                Text("No host found on this network yet. A Mac appears here once Flotilla on it is set to Host in Settings ▸ Hosts and Fleet — or type its address below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $target) {
                ForEach(hostMode.discovered) { host in
                    HStack(spacing: 8) {
                        Label(host.name, systemImage: "desktopcomputer")
                        if !host.distinguishing.isEmpty {
                            Text(host.distinguishing).font(.caption).foregroundStyle(.secondary)
                        }
                        if let known = hostMode.knownHost(advertising: host) {
                            Text("paired as \(known.displayName)").font(.caption).foregroundStyle(Theme.online)
                        }
                    }
                    .tag(Target?.some(.discovered(host.name)))
                }
                Text("By address").tag(Target?.some(.address))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        if target == .address {
            FormField("Address",
                      help: FieldHelp(
                          "The host’s name, IP address or Tailscale address.",
                          detail: "Enter the address alone, with the port in the next field. "
                              + "Manual entry is the norm on routed networks: mDNS discovery does not cross subnets or VLANs.",
                          example: "mini-1.local\n192.168.1.20\n100.101.102.103 (Tailscale)",
                          warning: "A .local name relies on mDNS too. Across subnets, use an IP "
                              + "address or a name this Mac can resolve.")) {
                TextField("", text: $address, prompt: Text("mini-1.local or 192.168.1.20"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Address")
            }
            FormField("Port",
                      help: FieldHelp(
                          "The port Flotilla is listening on at the host.",
                          detail: "On the host Mac, Settings ▸ Hosts and Fleet shows its Port and "
                              + "Listening on port status. Use that number; the default is 7868.",
                          example: "7868",
                          warning: "Use Flotilla’s listening port, not the SSH port. A different "
                              + "port will not reach its pairing listener.")) {
                TextField("", text: $port)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                    .accessibilityLabel("Port")
            }
        }
    }

    private func importedFields(_ host: HostModeController.ImportedHost) -> some View {
        Group {
            FormSectionHeader(title: "From an imported file")
            FormField("Mac", help: FieldHelp(
                "The host named in the imported file.",
                detail: "The file supplies its name, endpoint and expected key. You still need to pair it here.",
                example: "mini-1",
                warning: "An imported host is not yet trusted. Pair only with Macs you own.")) {
                Text(host.name)
            }
            FormField("Where", help: FieldHelp(
                "Where the imported file says to reach this host.",
                detail: "This is either a Bonjour service or an address and port, as exported by the other admin Mac.",
                example: "mini-1 (found by Bonjour)\n192.168.1.20, port 7868",
                warning: "Bonjour relies on mDNS, which does not cross subnets. An imported endpoint may no longer be reachable.")) {
                Text(Self.describe(host.endpoint))
                    .textSelection(.enabled)
            }
            FormField("Must present key", help: FieldHelp(
                "The answering Mac must match the imported key fingerprint.",
                detail: "The value shown is the start of that fingerprint. Flotilla checks the full "
                    + "fingerprint before sending any pairing message.",
                example: "First 16 hexadecimal characters…",
                warning: "If a different key answers, nothing is sent to it and it is not paired. "
                    + "Check with the host’s owner; the address may reach another Mac, or the host may have been reinstalled.")) {
                Text(String(host.fingerprint.hex.prefix(16)) + "…")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private var codeHelp: FieldHelp {
        FieldHelp(
            "On the host Mac, open Flotilla’s Settings ▸ Hosts and Fleet and click Show Code beside Pairing code.",
            detail: "Type that code here. Code pairing then shows four words on both Macs; "
                + "compare them and confirm on both."
                + (hostMode.adminKey == nil ? "" : " Or leave this empty to enrol with this admin’s "
                   + "fleet enrolment key, if the host has the matching key; approve its request in Hosts."),
            example: "ABCD-EFGH",
            warning: "The code is single-use and expires after ten minutes. Show a fresh code if "
                + "it expires. Confirm only if all four words match on both Macs.")
    }

    private var railPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(importing == nil ? "Add Host" : "Pair", systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(Theme.info)
            if let endpoint {
                Text(PeerEndpoint(endpoint).map(Self.describe) ?? String(describing: endpoint))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose a host or enter its address and port.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(code.isEmpty && hostMode.adminKey != nil
                 ? "Connects with the fleet enrolment key. A new host’s request waits for approval in Hosts."
                 : "Connects to the host, then asks you to compare and confirm four words on both Macs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If already paired on both Macs, this saves the address for reaching the host when it cannot be found nearby.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var endpoint: NWEndpoint? {
        switch target {
        case .discovered(let name): return hostMode.discovered.first { $0.name == name }?.endpoint
        case .imported: return importing?.endpoint.nwEndpoint
        case .address:
            let host = address.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let number = UInt16(port), let nwPort = NWEndpoint.Port(rawValue: number) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        case nil: return nil
        }
    }

    private func add() {
        guard let endpoint else { return }
        working = true
        outcome = nil
        Task {
            outcome = await hostMode.addHost(at: endpoint, code: code.isEmpty ? nil : code,
                                             expecting: importing?.fingerprint)
            working = false
            if case .paired = outcome { code = "" }
        }
    }

    static func describe(_ endpoint: PeerEndpoint) -> String {
        switch endpoint {
        case .bonjour(let name): "\(name) (found by Bonjour)"
        case .address(let host, let port): "\(host), port \(port)"
        }
    }

    @ViewBuilder
    private func result(_ outcome: HostModeController.AddHostOutcome) -> some View {
        switch outcome {
        case .paired(let name):
            HStack {
                Label("Paired with \(name).", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.online)
                Spacer()
                Button("Done", action: dismiss)
            }
        case .waitingForApproval(let name):
            HStack {
                Label("\(name) asked to join. Approve it in Hosts.", systemImage: "person.badge.key")
                    .foregroundStyle(Theme.warning)
                Spacer()
                Button("Done", action: dismiss)
            }
        case .alreadyPaired(let name):
            HStack {
                Label("\(name) is already paired. Flotilla will reach it at this address whenever it can\u{2019}t find it nearby.",
                      systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: dismiss)
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger).lineLimit(4)
                .help(why)
        }
    }
}
