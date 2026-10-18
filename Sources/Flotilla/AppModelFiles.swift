import Foundation
import AppKit
import FlotillaCore

enum FilesViewMode: String, CaseIterable {
    case icons = "Icons", list = "List", columns = "Columns"
    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }
}

extension AppModel {
    func listDirectory(_ path: String, in containerID: String) async throws -> [FileEntry] {
        try await Task.detached { [cli] in try cli.listDirectory(containerID, path: path) }.value
    }

    func searchFiles(_ term: String, directory: String, in containerID: String) async throws -> FileSearchResults {
        try await Task.detached { [cli] in try cli.searchFiles(containerID, directory: directory, term: term) }.value
    }

    func changeFiles(_ command: FileCommand, in containerID: String) async throws {
        try await Task.detached { [cli] in try cli.performFileCommand(command, in: containerID) }.value
    }

    /// The save/open panel grants only its chosen endpoint for this invocation. Never widen the
    /// shared CLI (or a remote CLI). The copy grammar still checks that endpoint via MountPolicy.
    func download(_ containerPath: String, from containerID: String, to hostURL: URL) async throws {
        try await Task.detached { [cli] in
            guard cli.wirePolicy == .localOwner else { throw ContainerCLIError.unsupported("Remote file transfer is unavailable.") }
            let scoped = ContainerCLI(host: cli.host, mountPolicy: .roots([hostURL.path]),
                                      execPolicy: cli.execPolicy, wirePolicy: cli.wirePolicy)
            try scoped.copy(from: "\(containerID):\(containerPath)", to: hostURL.path)
        }.value
    }

    func upload(_ hostURL: URL, to containerPath: String, in containerID: String) async throws {
        try await Task.detached { [cli] in
            guard cli.wirePolicy == .localOwner, cli.execPolicy == .interactiveShell else {
                throw ContainerCLIError.unsupported("Only this Mac's owner can upload files.")
            }
            let scoped = ContainerCLI(host: cli.host, mountPolicy: .roots([hostURL.path]),
                                      execPolicy: cli.execPolicy, wirePolicy: cli.wirePolicy)
            try scoped.copy(from: hostURL.path, to: "\(containerID):\(containerPath)")
        }.value
    }
}

/// Open/Share copies live for this app session, so receivers can read them after the picker
/// closes. Each copy gets its own subdirectory; equal basenames cannot overwrite one another.
@MainActor
final class FileTemporaryStore {
    static let shared = FileTemporaryStore()
    private var root: URL?
    func destination(named name: String) throws -> URL {
        guard FileCommand.isValidName(name) else { throw ContainerCLIError.unsupported("Invalid file name.") }
        let fm = FileManager.default
        if root == nil {
            let made = fm.temporaryDirectory.appendingPathComponent("Flotilla-Files-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: made, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            root = made
        }
        guard let root else { throw ContainerCLIError.unsupported("Cannot create temporary folder.") }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent(name)
    }
    func cleanUp() {
        guard let root else { return }
        do { try FileManager.default.removeItem(at: root); self.root = nil }
        catch { NSLog("Could not clean up Files temporary directory: %@", error.localizedDescription) }
    }
}
