import Foundation
import FlotillaCore

/// Starting and stopping a saved group.
///
/// Everything here is a loop over commands `AppModel` already issues for one container, through
/// the same `ContainerCLI` and therefore the same `Allowlist`. A group adds no command to the
/// boundary — see `ContainerGroup` for why that is the point rather than a coincidence.
extension AppModel {

    /// The group's state, derived from the live container list rather than from anything stored.
    func state(of group: ContainerGroup) -> GroupState {
        group.state(runningNames: runningContainerNames, existingNames: existingContainerNames)
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
            title: "Start “\(group.name)”",
            command: groupCommandPreview(group, starting: true),
            work: { [weak self] progress in
                guard let self else { return "" }
                var started: [String] = []
                for member in group.members {
                    let step = progress.begin("Starting \(member.name)")
                    if runningContainerNames.contains(member.name) {
                        progress.finish(step, detail: "already running")
                        continue
                    }
                    do {
                        if existingContainerNames.contains(member.name) {
                            _ = try await Task.detached { [cli] in try cli.start(member.name) }.value
                        } else {
                            let options = member.runOptions(network: group.network)
                            _ = try await Task.detached { [cli] in
                                try cli.run(image: member.image, options: options,
                                            command: member.command)
                            }.value
                        }
                    } catch {
                        // Named plainly: which member, and what was already up when it stopped.
                        progress.finish(step, detail: "failed")
                        throw GroupRunFailure(member: member.name, started: started,
                                              underlying: String(describing: error))
                    }
                    started.append(member.name)
                    progress.finish(step, detail: nil)
                }
                await refresh()
                return started.isEmpty
                    ? "Every service was already running"
                    : "Started \(started.count) of \(group.members.count)"
            }
        )
        await refresh()
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
            title: "Stop “\(group.name)”",
            command: groupCommandPreview(group, starting: false),
            work: { [weak self] progress in
                guard let self else { return "" }
                var stopped = 0
                var failed: [String] = []
                for member in group.members.reversed() {
                    guard runningContainerNames.contains(member.name) else { continue }
                    let step = progress.begin("Stopping \(member.name)")
                    do {
                        _ = try await Task.detached { [cli] in try cli.stop(member.name) }.value
                        stopped += 1
                        progress.finish(step, detail: nil)
                    } catch {
                        failed.append(member.name)
                        progress.finish(step, detail: "failed")
                    }
                }
                await refresh()
                if !failed.isEmpty {
                    throw GroupStopFailure(members: failed, stopped: stopped)
                }
                return stopped == 0 ? "Nothing was running" : "Stopped \(stopped)"
            }
        )
        await refresh()
    }

    /// What the progress panel shows as the command, since a group is several of them.
    ///
    /// Deliberately not a single joined line pretending to be one invocation: it is one line per
    /// member, in the order they will run, so the panel's "command" is honest about being a
    /// sequence. A member that already exists shows `container start`, matching what will
    /// actually be issued.
    private func groupCommandPreview(_ group: ContainerGroup, starting: Bool) -> String {
        let members = starting ? group.members : Array(group.members.reversed())
        return members.map { member in
            if !starting { return "container stop \(member.name)" }
            if existingContainerNames.contains(member.name) { return "container start \(member.name)" }
            // Through the allowlist, so the panel shows the argv that will actually be
            // executed. Building it straight from `runArguments` prints the `--` that only
            // the input grammar carries, and a panel that shows a token the CLI would refuse
            // is the same lie the Run sheet's preview was telling.
            switch AppModel.runPreview(image: member.image,
                                       options: member.runOptions(network: group.network),
                                       command: member.command) {
            case .success(let validated): return validated.localPreview
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
