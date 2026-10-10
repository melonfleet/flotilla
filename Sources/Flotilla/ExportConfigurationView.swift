import SwiftUI
import FlotillaCore

/// File ▸ Export Configuration… — the checklist (DECISIONS Q29).
///
/// Embedded with Back, like every form since 9 August. **Nothing starts ticked** (the owner, 6
/// October), with Select All and Clear All at the top. The rail says what the file
/// will hold and, before anything is written, **everything that will be left out** — a file that
/// quietly builds something different on the other Mac is the failure this screen exists to avoid.
struct ExportConfigurationView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var inputs: ConfigurationExport.Inputs?
    @State private var selection = ConfigurationExport.Selection()
    @State private var saveError: String?

    private var result: ConfigurationExport.Result? {
        inputs.map { ConfigurationExport.build($0, selection: selection) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Export Configuration", systemImage: "square.and.arrow.up",
                       hasUnsavedChanges: false, onBack: dismiss) {
                // The owner's layout (6 October): nothing ticked to start, and these two at the
                // top rather than an All/None on every section.
                Button("Select All") { selection = everything }
                    .disabled(inputs == nil || selection == everything)
                Button("Clear All") { selection = ConfigurationExport.Selection() }
                    .disabled(selection == ConfigurationExport.Selection())
            }
            Divider()
            if let inputs {
                FormScaffold {
                    VStack(alignment: .leading, spacing: 22) { checklist(inputs) }
                } preview: {
                    rail
                }
            } else {
                ProgressView("Reading this Mac's configuration…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await load() }
    }

    // MARK: Checklist

    /// Containers that stand on their own: group members travel with their group, and a
    /// cluster's node is the cluster.
    private func standalone(_ inputs: ConfigurationExport.Inputs) -> [Container] {
        let members = Set(inputs.groups.flatMap(\.memberNames))
        let nodes = Set(inputs.clusters.map(\.name))
        return inputs.containers.filter { !members.contains($0.id) && !nodes.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    @ViewBuilder
    private func checklist(_ inputs: ConfigurationExport.Inputs) -> some View {
        Text("The file says what to build — another Mac pulls the same images and creates the same "
             + "things, empty. It holds no passwords, no volume data and no image layers.")
            .font(.callout).foregroundStyle(.secondary)

        kind("Groups", ids: inputs.groups.map(\.id), titles: Dictionary(uniqueKeysWithValues: inputs.groups.map { ($0.id, $0.name) }),
             detail: { id in inputs.groups.first { $0.id == id }.map { "\($0.members.count) services" } },
             set: \.groups)
        kind("Containers", ids: standalone(inputs).map(\.id), titles: [:],
             detail: { id in inputs.containers.first { $0.id == id }?.imageReference },
             set: \.containers)
        kind("Networks", ids: inputs.networks.filter { !$0.isBuiltin }.map(\.id), titles: [:],
             detail: { id in inputs.networks.first { $0.id == id }?.mode == "hostOnly" ? "host-only" : nil },
             set: \.networks)
        kind("Volumes", ids: inputs.volumes.map(\.name), titles: [:],
             detail: { _ in "created empty" }, set: \.volumes)
        kind("Machines", ids: inputs.machines.map(\.id), titles: [:],
             detail: { id in inputs.machines.first { $0.id == id }?.image?.reference }, set: \.machines)
        kind("Clusters", ids: Array(Set(inputs.clusters.map(\.name))).sorted(), titles: [:],
             detail: { _ in "on the default node image" }, set: \.clusters)
        // Who and where, and the key each must present — never a key and never trust (Q34).
        kind("Hosts", ids: inputs.hosts.map(\.fingerprint.hex),
             titles: Dictionary(uniqueKeysWithValues: inputs.hosts.map { ($0.fingerprint.hex, $0.displayName) }),
             detail: { _ in "paired again on the other Mac" }, set: \.hosts)

        VStack(alignment: .leading, spacing: 8) {
            FormSectionHeader(title: "Also")
            Toggle("Tags — on the things above", isOn: $selection.tags).toggleStyle(.checkbox)
            Toggle("Host categories — Site, Rack… and the values of the hosts above",
                   isOn: $selection.hostCategories).toggleStyle(.checkbox)
            Toggle("Registry list — never sign-ins", isOn: $selection.registries).toggleStyle(.checkbox)
            Toggle("DNS domains — recreating them needs an administrator, or the Flotilla Helper",
                   isOn: $selection.dns).toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private func kind(_ title: String, ids: [String], titles: [String: String],
                      detail: @escaping (String) -> String?,
                      set: WritableKeyPath<ConfigurationExport.Selection, Set<String>>) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FormSectionHeader(title: title)
                ForEach(ids, id: \.self) { id in
                    Toggle(isOn: Binding(get: { selection[keyPath: set].contains(id) },
                                         set: { on in
                                             if on { selection[keyPath: set].insert(id) }
                                             else { selection[keyPath: set].remove(id) }
                                         })) {
                        HStack(spacing: 8) {
                            Text(titles[id] ?? id)
                            if let detail = detail(id) {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: Rail and footer

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The file will hold", systemImage: "doc.text")
                .font(.caption).foregroundStyle(Theme.info)
            if let file = result?.file {
                Text(summary(file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let omissions = result?.omissions, !omissions.isEmpty {
                    Divider().padding(.vertical, 2)
                    Label("Left out", systemImage: "eye.slash")
                        .font(.caption).foregroundStyle(Theme.warning)
                    ForEach(omissions, id: \.self) { omission in
                        Text("\(omission.subject): \(omission.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func summary(_ file: ConfigurationFile) -> String {
        var lines: [String] = []
        func add(_ count: Int, _ noun: String) { if count > 0 { lines.append("\(count) \(noun)\(count == 1 ? "" : "s")") } }
        func add(_ count: Int, _ singular: String, _ plural: String) {
            if count > 0 { lines.append("\(count) \(count == 1 ? singular : plural)") }
        }
        add(file.groups.count, "group")
        add(file.containers.count, "container")
        add(file.networks.count, "network")
        add(file.volumes.count, "volume")
        add(file.machines.count, "machine")
        add(file.clusters.count, "cluster")
        if let tags = file.tags { add(tags.definitions.count, "tag") }
        if let registries = file.registries { add(registries.entries.count, "registry", "registries") }
        if let dns = file.dns { add(dns.domains.count, "DNS domain") }
        add(file.hosts.count, "host")
        if let categories = file.hostCategories { add(categories.count, "host category", "host categories") }
        return lines.isEmpty ? "Nothing yet — tick something." : lines.joined(separator: "\n")
    }

    private var footer: some View {
        HStack {
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button("Export…") { export() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(result?.file.isEmpty ?? true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    /// Every box ticked — what Select All sets. Computed from what this Mac has.
    private var everything: ConfigurationExport.Selection {
        guard let gathered = inputs else { return ConfigurationExport.Selection() }
        var all = ConfigurationExport.Selection()
        all.groups = Set(gathered.groups.map(\.id))
        all.containers = Set(standalone(gathered).map(\.id))
        all.networks = Set(gathered.networks.filter { !$0.isBuiltin }.map(\.id))
        all.volumes = Set(gathered.volumes.map(\.name))
        all.machines = Set(gathered.machines.map(\.id))
        all.clusters = Set(gathered.clusters.map(\.name))
        all.tags = true
        all.hostCategories = true
        all.registries = true
        all.dns = !gathered.dnsDomains.isEmpty
        all.hosts = Set(gathered.hosts.map(\.fingerprint.hex))
        return all
    }

    /// Nothing ticked to start (the owner, 6 October): the user picks what goes in the file.
    private func load() async {
        let gathered = await model.gatherExportInputs()
        selection = ConfigurationExport.Selection()
        inputs = gathered
    }

    private func export() {
        guard let file = result?.file else { return }
        do {
            if try model.saveConfiguration(file, suggestedName: "flotilla-configuration") != nil {
                dismiss()
            }
        } catch {
            saveError = "Couldn't write the file: \(error.localizedDescription)"
        }
    }
}
