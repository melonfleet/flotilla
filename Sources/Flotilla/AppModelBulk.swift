import Foundation
import FlotillaCore

@MainActor
extension AppModel {
    /// Runs a batch sequentially so each id has one well-defined busy interval, but collects every
    /// failure before surfacing one bounded summary. Refreshing here, after the loop, also avoids
    /// replacing the list under the remaining operations.
    ///
    /// `kind` is what the batch marks busy, and it must be the kind that type's single-row path
    /// marks or the row's own controls stay enabled while the batch is acting on it. It used to be
    /// a private `BusyScope` enum with two cases — machines, and *everything else sharing one
    /// namespace* — which is gone now that `BusySet` keys by kind: passing the resource's own kind
    /// is both the right answer and the only one available.
    private func performResourceBulk(
        _ ids: Set<String>,
        pluralNoun: String,
        verb: String,
        kind: ActivityKind,
        operation: (String) async throws -> Void,
        refresh: () async -> Void
    ) async {
        var failures: [(id: String, error: String)] = []

        for id in ids.sorted() {
            guard !isBusy(id, kind: kind) else { continue }

            markBusy(id, kind: kind)
            do {
                try await operation(id)
            } catch {
                failures.append((id, String(describing: error)))
            }
            clearBusy(id, kind: kind)
        }

        if let first = failures.first {
            if failures.count == 1 {
                actionError = "\(verb) failed for \(first.id): \(first.error)"
            } else {
                // A handful of names makes the summary useful without turning the alert into a
                // wall of ids; the true count is never abbreviated.
                let named = failures.prefix(4).map(\.id).joined(separator: ", ")
                let rest = failures.count > 4 ? ", and \(failures.count - 4) more" : ""
                actionError = """
                    \(verb) failed for \(failures.count) of \(ids.count) \(pluralNoun) \
                    (\(named)\(rest)).

                    First error: \(first.error)
                    """
            }
        }

        await refresh()
    }

    func performMachineBulk(_ action: MachineAction, on ids: Set<ContainerMachine.ID>) async {
        let verb: String
        switch action {
        case .start: verb = "Start"
        case .stop: verb = "Stop"
        case .restart: verb = "Restart"
        case .delete: verb = "Delete"
        case .setDefault: verb = "Set default"
        }

        await performResourceBulk(
            ids,
            pluralNoun: "machines",
            verb: verb,
            kind: .machine,
            operation: { [cli] id in
                _ = try await Task.detached { () -> CommandResult in
                    switch action {
                    case .start: try cli.startMachine(id)
                    case .stop: try cli.stopMachine(id)
                    case .restart: try cli.restartMachine(id)
                    case .delete: try cli.deleteMachine(id)
                    case .setDefault: try cli.setDefaultMachine(id)
                    }
                }.value

                // A stopped, restarted or deleted VM cannot retain a live shell even when the
                // command itself succeeded, so stale terminal sessions leave with it.
                if action == .stop || action == .delete || action == .restart {
                    self.machineTerminals.closeAll(for: id)
                }
                if action == .restart {
                    self.recordActivity(ContainerEvent(date: Date(), from: "running", to: "running",
                                                       kind: .machine, subject: id,
                                                       action: "Restarted"))
                }
            },
            refresh: { await self.refreshMachines() }
        )
    }

    func deleteVolumes(_ ids: Set<ContainerVolume.ID>) async {
        let names = Dictionary(uniqueKeysWithValues: volumes.map { ($0.id, $0.name) })
        await performResourceBulk(
            ids,
            pluralNoun: "volumes",
            verb: "Delete",
            kind: .volume,
            operation: { [cli] id in
                guard let name = names[id] else { throw BulkActionError.resourceDisappeared(id) }
                _ = try await Task.detached { try cli.removeVolume(name) }.value
            },
            refresh: { await self.refreshVolumes() }
        )
    }

    func deleteNetworks(_ ids: Set<ContainerNetwork.ID>) async {
        await performResourceBulk(
            ids,
            pluralNoun: "networks",
            verb: "Delete",
            kind: .network,
            operation: { [cli] id in
                _ = try await Task.detached { try cli.removeNetwork(id) }.value
            },
            refresh: { await self.refreshNetworks() }
        )
    }

    func deleteImages(_ ids: Set<ContainerImage.ID>) async {
        let references = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0.reference) })
        await performResourceBulk(
            ids,
            pluralNoun: "images",
            verb: "Delete",
            kind: .image,
            operation: { [cli] id in
                guard let reference = references[id] else { throw BulkActionError.resourceDisappeared(id) }
                _ = try await Task.detached { try cli.removeImage(reference) }.value
            },
            refresh: { await self.refreshImages() }
        )
    }
}

private enum BulkActionError: Error, CustomStringConvertible {
    case resourceDisappeared(String)

    var description: String {
        switch self {
        case .resourceDisappeared(let id): "\(id) is no longer available"
        }
    }
}
