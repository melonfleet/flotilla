import Foundation
import FlotillaCore

/// Restart policies and health checks on This Mac (DECISIONS Q53, part 2). The engine decides;
/// this feeds it what the container list shows and does what it says. Hosts follow in part 3.
extension AppModel {
    /// Every five seconds: restarts that have come due, and checks.
    func startPolicyWatch() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.runtimeUsable {
                    let actions = self.policies.update { $0.tick(policies: self.policies.policies, at: Date()) }
                    self.carryOut(actions)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// After each refresh of This Mac's containers.
    func observePolicies(_ containers: [Container]) {
        let present = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [PolicyEngine.Action] = []
        for (id, policy) in policies.policies {
            guard let container = present[id] else {
                // Gone — deleted here or in Terminal. Its policy goes with it.
                policies.set(ContainerPolicy(), for: id)
                continue
            }
            actions += policies.update { $0.observe(id, running: container.isRunning, policy: policy, at: Date()) }
        }
        carryOut(actions)
    }

    /// What a lifecycle action Flotilla is about to take means to a policy: a stop, kill or delete
    /// is deliberate; a start by hand clears "gave up"; a restart is both.
    func notePolicyIntent(_ action: Action, _ id: String) {
        switch action {
        case .stop, .kill, .delete: noteDeliberateStop(id)
        case .start: noteStartedByHand(id)
        case .restart: noteDeliberateStop(id); noteStartedByHand(id)
        }
    }

    /// A stop, kill or delete Flotilla is about to make: not one to undo.
    func noteDeliberateStop(_ id: String) {
        guard policies.policies[id] != nil else { return }
        policies.update { $0.noteDeliberateStop(id, at: Date()) }
    }

    /// This Mac's policies and what each last saw: what `.policies` answers an admin, and what its
    /// own container card shows.
    func policySummaries() -> [String: PolicySummary] {
        Dictionary(uniqueKeysWithValues: policies.policies.map { id, policy in
            (id, PolicySummary(policy: policy, watch: policies.watch(for: id)))
        })
    }

    /// Host side: an admin's stop, kill, delete, start or restart, before it runs. The canonical
    /// argv puts flags first and operands last, so the operands are whatever names a container here.
    func noteAdminLifecycle(_ verb: String, _ arguments: [String]) {
        let known = Set(containers.map(\.id))
        for id in arguments.dropFirst() where known.contains(id) {
            switch verb {
            case "start": noteStartedByHand(id)
            case "restart": noteDeliberateStop(id); noteStartedByHand(id)
            default: noteDeliberateStop(id)
            }
        }
    }

    /// A start by hand clears "gave up".
    func noteStartedByHand(_ id: String) {
        guard policies.policies[id] != nil else { return }
        policies.update { $0.clearGaveUp(id) }
    }

    private func carryOut(_ actions: [PolicyEngine.Action]) {
        for action in actions {
            switch action {
            case .restart(let id):
                Task { await self.policyRestart(id) }
            case .probe(let id, let probe, let timeout):
                Task { await self.policyProbe(id, probe, timeout: timeout) }
            case .changed:
                // The notices are rebuilt from the engine's state on their own five-second tick.
                break
            }
        }
    }

    private func policyRestart(_ id: String) async {
        let failure: String?
        do {
            try await Blocking.run { [cli] in _ = try cli.start(id) }
            failure = nil
            recordActivity(ContainerEvent(date: Date(), from: "stopped", to: "running", kind: .container,
                                          subject: id, action: "Restarted by its policy"))
        } catch {
            failure = "Couldn't start it: \(error)"
        }
        policies.update { $0.restartFinished(id, error: failure, at: Date()) }
        await refresh(showingProgress: false)
    }

    private func policyProbe(_ id: String, _ probe: HealthCheck.Probe, timeout: Int) async {
        let result: (ok: Bool, detail: String)
        let stored = policies.policy(for: id)
        // Held to the rules at every run, not only when saved: an admin's command check is never
        // run (whatever a dev build stored), and a dialled port must still be this container's own,
        // since its published ports can change after the policy was set (Kyle, 19 October).
        let published = containers.first { $0.id == id }.map { Set($0.publishedPorts.map(\.hostPort)) } ?? []
        if stored.setByAdmin == true, let refusal = stored.remoteProblem {
            result = (false, refusal)
        } else if probe.dialledPort != nil, let refusal = stored.portProblem(published: published) {
            result = (false, refusal)
        } else {
        switch probe {
        case .port(let port):
            result = await PolicyProbe.port(port, timeout: timeout)
        case .http(let port, let path):
            result = await PolicyProbe.http(port: port, path: path, timeout: timeout)
        case .command(let argv):
            result = await Blocking.run { [cli] () -> (ok: Bool, detail: String) in
                do {
                    let run = try cli.healthCommand(id, argv, timeout: timeout)
                    let said = (run.stdout + run.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    let excerpt = String(said.prefix(160))
                    return run.exitCode == 0 ? (true, excerpt.isEmpty ? "Exited 0" : excerpt)
                                             : (false, "Exited \(run.exitCode)" + (excerpt.isEmpty ? "" : ": \(excerpt)"))
                } catch {
                    return (false, String(describing: error))
                }
            }
        }
        }
        let policy = policies.policy(for: id)
        let actions = policies.update { $0.probeFinished(id, ok: result.ok, detail: result.detail, policy: policy, at: Date()) }
        carryOut(actions)
    }

    /// Notices for containers this Mac's policies watch: unhealthy (a warning, with Restart) and
    /// given up (an error, with Start).
    var policyAttentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        for id in policies.policies.keys.sorted() {
            guard let watch = policies.watch(for: id) else { continue }
            if watch.gaveUp {
                items.append(AttentionItem("\(id) keeps stopping: Flotilla stopped restarting it after "
                                           + "\(PolicyEngine.maxRestarts) tries in \(Int(PolicyEngine.window / 60)) minutes.",
                                           .containers, key: "container-gave-up:\(id)", level: .error,
                                           dismissible: false, host: .local,
                                           fix: ("Start", { [weak self] in self?.startByPolicyNotice(id) })))
            } else if watch.running, watch.health == .unhealthy {
                items.append(AttentionItem("\(id) is unhealthy: \(watch.lastProbeDetail ?? "its health check failed")",
                                           .containers, key: "container-unhealthy:\(id)", host: .local,
                                           fix: ("Restart", { [weak self] in self?.restartByPolicyNotice(id) })))
            }
        }
        return items
    }

    /// The same notices for hosts' containers, from each host's last report — a host Mac has nobody
    /// at it, so its admin is where they are seen.
    var hostPolicyAttentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        for peer in hostMode.trustedHosts {
            guard let reports = hostMode.policySnapshots[peer.fingerprint] else { continue }
            let host = HostRef.peer(peer.fingerprint)
            for id in reports.keys.sorted() {
                guard let report = reports[id] else { continue }
                let key = "\(peer.fingerprint.hex)/\(id)"
                if report.gaveUp {
                    items.append(AttentionItem("\(id) on \(peer.displayName) keeps stopping: it stopped restarting it after "
                                               + "\(PolicyEngine.maxRestarts) tries in \(Int(PolicyEngine.window / 60)) minutes.",
                                               .containers, key: "container-gave-up:\(key)", level: .error,
                                               dismissible: false, host: host,
                                               fix: ("Start", { [weak self] in self?.hostContainerAction(.start, id, on: host) })))
                } else if report.running, report.health == .unhealthy {
                    items.append(AttentionItem("\(id) on \(peer.displayName) is unhealthy: \(report.lastProbeDetail ?? "its health check failed")",
                                               .containers, key: "container-unhealthy:\(key)", host: host,
                                               fix: ("Restart", { [weak self] in self?.hostContainerAction(.restart, id, on: host) })))
                }
            }
        }
        return items
    }

    private func hostContainerAction(_ action: Action, _ id: String, on host: HostRef) {
        guard case .peer(let fingerprint) = host,
              let container = hostMode.containerSnapshots[fingerprint]?.items.first(where: { $0.id == id }) else { return }
        Task { await perform(action, on: container, host: host) }
    }

    private func startByPolicyNotice(_ id: String) {
        guard let container = containers.first(where: { $0.id == id }) else { return }
        Task { await perform(.start, on: container) }
    }

    private func restartByPolicyNotice(_ id: String) {
        guard let container = containers.first(where: { $0.id == id }) else { return }
        Task { await perform(.restart, on: container) }
    }
}
