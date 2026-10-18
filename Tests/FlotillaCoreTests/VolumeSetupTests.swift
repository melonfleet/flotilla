import Foundation
import Testing
@testable import FlotillaCore

private let setupTestDigest = String(repeating: "a", count: 64) // synthetic; never a production pin
private let setupMount = "fresh-data:/var/lib/grafana"
private let setupOwner = VolumeOwner(uid: 472, gid: 0)

/// Test double, not a captured CLI fixture. Uses the real volume model to simulate transitions.
private final class VolumeSetupHost: ContainerHost, @unchecked Sendable {
    var volumes: [ContainerVolume] = []
    var commands: [[String]] = []
    var failHelper = false
    func run(_ args: [String]) throws -> CommandResult {
        commands.append(args)
        if args.starts(with: ["volume", "list"]) {
            return .init(stdout: String(decoding: try JSONEncoder().encode(volumes), as: UTF8.self), stderr: "", exitCode: 0)
        }
        if args.starts(with: ["volume", "create"]) {
            let name = args.last!
            if volumes.contains(where: { $0.name == name }) {
                return .init(stdout: "", stderr: "already exists", exitCode: 1)
            }
            var labels: [String: String] = [:]
            for index in args.indices where args[index] == "--label" {
                let pair = args[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                labels[pair[0]] = pair[1]
            }
            volumes.append(.init(id: name, configuration: .init(name: name, labels: labels)))
        }
        return .init(stdout: "", stderr: failHelper && args.first == "run" ? "interrupted" : "",
                     exitCode: failHelper && args.first == "run" ? 1 : 0)
    }
}

private func setupFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("volume-setup-test-\(UUID()).json")
}
private func setupCLI(_ host: VolumeSetupHost, remote: Bool = false) -> ContainerCLI {
    ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: remote ? .remotePeer : .localOwner)
}

@Test func volumeOwnerDecodesBackwardsCompatiblyAndValidates() throws {
    let old = Data(#"{"suffix":"data","path":"/data"}"#.utf8)
    #expect(try JSONDecoder().decode(LibraryVolume.self, from: old).volumeOwner == nil)
    let new = Data(#"{"suffix":"data","path":"/data","volumeOwner":{"uid":472,"gid":0}}"#.utf8)
    let volume = try JSONDecoder().decode(LibraryVolume.self, from: new)
    #expect(volume.volumeOwner == setupOwner)
    #expect(volume.problem() == nil)
    for owner in [VolumeOwner(uid: -1, gid: 0), .init(uid: 0, gid: -1),
                  .init(uid: 2_147_483_648, gid: 0), .init(uid: 0, gid: 2_147_483_648)] {
        var invalid = volume
        invalid.volumeOwner = owner
        #expect(invalid.problem() != nil)
        var entry = SuggestionLibrary.builtIn.entries.first { $0.kind == .container }!
        entry.container?.volumes = [invalid]
        #expect(SuggestionLibrary(version: "2026.10.18.0", entries: [entry]).checked().library.entries.isEmpty)
    }
    #expect(VolumeOwner(uid: 2_147_483_647, gid: 2_147_483_647).isValid)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(VolumeOwner.self, from: Data(#"{"uid":"root","gid":0}"#.utf8))
    }
}

@Test func volumeSetupHasExactArgvAndWorksThroughRemotePolicy() throws {
    let args = try VolumeSetupStore.helperArguments(volume: "fresh-data", owner: setupOwner, digest: setupTestDigest)
    let expected = ["run", "--rm", "-v", "fresh-data:/mnt",
                    "docker.io/library/busybox@sha256:\(setupTestDigest)", "chown", "472:0", "/mnt"]
    #expect(args == expected)
    var canonical = expected
    canonical[2] = "--volume" // Allowlist's established canonical spelling for -v
    #expect(try Allowlist.validated(Array(args.prefix(5)) + ["--"] + args.suffix(3), mountPolicy: .denyHostPaths, wirePolicy: .remotePeer).arguments == canonical)
    let host = VolumeSetupHost()
    let file = setupFile()
    defer { try? FileManager.default.removeItem(at: file) }
    try VolumeSetupStore(file: file, testDigest: setupTestDigest).prepare(cli: setupCLI(host, remote: true),
        host: "peer-a", image: "grafana:13.2", mounts: [setupMount], newOwners: [setupMount: setupOwner])
    #expect(host.commands.last == canonical)
    for name in ["/Users/person/data", "../data", "data:/other", "-bad"] {
        #expect(throws: (any Error).self) {
            try VolumeSetupStore.helperArguments(volume: name, owner: setupOwner, digest: setupTestDigest)
        }
    }
    #expect(throws: (any Error).self) {
        try VolumeSetupStore.helperArguments(volume: "data", owner: .init(uid: -1, gid: 0), digest: setupTestDigest)
    }
}

