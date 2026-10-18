import Foundation
import FlotillaCore

extension AppModel {
    /// The same validated container commands on This Mac and peers, without a new wire request
    /// or administrator operation. Mutable receipts live in the app, keyed by the host identity.
    func prepareVolumeOwnership(cli: ContainerCLI, host: HostRef, image: String, mounts: [String],
                                owners: [String: VolumeOwner] = [:], requireNewVolumes: Bool = false, progress: OperationProgress) async throws {
        let hostKey: String
        switch host {
        case .local: hostKey = "local"
        case .peer(let fingerprint): hostKey = fingerprint.hex
        }
        let store = volumeSetups
        try await Blocking.run {
            try store.prepare(cli: cli, host: hostKey, image: image, mounts: mounts, newOwners: owners, requireNewVolumes: requireNewVolumes) { line in
                Task { @MainActor in progress.note(line) }
            }
        }
    }
}
