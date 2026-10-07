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
                }
                ForEach(model.trustedHostRefs, id: \.self) { host in
                    hostRow(host)
                }
                ContainerSkewNote(model: model, hosts: targets)
            }
        }
    }

    @ViewBuilder
    private func hostRow(_ host: HostRef) -> some View {
        let state = status(on: host)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(model.hostMode.hostName(host, local: model.hostLabel),
                   isOn: Binding(get: { chosen.contains(host) && state.isCreate },
                                 set: { on in if on { chosen.insert(host) } else { chosen.remove(host) } }))
                .toggleStyle(.checkbox)
                .disabled(!state.isCreate)
            Text(describe(state, on: host))
                .font(.caption)
                .foregroundStyle(state.isDrift ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                .lineLimit(2)
        }
    }

    private func describe(_ state: FleetPush.Status, on host: HostRef) -> String {
        switch state {
        case .create:
            if case .network = subject {
                return model.pushSubnet(on: host).map { "will create on \($0)" } ?? "no free subnet in its block"
            }
            return "will create, empty"
        case .matches: return "already has it, the same"
        case .differs(let reasons): return "has one that differs — \(reasons.joined(separator: "; ")). Left as it is."
        case .unavailable: return "not answering — its \(noun)s aren't known"
        }
    }

    // MARK: Rail and footer

    /// The commands each ticked host will run — built by the same functions that run them.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if targets.isEmpty {
                Text("Tick a host to see what it will run.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            ForEach(targets, id: \.self) { host in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hostMode.hostName(host, local: model.hostLabel))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(command(on: host))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func command(on host: HostRef) -> String {
        let argv: [String]
        switch subject {
        case .network(let network):
            let definition = FleetPush.definition(of: network)
            argv = ContainerCLI.createNetworkArguments(definition.name, options: .init(
                subnet: model.pushSubnet(on: host)?.description, isInternal: definition.hostOnly,
                labels: definition.labels))
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