@Test func existingAndUntrackedPendingVolumesNeverGetSetup() throws {
    for labels in [[:], [VolumeSetupStore.label: setupOwner.pending]] {
        let host = VolumeSetupHost()
        host.volumes = [.init(id: "fresh-data", configuration: .init(name: "fresh-data", labels: labels))]
        let file = setupFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try VolumeSetupStore(file: file, testDigest: setupTestDigest).prepare(cli: setupCLI(host),
            host: "local", image: "grafana:13.2", mounts: [setupMount], newOwners: [setupMount: setupOwner])
        #expect(host.commands.allSatisfy { $0.first != "run" && !$0.starts(with: ["volume", "create"]) })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func pendingSurvivesFailureAndRerunsThenDoneSkips() throws {
    let host = VolumeSetupHost()
    host.failHelper = true
    let file = setupFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let store = VolumeSetupStore(file: file, testDigest: setupTestDigest)
    #expect(throws: (any Error).self) {
        try store.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2",
                          mounts: [setupMount], newOwners: [setupMount: setupOwner])
    }
    #expect(host.volumes.first?.labels?[VolumeSetupStore.label] == "pending:472:0")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("pending:472:0"))
    host.failHelper = false
    let relaunched = VolumeSetupStore(file: file, testDigest: setupTestDigest)
    // Different hosts/images never inherit another operation's pending authorization.
    try relaunched.prepare(cli: setupCLI(host), host: "peer-b", image: "grafana:13.2", mounts: [setupMount])
    try relaunched.prepare(cli: setupCLI(host), host: "local", image: "other:1", mounts: [setupMount])
    #expect(host.commands.filter { $0.first == "run" }.count == 1)
    try relaunched.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2", mounts: [setupMount])
    #expect(try String(contentsOf: file, encoding: .utf8).contains("done:472:0"))
    try relaunched.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2",
                           mounts: [setupMount], newOwners: [setupMount: setupOwner])
    #expect(host.commands.filter { $0.first == "run" }.count == 2)
    #expect(host.commands.filter { $0.starts(with: ["volume", "create"]) }.count == 1)
}

@Test func pendingCannotChownAReplacedVolume() throws {
    let host = VolumeSetupHost()
    host.failHelper = true
    let file = setupFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let store = VolumeSetupStore(file: file, testDigest: setupTestDigest)
    #expect(throws: (any Error).self) {
        try store.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2",
                          mounts: [setupMount], newOwners: [setupMount: setupOwner])
    }
    host.volumes[0].configuration.labels = [:]
    #expect(throws: (any Error).self) {
        try store.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2", mounts: [setupMount])
    }
    #expect(host.commands.filter { $0.first == "run" }.count == 1)
}

@Test func missingDigestStopsBeforeVolumeAllocation() throws {
    let host = VolumeSetupHost()
    let file = setupFile()
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: (any Error).self) {
        try VolumeSetupStore(file: file, testDigest: "").prepare(cli: setupCLI(host), host: "local",
            image: "grafana:13.2", mounts: [setupMount], newOwners: [setupMount: setupOwner])
    }
    #expect(host.commands.allSatisfy { !$0.starts(with: ["volume", "create"]) && $0.first != "run" })
}

@Test func stackCreationRecordsPendingAndStartInitializesIt() throws {
    let host = VolumeSetupHost()
    let file = setupFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let store = VolumeSetupStore(file: file, testDigest: setupTestDigest)
    try store.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2", mounts: [setupMount],
                      newOwners: [setupMount: setupOwner], requireNewVolumes: true, createOnly: true)
    #expect(host.commands.allSatisfy { $0.first != "run" })
    #expect(try String(contentsOf: file, encoding: .utf8).contains("pending:472:0"))
    try store.prepare(cli: setupCLI(host), host: "local", image: "grafana:13.2", mounts: [setupMount])
    #expect(host.commands.filter { $0.first == "run" }.count == 1)
    #expect(try String(contentsOf: file, encoding: .utf8).contains("done:472:0"))
}

@Test func suggestionsOwnersSurviveLibraryAndStackConversions() throws {
    let library = SuggestionLibrary.builtIn.checked().library
    for (id, owner) in [("grafana", setupOwner), ("prometheus", VolumeOwner(uid: 65534, gid: 65534)),
                         ("pgadmin", VolumeOwner(uid: 5050, gid: 0))] {
        #expect(library.entries.first { $0.id == id }?.container?.volumes.first?.volumeOwner == owner)
    }
    let roundTrip = try JSONDecoder().decode(SuggestionLibrary.self, from: JSONEncoder().encode(library))
    let monitoring = roundTrip.entries.first { $0.id == "monitoring-stack" }?.stackSuggestion
    #expect(monitoring?.services.first { $0.role == "grafana" }?.volumes.first?.volumeOwner == setupOwner)
}
