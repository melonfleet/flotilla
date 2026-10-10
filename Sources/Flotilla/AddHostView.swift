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

    private var hostMode: HostModeController { model.hostMode }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: importing.map { "Pair \($0.name)" } ?? "Add Host", systemImage: "plus",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            Form {
                if let importing {
                    SwiftUI.Section("From an imported file") {
                        LabeledContent("Mac", value: importing.name)
                        LabeledContent("Where", value: Self.describe(importing.endpoint))
                        LabeledContent("Must present key") {
                            Text(String(importing.fingerprint.hex.prefix(16)) + "…")
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        }
                        Text("If the Mac that answers presents a different key, nothing is sent to it and it is not paired.")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                } else {
                SwiftUI.Section("Which Mac") {
                    if hostMode.discovered.isEmpty {
                        Text("No host found on this network yet. A Mac appears here once Flotilla on it is set to Host in Settings ▸ Host Mode — or type its address below.")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    Picker("Which Mac", selection: $target) {
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
                    if target == .address {
                        // One labelled row: a grouped Form floats a second field's label above it.
                        LabeledContent("Address") {
                            HStack(spacing: 8) {
                                TextField("", text: $address, prompt: Text("mini-1.local or 192.168.1.20"))
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Address")
                                Text("Port").foregroundStyle(.secondary)
                                TextField("", text: $port)
                                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                                    .accessibilityLabel("Port")
                            }
                        }
                    }
                }
                }

                SwiftUI.Section("Pairing") {
                    TextField("Code", text: $code, prompt: Text("ABCD-EFGH"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text(hostMode.adminKey == nil
                         ? "On the other Mac, open Settings ▸ Host Mode and click Show Code, then type it here."
                         : "Type the code the other Mac shows — or leave it empty to enrol it with your fleet enrolment key, if its profile carries that key.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let outcome {
                    SwiftUI.Section { result(outcome) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                if working { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(importing == nil ? "Add Host" : "Pair") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(endpoint == nil || working || (code.isEmpty && hostMode.adminKey == nil))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Something chosen from the start: the first Mac found, or the address field when none is.
        .onAppear {
            if importing != nil { target = .imported }
            if target == nil { target = hostMode.discovered.first.map { .discovered($0.name) } ?? .address }
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
            Label("\(name) is already paired with this Mac.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger).lineLimit(4)
        }
    }
}
