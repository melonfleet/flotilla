import SwiftUI
import FlotillaCore

/// Restart and health settings for one container (DECISIONS Q53): the container page's card and
/// the Run form both use this editor, so a policy reads the same wherever it is set.
struct ContainerPolicyEditor: View {
    @Binding var policy: ContainerPolicy
    /// The container's ports published on this Mac — what a port or HTTP check can reach.
    let publishedPorts: [Int]

    private enum Kind: String, CaseIterable, Identifiable {
        case port = "Port answers", http = "HTTP returns OK", command = "Command succeeds"
        var id: Self { self }
    }

    @State private var commandText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Restart", selection: $policy.restart) {
                ForEach(ContainerPolicy.Restart.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if policy.restart == .unlessStopped {
                note("Started again whenever it stops, unless you stopped it in Flotilla: after 10, 30, 60, 120 "
                     + "and 300 seconds, giving up after five in ten minutes. `container` doesn't say why a "
                     + "container stopped, so a stop typed in Terminal looks like a crash and is restarted too.")
            }

            Toggle("Check its health", isOn: Binding(get: { policy.health != nil }, set: { on in
                policy.health = on ? HealthCheck(probe: .port(publishedPorts.first ?? 80)) : nil
                if !on { policy.restartWhenUnhealthy = false }
            }))
            if let health = policy.health {
                healthFields(health)
            }
        }
        .onAppear {
            if case .command(let argv)? = policy.health?.probe { commandText = argv.joined(separator: " ") }
        }
    }

    @ViewBuilder
    private func healthFields(_ health: HealthCheck) -> some View {
        let kind: Kind = switch health.probe {
        case .port: .port
        case .http: .http
        case .command: .command
        }
        Picker("Check", selection: Binding(get: { kind }, set: { new in
            let port = publishedPorts.first ?? 80
            let probe: HealthCheck.Probe = switch new {
            case .port: .port(port)
            case .http: .http(port: port, path: "/")
            case .command: .command(commandText.split(separator: " ").map(String.init))
            }
            setProbe(probe)
        })) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()

        switch health.probe {
        case .port(let port):
            portField(port) { setProbe(.port($0)) }
            note("Flotilla connects to this port on this Mac. Nothing runs in the container.")
        case .http(let port, let path):
            portField(port) { setProbe(.http(port: $0, path: path)) }
            TextField("Path", text: Binding(get: { path }, set: { setProbe(.http(port: port, path: $0)) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            note("A 2xx or 3xx answer from this path on the container's own port is healthy. Only this "
                 + "port on this Mac is ever asked: a check can't be pointed at another address.")
        case .command:
            TextField("Command, e.g. pg_isready -U postgres", text: $commandText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                .onChange(of: commandText) { _, text in setProbe(.command(text.split(separator: " ").map(String.init))) }
            note("Run in the container; exit 0 is healthy. Words are split on spaces and passed as they are, "
                 + "not to a shell: write `sh -c …` yourself if you want one. Up to \(HealthCheck.maxCommandTokens) words.")
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            stepperRow("Every", value: \.interval, range: HealthCheck.intervals, step: 5, unit: "s")
            stepperRow("Timeout", value: \.timeout, range: HealthCheck.timeouts, step: 1, unit: "s")
            stepperRow("Unhealthy after", value: \.retries, range: HealthCheck.retryCounts, step: 1, unit: " failures")
            stepperRow("Grace after start", value: \.startPeriod, range: HealthCheck.startPeriods, step: 5, unit: "s")
        }
        Toggle("Restart it when unhealthy", isOn: $policy.restartWhenUnhealthy)
        note("Off, an unhealthy container raises a notice with Restart as its fix.")
        if let problem = policy.problem {
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
        }
    }

    private func setProbe(_ probe: HealthCheck.Probe) {
        policy.health?.probe = probe
    }

    @ViewBuilder
    private func portField(_ port: Int, set: @escaping (Int) -> Void) -> some View {
        if publishedPorts.count > 1 || (publishedPorts.count == 1 && publishedPorts[0] != port) {
            Picker("Port", selection: Binding(get: { port }, set: set)) {
                ForEach(Array(Set(publishedPorts + [port])).sorted(), id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
        } else {
            TextField("Port", value: Binding(get: { port }, set: set), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 90)
        }
    }

    private func stepperRow(_ label: String, value: WritableKeyPath<HealthCheck, Int>, range: ClosedRange<Int>,
                            step: Int, unit: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { policy.health?[keyPath: value] ?? range.lowerBound },
                                   set: { policy.health?[keyPath: value] = $0 }),
                    in: range, step: step) {
                Text("\(policy.health?[keyPath: value] ?? range.lowerBound)\(unit)").monospacedDigit()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)
    }
}

/// The container page's "Restart and health" card: the policy, what its Mac last saw, and its
/// history, with the editor behind Edit. On a host, the host keeps and runs the policy, and this
/// shows its last report (wire version 12).
struct ContainerPolicyCard: View {
    let model: AppModel
    let container: Container
    var host: HostRef = .local

    @State private var editing = false
    @State private var saving = false
    @State private var draft = ContainerPolicy()
    @State private var failure: String?

    private var report: PolicySummary {
        switch host {
        case .local:
            PolicySummary(policy: model.policies.policy(for: container.id), watch: model.policies.watch(for: container.id))
        case .peer(let fingerprint):
            model.hostMode.policySnapshots[fingerprint]?[container.id] ?? PolicySummary(policy: ContainerPolicy(), watch: nil)
        }
    }
    private var policy: ContainerPolicy { report.policy }

    var body: some View {
        DetailCard(title: "Restart and health", minHeight: nil) {
            if !model.hostKeepsPolicies(host) {
                Text("\(model.hostMode.hostName(host, local: model.hostLabel)) needs a newer Flotilla to keep a restart or health policy.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if editing {
                ContainerPolicyEditor(policy: $draft, publishedPorts: container.publishedPorts.map(\.hostPort))
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
                HStack {
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Cancel") { editing = false; failure = nil }
                    Button("Save") {
                        saving = true
                        Task {
                            failure = await model.setPolicy(draft, for: container.id, on: host)
                            saving = false
                            if failure == nil { editing = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.problem != nil || saving)
                }
            } else {
                summary
                HStack {
                    if !host.isLocal {
                        Text("Kept and run by \(model.hostMode.hostName(host, local: model.hostLabel)), so it carries on while this Mac is away.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { draft = policy; failure = nil; editing = true }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        row("Restart", policy.restart.title)
        if let health = policy.health {
            row("Health check", health.probe.title + ", every \(health.interval)s")
            HStack(spacing: 6) {
                Circle().fill(healthColour).frame(width: 7, height: 7)
                Text(healthText).font(.system(size: 12, weight: .medium))
                if let last = report.lastProbe {
                    Text("· checked \(RelativeDate.relativeToNow(last))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let detail = report.lastProbeDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(detail)
            }
        } else {
            row("Health check", "None")
        }
        if report.gaveUp {
            Label("Stopped restarting it after \(PolicyEngine.maxRestarts) tries in \(Int(PolicyEngine.window / 60)) minutes. Start it to try again.",
                  systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(Theme.danger)
        }
        if !report.history.isEmpty {
            let history = report.history
            Divider()
            ForEach(history.prefix(5)) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(RelativeDate.relativeToNow(event.date)).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(event.detail).font(.caption).lineLimit(1).help(event.detail)
                }
            }
        }
    }

    private var healthText: String {
        switch report.health {
        case .unknown: container.isRunning ? "Not checked yet" : "Not running"
        case .starting: "Starting"
        case .healthy: "Healthy"
        case .unhealthy: "Unhealthy"
        }
    }

    private var healthColour: Color {
        switch report.health {
        case .healthy: Theme.online
        case .unhealthy: Theme.warning
        case .starting, .unknown: .secondary
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12)).multilineTextAlignment(.trailing)
        }
    }
}
