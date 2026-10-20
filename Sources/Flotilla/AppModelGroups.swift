import Foundation
import FlotillaCore

/// Starting and stopping a saved group.
///
/// Everything here is a loop over commands `AppModel` already issues for one container, through
/// the same `ContainerCLI` and therefore the same `Allowlist`. A group adds no command to the
/// boundary — see `ContainerGroup` for why that is the point rather than a coincidence.
extension AppModel {

    /// The group's state, derived from the live container list of the Mac it runs on rather than
    /// from anything stored.
    func state(of group: ContainerGroup) -> GroupState {
        group.state(runningNames: runningContainerNames(on: group.place),
                    existingNames: existingContainerNames(on: group.place))
    }

    // MARK: Per Mac (groups on hosts, the owner, 12 October)

    /// The containers on `host`, as last seen: This Mac's list, or the host's last snapshot.
    func containers(on host: HostRef) -> [Container] {
        switch host {
        case .local: containers
        case .peer(let fingerprint): hostMode.containerSnapshots[fingerprint]?.items ?? []
        }
    }

    func existingContainerNames(on host: HostRef) -> Set<String> { Set(containers(on: host).map(\.id)) }

    func runningContainerNames(on host: HostRef) -> Set<String> {
        Set(containers(on: host).filter(AppModel.isRunning).map(\.id))
    }

    /// Asks `host` for its containers again, now.
    func refreshContainers(on host: HostRef) async {
        switch host {
        case .local: await refresh()
        case .peer(let fingerprint): await hostMode.refreshHost(fingerprint)
        }
    }

    /// "This Mac" or the host's name, for titles and Activity.
    func groupHostName(_ group: ContainerGroup) -> String {
        hostMode.hostName(group.place, local: hostLabel)
    }

    /// Whether the group's Mac can be acted on now: This Mac always; a host while it is trusted.
    func canReach(_ group: ContainerGroup) -> Bool {
        guard case .peer(let fingerprint) = group.place else { return true }
        return hostMode.trustedHosts.contains { $0.fingerprint == fingerprint }
    }

    /// A group's title in a progress panel: "“shop”", or "“shop” on the mini".
    private func title(_ verb: String, _ group: ContainerGroup) -> String {
        group.place.isLocal ? "\(verb) “\(group.name)”" : "\(verb) “\(group.name)” on \(groupHostName(group))"
    }

    /// Activity names a host's group with its Mac, as it does a host's container.
    private func activitySubject(_ group: ContainerGroup) -> String {
        group.place.isLocal ? group.name : "\(group.name) on \(groupHostName(group))"
    }

    var existingContainerNames: Set<String> { Set(containers.map(\.id)) }

    /// Through `AppModel.isRunning`, not a second reading of the status field — `ContainerState`
    /// has more than two cases and the group badge must agree with the Containers table.
    var runningContainerNames: Set<String> {
        Set(containers.filter(AppModel.isRunning).map(\.id))
    }

    /// Starts every member, in listed order.
    ///
    /// **Start is not always `run`.** A member whose container already exists — the usual case
    /// after the group has been stopped once — is *started*, because `container run` would refuse
    /// the name as taken. Getting this wrong would make a group work exactly once.
    ///
    /// **A failure stops the group.** If the database refuses to start there is no value in
    /// starting the four things that talk to it; they would come up, fail to connect and need
    /// stopping again. The members that did start are left running and named in the summary, so
    /// the state on screen matches the state on the machine.
    func startGroup(_ group: ContainerGroup) async {
        guard !group.members.isEmpty else { return }
        await withProgress(
            title: title("Start", group),
            command: groupCommandPreview(group, starting: true),
            // Retry: Start skips members already running, so a second run picks up where it stopped.
            kind: .groupAction,
            retry: { [weak self] in await self?.startGroup(group) },
            work: { [weak self] progress in
                guard let self else { return "" }
                let started = try await startMembers(of: group, progress: progress,
                                                     skippingRunning: true)
                await refreshContainers(on: group.place)
                let summary = started.isEmpty
                    ? "Every service was already running"
                    : "Started \(started.count) of \(group.members.count)"
                // The group's own line in the feed. Each member's `container run` leaves a
                // container event of its own, but four of those within a second say what
                // happened and not why — this says why.
                if !started.isEmpty {
                    recordActivity(ContainerEvent(date: Date(), from: "stopped", to: "running",
                                                  kind: .group, subject: activitySubject(group),
                                                  action: summary))
                }
                return summary
            }
        )
        await refreshContainers(on: group.place)
    }

