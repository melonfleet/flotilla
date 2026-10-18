import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

/// `SSHKeyState.remove` on a real directory: the private folder it makes, and what it leaves.
@Suite struct SSHKeyRollbackTests {
    private func scratch() throws -> String {
        var template = Array((NSTemporaryDirectory() + "flotilla-ssh-XXXXXX").utf8CString)
        try #require(mkdtemp(&template) != nil)
        return String(cString: template)
    }

    private func leftovers(_ directory: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix(".flotilla-rollback-") }
    }

    @Test func theFileKeygenLeftIsRemovedAndThePrivateFolderWithIt() throws {
        let ssh = try scratch()
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let path = ssh + "/flotilla_ed25519"
        try Data("made".utf8).write(to: URL(fileURLWithPath: path))
        let made = try #require(SSHKeyState.stamp(path))

        #expect(SSHKeyState.remove(path, ifStill: made) == .removed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try leftovers(ssh).isEmpty)
    }

    @Test func aFileThatIsNotTheOneMadeIsPutBackUntouched() throws {
        let ssh = try scratch()
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let path = ssh + "/flotilla_ed25519"
        try Data("made".utf8).write(to: URL(fileURLWithPath: path))
        let made = try #require(SSHKeyState.stamp(path))
        // Another writer replaces it: a different inode at the same name.
        try FileManager.default.removeItem(atPath: path)
        try Data("someone else's".utf8).write(to: URL(fileURLWithPath: ssh + "/other"))
        try FileManager.default.moveItem(atPath: ssh + "/other", toPath: path)

        #expect(SSHKeyState.remove(path, ifStill: made) == .notMade)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else's")
        #expect(try leftovers(ssh).isEmpty)
    }

    @Test func nothingAtThePathRemovesNothing() throws {
        let ssh = try scratch()
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let stamp = SSHKeySetup.FileStamp(device: 1, inode: 1, isRegularFile: true, ownedByUser: true)
        #expect(SSHKeyState.remove(ssh + "/flotilla_ed25519", ifStill: stamp) == .notMade)
        #expect(try leftovers(ssh).isEmpty)
    }
}
