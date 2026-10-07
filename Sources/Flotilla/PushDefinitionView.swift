import SwiftUI
import FlotillaCore

/// Push to Hosts (PLAN.md Phase D, layer 1; DECISIONS Q35): one of This Mac's networks or volumes,
/// created the same on the hosts you tick. This Mac's item is the definition.
///
/// Each host says what a push would do there before anything runs: create it (a network on a
/// subnet from that Mac's own block), already matches, differs, or not answering. Only the first
/// can be ticked — a host whose copy differs is reported and **left as it is**, because replacing
/// a volume deletes its data and replacing a network detaches its containers.
struct PushDefinitionView: View {
    enum Subject {
        case network(ContainerNetwork)
        case volume(ContainerVolume)
    }

    let model: AppModel
    let subject: Subject
    let dismiss: () -> Void

    @State private var chosen: Set<HostRef> = []
    @State private var seeded = false

    private var name: String {
        switch subject {
        case .network(let network): network.id
        case .volume(let volume): volume.name
        }
    }

    private var noun: String {
        switch subject {
        case .network: "network"
        case .volume: "volume"
        }
    }

    private func status(on host: HostRef) -> FleetPush.Status {
        switch subject {
        case .network(let network): FleetPush.status(of: FleetPush.definition(of: network), on: model.networks(on: host))
        case .volume(let volume): FleetPush.status(of: FleetPush.definition(of: volume), on: model.volumes(on: host))
        }
    }

    /// Ticked and still pushable — a host that answered with a copy since is dropped, not pushed.
    private var targets: [HostRef] {
        model.trustedHostRefs.filter { chosen.contains($0) && status(on: $0).isCreate }
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Push \u{201C}\(name)\u{201D} to Hosts", systemImage: "square.and.arrow.up.on.square",
                       hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            FormScaffold {
                form
            } preview: {
                rail
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Fresh lists from every host before anything is ticked, so "create" means create.
            await model.hostMode.refreshLiveStatus(force: true)
            model.updateAddressPlan()
            if !seeded {
                chosen = Set(model.trustedHostRefs.filter { status(on: $0).isCreate })
                seeded = true
            }
        }
    }

    // MARK: Form

    private var definitionSummary: String {
        switch subject {
        case .network(let network):
            let definition = FleetPush.definition(of: network)
            return (definition.hostOnly ? "Host-only" : "With external access")
                + (definition.labels.isEmpty ? "" : ", labels " + definition.labels.joined(separator: ", "))
                + ". Each Mac's copy gets a subnet from that Mac's own address block — the same name on "
                + "two Macs is two separate private networks."
        case .volume(let volume):
            let definition = FleetPush.definition(of: volume)
            return "Capacity \(definition.size ?? "the default")"
                + (definition.labels.isEmpty ? "" : ", labels " + definition.labels.joined(separator: ", "))
                + ". Created empty — no data moves between Macs."
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormSectionHeader(title: "As This Mac has it", note: definitionSummary)

            VStack(alignment: .leading, spacing: 8) {
                FormSectionHeader(title: "Hosts",
                                  note: "Only a host without a \(noun) of this name can be ticked. One whose copy differs is left as it is.")
                if model.trustedHostRefs.isEmpty {
                    Text("No host is paired yet. Add one in Hosts.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HostChecklist(model: model, hosts: model.trustedHostRefs, selection: $chosen,
                                  isSelectable: { status(on: $0).isCreate },
                                  state: { host in
                                      let state = status(on: host)
                                      return (describe(state), state.isDrift || state == .unavailable)
                                  },
                                  stateTitle: "A push would",
                                  extraTitle: isNetwork ? "Subnet" : nil,
                                  extra: { host in
                                      isNetwork && status(on: host).isCreate ? model.pushSubnet(on: host)?.description : nil
                                  })
                }
                ContainerSkewNote(model: model, hosts: targets)
            }
        }
    }

    private var isNetwork: Bool {
        if case .network = subject { return true }
        return false
    }

    private func describe(_ state: FleetPush.Status) -> String {
        switch state {
        case .create: return isNetwork ? "will create" : "will create, empty"
        case .matches: return "already has it, the same"
        case .differs(let reasons): return "differs — \(reasons.joined(separator: "; ")); left as it is"
        case .unavailable: return "not answering — its \(noun)s aren't known"
        }
    }

    // MARK: Rail and footer

    /// The command every chosen host runs — once, not once per host, which at thirty Mac minis
    /// would be thirty copies of one line. A network's subnet differs per Mac, so it is shown as a
    /// placeholder here and per host in the table's Subnet column. Built by the same functions
    /// that run it.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if targets.isEmpty {
                Text("Choose a host to see what it will run.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("On \(targets.count) host\(targets.count == 1 ? "" : "s"):")
                    .font(.caption).foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var command: String {
        let argv: [String]
        switch subject {
        case .network(let network):
            let definition = FleetPush.definition(of: network)
            // A real subnet for the shape check, shown as the placeholder it stands for.
            argv = ContainerCLI.createNetworkArguments(definition.name, options: .init(
                subnet: "10.240.0.0/24", isInternal: definition.hostOnly,
                labels: definition.labels))
                .map { $0 == "10.240.0.0/24" ? "<that Mac's /24>" : $0 }
        case .volume(let volume):
            let definition = FleetPush.definition(of: volume)
            argv = ContainerCLI.createVolumeArguments(definition.name, options: .init(size: definition.size,
                                                                                     labels: definition.labels))
        }
        return (["container"] + argv).joined(separator: " ")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(targets.count == 1 ? "Push to 1 Host" : "Push to \(targets.count) Hosts") {
                let hosts = targets
                let subject = subject
                dismiss()
                Task {
                    switch subject {
                    case .network(let network): await model.pushNetwork(FleetPush.definition(of: network), to: hosts)
                    case .volume(let volume): await model.pushVolume(FleetPush.definition(of: volume), to: hosts)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(targets.isEmpty)
        }
        .padding(12)
    }
}