    /// Stops every member that is running, in **reverse** listed order.
    ///
    /// Reverse is the one piece of ordering a group can honour honestly: it costs nothing, and
    /// taking the web tier down before the database it talks to is what you would do by hand.
    /// It is not a dependency graph and must not be described as one — nothing here waits for
    /// anything, it is a sequence, not a schedule.
    ///
    /// Unlike Start, a failure here does **not** stop the run. If one member will not stop, the
    /// remaining ones still should — leaving a half-stopped group because of one stuck container
    /// helps nobody. Failures are collected and reported together.
    func stopGroup(_ group: ContainerGroup) async {
        guard !group.members.isEmpty else { return }
        await withProgress(
            title: title("Stop", group),
            command: groupCommandPreview(group, starting: false),
            kind: .groupAction,
            retry: { [weak self] in await self?.stopGroup(group) },
            work: { [weak self] progress in
                guard let self else { return "" }
                let cli = try self.cli(for: group.place)
                let running = runningContainerNames(on: group.place)
                var stopped = 0
                var failed: [String] = []
                for member in group.members.reversed() {
                    guard running.contains(member.name) else { continue }
                    let step = progress.begin("Stopping \(member.name)")
                    do {
                        // On a host, its own Flotilla records the stop as deliberate (Q53).
                        if group.place.isLocal { noteDeliberateStop(member.name) }
                        _ = try await Blocking.run { try cli.stop(member.name) }
                        stopped += 1
                        progress.finish(step, detail: nil)
                    } catch {
                        failed.append(member.name)
                        progress.finish(step, detail: "failed")
                    }
                }
                await refreshContainers(on: group.place)
                if stopped > 0 {
                    recordActivity(ContainerEvent(date: Date(), from: "running", to: "stopped",
                                                  kind: .group, subject: activitySubject(group),
                                                  action: "Stopped \(stopped)"))
                }
                if !failed.isEmpty {
                    throw GroupStopFailure(members: failed, stopped: stopped)
                }
                return stopped == 0 ? "Nothing was running" : "Stopped \(stopped)"
            }
        )
        await refreshContainers(on: group.place)
    }

    /// Stops everything that is running, then starts everything — one operation, not a stop
    /// followed by a start.
    ///
    /// Two calls would give you two progress panels for one intention, and worse, the second
    /// would begin from whatever the first left behind. Written out here so the whole thing
    /// succeeds or reports once, and so the stop half honours reverse order the way `stopGroup`
    /// does while the start half honours listed order.
    ///
    /// Like `startGroup`, a failure to start stops the run: there is no value in bringing up the
    /// things that talk to a database that would not come back.
    func restartGroup(_ group: ContainerGroup) async {
        guard !group.members.isEmpty else { return }
        await withProgress(
            title: title("Restart", group),
            command: groupCommandPreview(group, starting: false) + "\n"
                + groupCommandPreview(group, starting: true),
            kind: .groupAction,
            retry: { [weak self] in await self?.restartGroup(group) },
            work: { [weak self] progress in
                guard let self else { return "" }
                let cli = try self.cli(for: group.place)
                for member in group.members.reversed()
                where runningContainerNames(on: group.place).contains(member.name) {
                    let step = progress.begin("Stopping \(member.name)")
                    // A member that will not stop is reported and skipped rather than aborting:
                    // the restart's whole purpose is to get back to a known state.
                    if group.place.isLocal { noteDeliberateStop(member.name) }
                    _ = try? await Blocking.run { try cli.stop(member.name) }
                    progress.finish(step, detail: nil)
                }
                await refreshContainers(on: group.place)

                let started = try await startMembers(of: group, progress: progress,
                                                     skippingRunning: false)
                await refreshContainers(on: group.place)
                let summary = "Restarted \(started.count) of \(group.members.count)"
                recordActivity(ContainerEvent(date: Date(), from: "running", to: "running",
                                              kind: .group, subject: activitySubject(group), action: summary))
                return summary
            }
        )
        await refreshContainers(on: group.place)
    }

