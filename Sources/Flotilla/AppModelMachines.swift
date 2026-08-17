import Foundation
import FlotillaCore

/// Machines — the Linux micro-VMs `container` runs containers inside.
///
/// A separate file from `AppModel` for the same reason `AppModelDetail` is: this is a distinct
/// surface and keeping it apart makes ownership obvious. It shares **this** model's `cli`, so
/// every call crosses the one `Allowlist` and `MountPolicy` boundary rather than a second
/// instance's — the mistake `AppModelDetail` made and had corrected.
///
/// Every mutation is deliberately loud. A machine is not a container: it is the VM every
/// container on this host runs inside, so stopping one stops everything in it and deleting one
/// destroys the substrate. `research/VM-SECURITY-REVIEW.md` is explicit that these are "not nine
/// ordinary additions", and the UI treats them accordingly.
@MainActor
extension AppModel {

    // MARK: Loading

    func refreshMachines() async {
        guard runtimeUsable else { return }
        machinesState = .loading
        do {
            let fetched = try await Task.detached { [cli] in try cli.machines() }.value
            // Same equality guard as `containers`: `@Observable` notifies on every write, so an
            // unconditional assignment invalidates every view on each poll even when nothing
            // moved. That was half of the original flicker.
            if fetched != machines {
                recordMachineTransitions(previous: machines, current: fetched)
                machines = fetched
            }
            machinesState = .loaded
            machinesLastRefresh = Date()
        } catch {
            machines = []
            machinesState = .failed(describe(error))
            record("Could not list machines: \(error)", subsystem: "machines")
        }
    }

    /// Notes state changes so the activity strip has something to show.
    ///
    /// Mirrors `recordTransitions` for containers, including its rule that a **first sighting is
    /// not a transition** — recording "appeared" for every machine present at launch would fill
    /// the strip with noise about nothing having happened.
    func recordMachineTransitions(previous: [ContainerMachine], current: [ContainerMachine]) {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.status) })
        for machine in current {
            guard let was = before[machine.id] else { continue }
            guard was.caseInsensitiveCompare(machine.status) != .orderedSame else { continue }
            recordActivity(ContainerEvent(date: Date(), from: was, to: machine.status,
                                          kind: .machine, subject: machine.id))
        }
    }

    // MARK: Actions

    enum MachineAction { case start, stop, restart, delete, setDefault }

    /// Runs one action and reloads. `busyMachines` disables the row's controls while it is in
    /// flight, because a second click on Stop is a second VM shutdown.
    func perform(_ action: MachineAction, on machine: ContainerMachine) async {
        guard !busyMachines.contains(machine.id) else { return }
        busyMachines.insert(machine.id)
        defer { busyMachines.remove(machine.id) }

        do {
            _ = try await Task.detached { [cli] in
                switch action {
                case .start: try cli.startMachine(machine.id)
                case .stop: try cli.stopMachine(machine.id)
                case .restart: try cli.restartMachine(machine.id)
                case .delete: try cli.deleteMachine(machine.id)
                case .setDefault: try cli.setDefaultMachine(machine.id)
                }
            }.value

            // Shells live inside the machine. Stopping or deleting it kills them whether we
            // tidy up or not, so drop them rather than leaving dead terminals on screen.
            // `.restart` too: the VM goes down in the middle, so any shell attached to it is
            // already dead by the time it comes back.
            if action == .stop || action == .delete || action == .restart {
                machineTerminals.closeAll(for: machine.id)
            }
            // Same blind spot as containers: a restart leaves the machine running, so
            // `recordMachineTransitions` sees nothing between polls.
            if action == .restart {
                recordActivity(ContainerEvent(date: Date(), from: "running", to: "running",
                                              kind: .machine, subject: machine.id,
                                              action: "Restarted"))
            }
            await refreshMachines()
        } catch {
            actionError = describe(error)
            record("Machine \(action) failed for \(machine.id): \(error)", subsystem: "machines")
        }
    }

    func createMachine(image: String, name: String?, cpus: Int?, memory: String?,
                       homeMount: String?) async -> Bool {
        do {
            _ = try await Task.detached { [cli] in
                try cli.createMachine(image: image, name: name, cpus: cpus,
                                      memory: memory, homeMount: homeMount)
            }.value
            await refreshMachines()
            return true
        } catch {
            actionError = describe(error)
            record("Machine create failed for \(image): \(error)", subsystem: "machines")
            return false
        }
    }

    /// Applies configuration. **Takes effect after a restart** — the CLI says so and the UI must
    /// too, or a form that silently changes nothing until the next boot is a trap. The caller
    /// owns telling the user; this just reports whether the write landed.
    func applyMachineSettings(_ id: String, cpus: Int?, memory: String?,
                              homeMount: String?) async -> Bool {
        do {
            _ = try await Task.detached { [cli] in
                try cli.setMachine(id, cpus: cpus, memory: memory, homeMount: homeMount)
            }.value
            await refreshMachines()
            return true
        } catch {
            actionError = describe(error)
            record("Machine set failed for \(id): \(error)", subsystem: "machines")
            return false
        }
    }

    /// The **full** record for one machine.
    ///
    /// `machine list` returns a deliberately thin row — no image, no start time, no home-mount,
    /// no platform — while `machine inspect` returns all of it. The detail Overview was
    /// rendering "Started —" and "Not reported by `machine list`" for fields that were one call
    /// away, which is the same "a card that states nothing" failure as an inert setting.
    ///
    /// Returns `nil` rather than throwing: this only enriches a view that already has a usable
    /// record, so a failure should quietly leave the thin one in place, not blank the screen.
    func inspectMachine(_ id: String) async -> ContainerMachine? {
        do {
            return try await Task.detached { [cli] in try cli.inspectMachine(id) }.value
        } catch {
            record("Could not inspect machine \(id): \(error)", subsystem: "machines")
            return nil
        }
    }

    func machineLogs(for id: String, lines: Int, boot: Bool) async throws -> LogChunk {
        try await Task.detached { [cli] in
            try cli.machineLogs(id, lines: lines, boot: boot)
        }.value
    }

    /// The CLI's own error text is more useful than Swift's `String(describing:)` on a thrown
    /// enum, so prefer it where we have it.
    private func describe(_ error: any Error) -> String {
        if let cliError = error as? ContainerCLIError { return String(describing: cliError) }
        return String(describing: error)
    }
}
