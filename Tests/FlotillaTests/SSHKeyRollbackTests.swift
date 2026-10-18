import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

/// `SSHKeySetup.rollBack` with `SSHKeyState.RollbackOps` on a real directory: what it moves, where,
/// and that nothing it finds is ever gone afterwards.
@Suite struct SSHKeyRollbackTests {
    private let date = Date(timeIntervalSince1970: 1_792_331_000)  // 2026-10-18 13:43:20 UTC
    private let utc = TimeZone(identifier: "UTC")!

    /// A fresh `<tmp>/flotilla-ssh-XXXXXX/.ssh`, and the directory to remove afterwards.
    private func scratch() throws -> (ssh: String, root: String) {
        var template = Array((NSTemporaryDirectory() + "flotilla-ssh-XXXXXX").utf8CString)
        try #require(mkdtemp(&template) != nil)
        let root = String(cString: template)
        let ssh = root + "/.ssh"
        try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: false)
        return (ssh, root)
    }

    private func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// The old pair renamed aside, as Regenerate leaves it before ssh-keygen runs, and the snapshot.
    private func archived(_ ssh: String) throws -> ([(from: String, to: String)], SSHKeySetup.KeygenSnapshot) {
        let moves = [(from: ssh + "/flotilla_ed25519", to: ssh + "/flotilla_ed25519.old-2026-10-18"),
                     (from: ssh + "/flotilla_ed25519.pub", to: ssh + "/flotilla_ed25519.old-2026-10-18.pub")]
        try write("old private", moves[0].to)
        try write("old public", moves[1].to)
        let stamps = moves.compactMap { SSHKeyState.stamp($0.to) }
        let snapshot = try #require(SSHKeySetup.KeygenSnapshot(sshDirectory: ssh, archived: stamps, stamp: SSHKeyState.stamp))
        return (moves, snapshot)
    }

    /// Kyle's reproduction: a file another process creates at the key path while ssh-keygen runs.
    /// It is moved into the quarantine with ssh-keygen's half, intact, and the old key comes back.
    @Test func anExternalFileMadeDuringKeygenSurvivesInTheQuarantine() throws {
        let (ssh, root) = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (moves, snapshot) = try archived(ssh)
        try write("half-made", ssh + "/flotilla_ed25519")
        try write("another process's file", ssh + "/flotilla_ed25519.pub")
        let output = SSHKeySetup.keygenOutput(after: snapshot, stamp: SSHKeyState.stamp)

        let result = SSHKeySetup.rollBack(sshDirectory: ssh, archive: moves, made: output.made,
                                          date: date, timeZone: utc, ops: SSHKeyState.RollbackOps())
        let folder = ssh + "/flotilla-rollback-2026-10-18-134320"
        #expect(result.folder == folder)
        #expect(try read(folder + "/flotilla_ed25519.pub") == "another process's file")
        #expect(try read(folder + "/flotilla_ed25519") == "half-made")
        #expect(try read(ssh + "/flotilla_ed25519") == "old private")
        #expect(try read(ssh + "/flotilla_ed25519.pub") == "old public")
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func nothingLeftRestoresTheOldKeyAndLeavesNoFolder() throws {
        let (ssh, root) = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (moves, snapshot) = try archived(ssh)
        let output = SSHKeySetup.keygenOutput(after: snapshot, stamp: SSHKeyState.stamp)

        let result = SSHKeySetup.rollBack(sshDirectory: ssh, archive: moves, made: output.made,
                                          date: date, timeZone: utc, ops: SSHKeyState.RollbackOps())
        #expect(result.folder == nil && result.restored.count == 2)
        #expect(try read(ssh + "/flotilla_ed25519") == "old private")
        #expect(try FileManager.default.contentsOfDirectory(atPath: ssh).sorted() == ["flotilla_ed25519", "flotilla_ed25519.pub"])
    }

    /// A symlink planted at the key path is moved as itself; what it points at is not touched.
    @Test func aPlantedSymlinkIsMovedAndItsTargetIsUntouched() throws {
        let (ssh, root) = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (moves, _) = try archived(ssh)
        try write("precious", root + "/elsewhere")
        try FileManager.default.createSymbolicLink(atPath: ssh + "/flotilla_ed25519.pub", withDestinationPath: root + "/elsewhere")

        let result = SSHKeySetup.rollBack(sshDirectory: ssh, archive: moves, made: [:],
                                          date: date, timeZone: utc, ops: SSHKeyState.RollbackOps())
        let folder = try #require(result.folder)
        #expect(result.moved == [.init(path: ssh + "/flotilla_ed25519.pub", madeByKeygen: false)])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/flotilla_ed25519.pub") == root + "/elsewhere")
        #expect(try read(root + "/elsewhere") == "precious")
        #expect(try read(ssh + "/flotilla_ed25519.pub") == "old public")
    }

    /// A folder already at the name is never used, whatever is in it.
    @Test func anExistingFolderAtTheNameIsLeftAlone() throws {
        let (ssh, root) = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let taken = ssh + "/flotilla-rollback-2026-10-18-134320"
        try FileManager.default.createDirectory(atPath: taken, withIntermediateDirectories: false)
        try write("theirs", taken + "/flotilla_ed25519")
        try write("half-made", ssh + "/flotilla_ed25519")

        let result = SSHKeySetup.rollBack(sshDirectory: ssh, archive: [], made: [:],
                                          date: date, timeZone: utc, ops: SSHKeyState.RollbackOps())
        #expect(result.folder == taken + "-2")
        #expect(try read(taken + "/flotilla_ed25519") == "theirs")
        #expect(try read(taken + "-2/flotilla_ed25519") == "half-made")
    }
}