    /// Starts each member in listed order, waiting where a member names a `readyPort` (Q21
    /// amended, 6 October). Shared by Start and Restart so the two cannot disagree about order.
    ///
    /// **Start is not always `run`.** A member whose container already exists — the usual case
    /// after the group has been stopped once — is *started*, because `container run` would refuse
    /// the name as taken.
    ///
    /// The wait is skipped after the **last** member: it exists to hold back what comes next, and
    /// nothing does.
    private func startMembers(of group: ContainerGroup, progress: OperationProgress,
                              skippingRunning: Bool) async throws -> [String] {
        // Every Keychain-held value is read **before** anything starts, so a missing one stops the
        // group cleanly rather than half way through.
        let host = group.place
        let cli = try self.cli(for: host)
        // A member whose port was removed at load is not created until the owner answers the flag:
        // created now, its service would quietly not be published (Kyle, 20 October). Checked
        // before anything starts, like the secrets, so the usual case stops cleanly — and again
        // before each member's own `run` below (`MemberLaunch`), because a container that exists
        // now can be deleted while an earlier member waits for readiness. One whose container
        // exists only starts it.
        let existing = existingContainerNames(on: host)
        for (member, ports) in groups.unpublished(in: group) {
            if case .refuse = MemberLaunch.decide(exists: existing.contains(member.name), unpublishedPorts: ports) {
                throw GroupRunFailure(member: member.name, started: [],
                                      underlying: GroupStore.unpublishedSentence(member.name, ports)
                                          + " Edit the group to choose.")
            }
        }
        let values = try await secretValues(for: group, progress: progress)
        var started: [String] = []
        for (index, member) in group.members.enumerated() {
            let step = progress.begin("Starting \(member.name)")
            if skippingRunning, runningContainerNames(on: host).contains(member.name) {
                progress.finish(step, detail: "already running")
            } else {
                // Decided here, from the list and the flag as they are now, not as they were when
                // the run began (Kyle, 20 October, round 2).
                let launch = MemberLaunch.decide(exists: existingContainerNames(on: host).contains(member.name),
                                                 unpublishedPorts: unpublishedPorts(of: member, in: group))
                if case .refuse(let ports) = launch {
                    progress.finish(step, detail: "port removed", failed: true)
                    throw GroupRunFailure(member: member.name, started: started,
                                          underlying: GroupStore.unpublishedSentence(member.name, ports)
                                              + " Edit the group to choose.")
                }
                do {
                    try await prepareVolumeOwnership(cli: cli, host: host, image: member.image,
                        mounts: member.volumes, owners: member.requestedVolumeOwners, progress: progress)
                    if launch == .start {
                        _ = try await Blocking.run { try cli.start(member.name) }
                    } else {
                        // Secrets go to a host inside the validated `run` request, over the
                        // admin's mTLS connection — the same path a single container's env takes.
                        let env = try GroupSecrets.resolvedEnv(for: member, values: values)
                        let options = member.runOptions(network: group.network, env: env)
                        _ = try await Blocking.run {
                            try cli.run(image: member.image, options: options,
                                        command: member.command)
                        }
                    }
                } catch {
                    // Named plainly: which member, and what was already up when it stopped.
                    progress.finish(step, detail: "failed", failed: true)
                    // Anything the CLI echoed back is shown without the group's secret values.
                    var underlying = String(describing: error)
                    for value in values.values where value.count >= 4 {
                        underlying = underlying.replacingOccurrences(of: value, with: "••••")
                    }
                    throw GroupRunFailure(member: member.name, started: started, underlying: underlying)
                }
                started.append(member.name)
                progress.finish(step, detail: nil)
            }
            if let port = member.readyPort, index < group.members.count - 1 {
                try await waitUntilReady(member, of: group, port: port, started: started, progress: progress)
            }
        }
        return started
    }

