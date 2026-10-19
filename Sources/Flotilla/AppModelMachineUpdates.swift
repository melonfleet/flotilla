import Foundation
import FlotillaCore

struct MachineUpdateCheckState {
    var checking = false
    var report: MachineUpdateReport?
    var error: String?
    var lastAttempt: Date?
}

@MainActor
extension AppModel {
    /// Called only by the machine page's button. The normal poll never calls this.
    func checkMachineUpdates(_ id: String) async {
        guard runtimeUsable, machines.contains(where: { $0.id == id && $0.isRunning }),
              !isBusy(id, kind: .machine) else { return }
        let generation = machineGenerations[id]
        markBusy(id, kind: .machine)
        machineUpdateChecks[id] = .init(checking: true)
        defer { clearBusy(id, kind: .machine) }
        do {
            let report = try await Blocking.run { [cli] in try cli.checkMachineUpdates(id) }
            guard machineGenerations[id] == generation else { return }
            machineUpdateChecks[id] = .init(report: report, lastAttempt: report.checkedAt)
        } catch {
            guard machineGenerations[id] == generation else { return }
            machineUpdateChecks[id] = .init(error: describe(error), lastAttempt: Date())
        }
    }
}
