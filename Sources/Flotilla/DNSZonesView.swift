import SwiftUI
import FlotillaCore

/// Set Up Zones (PLAN.md Phase D, layer 2, Part B; DECISIONS Q36): each Mac names its containers in
/// its own zone, `<its label>.<fleet domain>` — `web.mini.fleet.internal` — so two Macs' `web` never
/// share a name.
///
/// Each Mac says what setting up its zone would do before anything runs: nothing (already done),
/// add the domain, and name its containers there — which restarts that Mac's runtime and stops its
/// running containers, said with the count. A host whose DNS helper is off cannot be ticked.
struct DNSZonesView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var chosen: Set<HostRef> = []
    @State private var seeded = false
    @State private var confirming = false
    @State private var fleetDomain = ""

    private var macs: [HostRef] { [.local] + model.trustedHostRefs }

    private var targets: [HostRef] { macs.filter { chosen.contains($0) && model.zoneState(on: $0).canSetUp } }

    /// Running containers the chosen Macs' restarts would stop, in all.
    private var stopping: Int {
        targets.reduce(0) { total, host in
            if case .needed(_, _, let restarts) = model.zoneState(on: host) { return total + restarts }
            return total
        }
    }

    private var domainProblem: String? {
        let trimmed = fleetDomain.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : FleetZones.fleetDomainProblem(trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Set Up Zones", systemImage: Section.dns.systemImage,
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
            fleetDomain = model.fleetDNSDomain
            await model.hostMode.refreshLiveStatus(force: true)
            if !seeded {
                // Only Macs where nothing stops: a restart that stops containers is ticked by hand.
                chosen = Set(macs.filter {
                    if case .needed(_, _, let restarts) = model.zoneState(on: $0) { return restarts == 0 }
                    return false
                })
                seeded = true
            }
        }
        .confirmationDialog("Restart container on \(targets.count) Mac\(targets.count == 1 ? "" : "s")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Restart and Set Up") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Naming containers in a zone restarts container on each Mac, which stops every running "
                 + "container there (\(stopping) in all). Start them again afterwards; only containers "
                 + "created from now on get a name in the zone.")
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormField("Fleet domain",
                      help: FieldHelp("The domain every Mac's zone sits under.",
                                      detail: "Each Mac's zone is its name in front of it. .internal is "
                                          + "reserved for private networks, so it can never be a real website.",
                                      example: "fleet.internal → web.mini.fleet.internal"),
                      problem: domainProblem) {
                TextField(FleetZones.defaultFleetDomain, text: $fleetDomain)
                    .textFieldStyle(.roundedBorder)
                    .monospaced()
                    .frame(maxWidth: 260)
                    .onSubmit(saveDomain)
                    .onChange(of: fleetDomain) { _, _ in saveDomain() }
            }

            VStack(alignment: .leading, spacing: 8) {
                FormSectionHeader(title: "Macs",
                                  note: "A Mac's zone is its own: its containers are named there and nowhere else. "
                                      + "Names that resolve on other Macs come later (Q36).")
                HostChecklist(model: model, hosts: macs, selection: $chosen,
                              isSelectable: { model.zoneState(on: $0).canSetUp },
                              state: { describe(model.zoneState(on: $0)) },
                              stateTitle: "Setting up would",
                              extraTitle: "Zone",
                              extra: { model.fleetZones[$0] })
            }
        }
    }

    private func describe(_ state: AppModel.ZoneState) -> (text: String, warning: Bool) {
        switch state {
        case .done: return ("already set up", false)
        case .unavailable(let why): return (why, true)
        case .needed(let createResolver, let setDomain, let restarts):
            var parts: [String] = []
            if createResolver { parts.append("add the domain") }
            if setDomain {
                parts.append(restarts > 0 ? "restart container, stopping \(restarts)" : "restart container")
            }
            return (parts.joined(separator: ", "), restarts > 0)
        }
    }

    private func saveDomain() {
        let trimmed = fleetDomain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, FleetZones.fleetDomainProblem(trimmed) == nil else { return }
        try? model.settingsStore.set(trimmed, for: SettingsKeys.fleetDNSDomain)
    }

    // MARK: Rail and footer

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On each Mac", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if targets.isEmpty {
                Text("Choose a Mac to see what it will do.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("container system dns create <zone>\n[dns] domain = \"<zone>\"  (then container restarts)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Run by each Mac's own DNS helper. This Mac uses its helper, or asks for your password.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(targets.count == 1 ? "Set Up 1 Mac…" : "Set Up \(targets.count) Macs…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(targets.isEmpty || domainProblem != nil)
        }
        .padding(12)
    }

    private func start() {
        let hosts = targets
        dismiss()
        Task { await model.setUpZones(on: hosts) }
    }
}