    /// The member's removed ports as the store holds them now — empty once the owner has answered.
    private func unpublishedPorts(of member: GroupMember, in group: ContainerGroup) -> [String] {
        groups.unpublished(in: group).first { $0.member.id == member.id }?.ports ?? []
    }

    /// The group's Keychain-held values, by secret name. Only fetched when some member is about
    /// to be *created* — starting an existing container passes no environment at all.
    private func secretValues(for group: ContainerGroup,
                              progress: OperationProgress) async throws -> [String: String] {
        let existing = existingContainerNames(on: group.place)
        let needed = group.members.filter { !existing.contains($0.name) }
            .flatMap(\.secretEnv).map(\.secret)
        guard !needed.isEmpty else { return [:] }
        let step = progress.begin("Reading passwords from the Keychain")
        var values: [String: String] = [:]
        for secret in Set(needed) {
            let groupID = group.id
            guard let value = await Blocking.run({
                KeychainSecrets.value(group: groupID, secret: secret)
            }) else {
                progress.finish(step, detail: "missing", failed: true)
                throw GroupSecrets.MissingSecret(secret: secret)
            }
            values[secret] = value
        }
        progress.finish(step, detail: nil)
        return values
    }

    /// Holds the group until `member` accepts connections on `port`, or says why it gave up.
    ///
    /// On This Mac the probe goes to the container's own address. A host's containers sit on that
    /// Mac's private network, out of reach from here, so a host is asked to probe its own container
    /// (`.probePort`, wire version 13; Kyle, 12 October: a stack's database is published only on
    /// the host's gateway). A host too old to be asked is probed at its address where the port is
    /// published on every interface; otherwise the group waits only until the member is running,
    /// and the panel says so.
    private func waitUntilReady(_ member: GroupMember, of group: ContainerGroup, port: Int,
                                started: [String], progress: OperationProgress) async throws {
        let host = group.place
        let step = progress.begin("Waiting for \(member.name) on port \(port)")
        await refreshContainers(on: host)

        let probe: (@Sendable () async -> Bool)?
        switch host {
        case .local:
            guard let address = Readiness.address(fromIPv4: containers.first { $0.name == member.name }?.ipv4) else {
                progress.finish(step, detail: "no address", failed: true)
                throw GroupReadyFailure(member: member.name, port: port, outcome: .stopped, started: started)
            }
            probe = { await Blocking.run { TCPProbe.accepts(host: address, port: port) } }
        case .peer(let fingerprint):
            if let remote = hostMode.remoteHost(for: fingerprint),
               (remote.protocolVersion ?? 0) >= WireProtocol.probePortVersion {
                let name = member.name
                probe = { (try? await remote.call(.probePort(container: name, port: port)))?.stdout == "open" }
            } else {
                // Only a port published on every interface can be reached from here: one bound to
                // the host's gateway or to 127.0.0.1 is closed to other Macs.
                let published = member.ports.lazy.compactMap { spec -> Int? in
                    guard StackPlanner.containerPort(fromPublishSpec: spec) == port else { return nil }
                    let parts = (spec.split(separator: "/").first.map(String.init) ?? spec).split(separator: ":")
                    guard parts.count == 2 || parts.first == "0.0.0.0" else { return nil }
                    return StackPlanner.hostPort(fromPublishSpec: spec)
                }.first
                let name = hostMode.probeAddress(for: fingerprint)
                let address = await Self.resolve(name, within: 5)
                if let address, let published {
                    probe = { await Blocking.run { TCPProbe.accepts(host: address, port: published) } }
                } else {
                    probe = nil
                }
            }
        }

        guard let probe else {
            // Can't be probed from here: wait for it to be running, and say that is all it was.
            if runningContainerNames(on: host).contains(member.name) {
                progress.finish(step, detail: "running; port \(port) couldn't be checked from here — update Flotilla on \(groupHostName(group)) so it can")
                return
            }
            progress.finish(step, detail: "stopped", failed: true)
            throw GroupReadyFailure(member: member.name, port: port, outcome: .stopped, started: started)
        }

        var polls = 0
        let outcome = await Readiness.wait(
            sleep: { try? await Task.sleep(for: .seconds($0)) },
            isRunning: { [weak self] in
                // The list is re-read every fifth poll: often enough to notice a database that
                // exited on bad settings, rarely enough not to spawn a process every second.
                guard let self else { return false }
                polls += 1
                guard polls % 5 == 0 else { return true }
                await self.refreshContainers(on: host)
                return self.runningContainerNames(on: host).contains(member.name)
            },
            probe: probe)
        switch outcome {
        case .ready:
            progress.finish(step, detail: "ready")
        case .timedOut, .stopped:
            progress.finish(step, detail: outcome == .stopped ? "stopped" : "no answer",
                            failed: true)
            throw GroupReadyFailure(member: member.name, port: port, outcome: outcome,
                                    started: started)
        }
    }

    /// A host name's IPv4 address, giving up after `seconds`: `getaddrinfo` can't be cancelled,
    /// and a lookup that hangs must not hold a group start past its own deadline (Kyle).
    static func resolve(_ name: String?, within seconds: Double) async -> String? {
        guard let name else { return nil }
        // A continuation resumed by whichever finishes first. (A task group would wait for the
        // lookup anyway: it doesn't return until every child has.)
        let once = FirstAnswer()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { once.answer(TCPProbe.ipv4(for: name), to: continuation) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.answer(nil, to: continuation) }
        }
    }

    /// What the progress panel shows as the command, since a group is several of them.
    ///
    /// Deliberately not a single joined line pretending to be one invocation: it is one line per
    /// member, in the order they will run, so the panel's "command" is honest about being a
    /// sequence. A member that already exists shows `container start`, matching what will
    /// actually be issued.
    private func groupCommandPreview(_ group: ContainerGroup, starting: Bool) -> String {
        let members = starting ? group.members : Array(group.members.reversed())
        let existing = existingContainerNames(on: group.place)
        return members.map { member in
            if !starting { return "container stop \(member.name)" }
            if existing.contains(member.name) { return "container start \(member.name)" }
            // Through the allowlist, so the panel shows the argv that will actually be
            // executed. Building it straight from `runArguments` prints the `--` that only
            // the input grammar carries, and a panel that shows a token the CLI would refuse
            // is the same lie the Run sheet's preview was telling.
            //
            // **`auditDescription`, not `localPreview`.** That property's own rule is that its
            // audience is "the person at the keyboard who supplied the values" — and for a
            // group they did not. A group replays what was saved, possibly weeks ago, from one
            // click on a table row, with nothing else on screen showing it. A WordPress group
            // put `MYSQL_ROOT_PASSWORD=…` and `WORDPRESS_DB_PASSWORD=…` in 13pt monospace in
            // this panel, where it stayed until dismissed and went straight into a screenshot.
            // That is SEC-03 with extra steps. The shaped form still names every flag and
            // leaves the ports, image and container name legible.
            switch AppModel.runPreview(image: member.image,
                                       options: member.runOptions(network: group.network),
                                       command: member.command) {
            case .success(let validated): return validated.auditDescription
            case .failure: return "container run … \(member.image)"
            }
        }.joined(separator: "\n")
    }
}

/// A member refused to start. Carries what was already up, because the useful question after a
/// group half-starts is "what is running now".
struct GroupRunFailure: Error, CustomStringConvertible {
    let member: String
    let started: [String]
    let underlying: String

    var description: String {
        let prefix = "“\(member)” would not start. \(underlying)"
        guard !started.isEmpty else { return prefix }
        return "\(prefix)\n\nStill running from this group: \(started.joined(separator: ", "))."
    }
}

/// A member started but never became ready. The rest of the group was not started, and the
/// message says so rather than leaving it to be inferred from what is missing.
struct GroupReadyFailure: Error, CustomStringConvertible {
    let member: String
    let port: Int
    let outcome: Readiness.Outcome
    let started: [String]

    var description: String {
        let what = switch outcome {
        case .stopped:
            "“\(member)” stopped before it accepted connections on port \(port). Its logs say why."
        default:
            "“\(member)” didn't accept connections on port \(port) within "
                + "\(Int(Readiness.defaultTimeout / 60)) minutes. It's still running; check its logs."
        }
        let tail = " The services after it weren't started."
        // A member that stopped is not "running from this group", however it started.
        let running = outcome == .stopped ? started.filter { $0 != member } : started
        guard !running.isEmpty else { return what + tail }
        return what + tail + "\n\nRunning from this group: \(running.joined(separator: ", "))."
    }
}

/// One or more members would not stop. The rest of the group was stopped anyway.
struct GroupStopFailure: Error, CustomStringConvertible {
    let members: [String]
    let stopped: Int

    var description: String {
        let names = members.joined(separator: ", ")
        let tail = stopped == 0 ? "" : " The other \(stopped) stopped."
        return members.count == 1
            ? "“\(names)” would not stop.\(tail)"
            : "These would not stop: \(names).\(tail)"
    }
}

extension AppModel {
    /// Deletes a group, its tags with it, and notes it in the feed.
    ///
    /// Tag cleanup belongs here rather than in `GroupStore`, which knows nothing about tags, and
    /// it must be here rather than left to the user: a deleted group's assignments would
    /// otherwise sit in the plist forever keyed to an id nothing can show. That is different
    /// from `TagBook.removeAssignments(ofKind:notIn:)`, which is never automatic — a *container*
    /// can come back, and a group you just deleted cannot.
    func deleteGroup(_ group: ContainerGroup) {
        tags.clearTags(on: TagSubject(kind: .group, id: group.id))
        // Its passwords go with it: nothing else can name them once the group is gone. The
        // containers' volumes still hold whatever the database was initialised with.
        for secret in GroupSecrets.secretNames(in: group) {
            KeychainSecrets.delete(group: group.id, secret: secret)
        }
        groups.deleteGroup(group.id)
        recordActivity(ContainerEvent(date: Date(), from: "present", to: "absent",
                                      kind: .group, subject: activitySubject(group), action: "Deleted"))
    }

    /// Deletes a group's containers on the Mac it runs on — "Delete Group and Containers".
    func deleteContainers(_ names: Set<String>, of group: ContainerGroup) async {
        guard !group.place.isLocal else { return await performBulk(.delete, on: names) }
        for container in containers(on: group.place) where names.contains(container.id) {
            await perform(.delete, on: container, host: group.place)
        }
    }

    /// Starts several groups, one after another. Sequential rather than concurrent: two groups
    /// starting at once would interleave their progress panels, and the runtime is the
    /// bottleneck anyway.
    func startGroups(_ selected: [ContainerGroup]) async {
        for group in selected { await startGroup(group) }
    }

    func stopGroups(_ selected: [ContainerGroup]) async {
        for group in selected { await stopGroup(group) }
    }
}

/// Resumes a continuation once, with the first answer to arrive.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false

    func answer(_ value: String?, to continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        let first = !answered
        answered = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}
