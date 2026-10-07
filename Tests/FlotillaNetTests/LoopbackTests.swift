import Foundation
import Network
import Testing
import FlotillaCore
import FlotillaTrust
@testable import FlotillaNet

/// Host mode end to end on this Mac's loopback: two real Keychain identities, real TLS 1.3 with
/// client certificates, the real wire protocol and both pairing methods. Nothing here launches
/// `container` — the host side runs a scripted `ContainerHost`.
@Suite("Host mode over loopback TLS", .serialized)
struct LoopbackTests {

    final class ScriptedHost: ContainerHost, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ran: [[String]] = []
        /// How long each command takes, to hold slots open.
        var delay: TimeInterval = 0
        /// Answers for particular commands, by their leading words; anything else answers `[]`.
        var answers: [String: CommandResult] = [:]
        /// What `image load --input` found in the archive it was handed, read before it returns.
        private(set) var loaded: [Data] = []
        func run(_ args: [String]) throws -> CommandResult {
            lock.lock(); ran.append(args); let wait = delay; let answers = self.answers; lock.unlock()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            if args.starts(with: ["image", "load", "--input"]), let path = args.last {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                lock.withLock { loaded.append(data) }
                return CommandResult(stdout: "Loaded images:\nexample.test/app:1\n", stderr: "", exitCode: 0)
            }
            for (key, answer) in answers where args.joined(separator: " ").hasPrefix(key) { return answer }
            return CommandResult(stdout: "[]\n", stderr: "", exitCode: 0)
        }
    }

    final class Delegate: HostServerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        var trusted: [PeerFingerprint: Peer.Method] = [:]
        var code: PairingCode?
        var key: EnrolmentKey?
        var codeFailures = 0
        var answers: [WireMessage.PairOutcome] = []
        var hostSaysWordsMatch = true

        func isTrusted(_ fingerprint: PeerFingerprint) -> Bool { locked { trusted[fingerprint] != nil } }
        func currentPairingCode() -> PairingCode? { locked { code } }
        func pairingCodeFailed() { locked { codeFailures += 1 } }
        func enrolmentKey() -> EnrolmentKey? { locked { key } }
        func trust(admin: PeerFingerprint, details: PeerDetails, method: Peer.Method) { locked { trusted[admin] = method } }
        func confirmWords(_ words: [String], admin: PeerDetails, reply: @escaping @Sendable (Bool) -> Void) {
            reply(locked { hostSaysWordsMatch })
        }
        func enrolmentAnswered(_ outcome: WireMessage.PairOutcome, message: String) { locked { answers.append(outcome) } }
        var blocked: Set<PeerFingerprint> = []
        func isBlocked(_ fingerprint: PeerFingerprint) -> Bool { locked { blocked.contains(fingerprint) } }

        func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    }

    /// A listening host and an identity for the admin, torn down afterwards.
    struct Rig {
        let server: HostServer
        let delegate: Delegate
        let host: ScriptedHost
        let hostIdentity: DeviceIdentity
        let adminIdentity: DeviceIdentity
        let port: UInt16
        let stores: [DeviceIdentityStore]

        func admin() -> AdminConnection {
            AdminConnection(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                            identity: adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"))
        }

        func tearDown() {
            server.stop()
            stores.forEach { $0.reset() }
        }
    }

    func rig(configure: (inout HostServer.Configuration) -> Void = { _ in }) async throws -> Rig {
        let hostStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        let adminStore = DeviceIdentityStore(label: "dev.melonfleet.Flotilla.test-identity.\(UUID().uuidString)")
        let hostIdentity = try hostStore.loadOrCreate(), adminIdentity = try adminStore.loadOrCreate()
        let delegate = Delegate(), host = ScriptedHost()
        var configuration = HostServer.Configuration(identity: hostIdentity, port: 0,
                                                     info: WirePeerInfo(name: "mini-test", appVersion: "test"),
                                                     details: PeerDetails(computerName: "mini-test", serialNumber: "TEST"))
        configure(&configuration)
        let server = HostServer(configuration: configuration, host: host, delegate: delegate)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            server.onStateChange = { state in
                switch state {
                case .listening(let port): once.run { continuation.resume(returning: port) }
                case .failed(let why): once.run { continuation.resume(throwing: RemoteHostError.unreachable(why)) }
                default: break
                }
            }
            do { try server.start() } catch { once.run { continuation.resume(throwing: error) } }
        }
        return Rig(server: server, delegate: delegate, host: host, hostIdentity: hostIdentity,
                   adminIdentity: adminIdentity, port: port, stores: [hostStore, adminStore])
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    // MARK: Tests

    @Test func aStrangerConnectsButCannotRunAnything() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let admin = rig.admin()
        defer { admin.close() }
        let welcome = try await admin.connect()
        #expect(!welcome.trusted)
        #expect(welcome.peer.name == "mini-test")
        #expect(admin.hostFingerprint == rig.hostIdentity.fingerprint)
        await #expect(throws: RemoteHostError.self) { try await admin.run(["ls", "--format", "json"]) }
        #expect(rig.host.ran.isEmpty)
    }

    @Test func pairingByCodeThenRunningACommand() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let code = PairingCode()
        rig.delegate.locked { rig.delegate.code = code }

        let first = rig.admin()
        _ = try await first.connect()
        let outcome = try await first.pair(details: PeerDetails(computerName: "admin-laptop"),
                                           method: .pairingCode(code.display.lowercased()),
                                           confirmWords: { words, _ in words.count == 4 },
                                           recordEnrolment: { _, _ in .blocked })
        #expect(outcome == .paired(rig.hostIdentity.fingerprint,
                                   PeerDetails(computerName: "mini-test", serialNumber: "TEST")))
        #expect(rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] } == .pairingCode)
        first.close()

        // A new connection from the same key is now trusted, and commands run.
        let second = rig.admin()
        defer { second.close() }
        let welcome = try await second.connect()
        #expect(welcome.trusted)
        let result = try await second.run(["ls", "--format", "json"])
        #expect(result.stdout == "[]\n" && result.exitCode == 0)
        #expect(rig.host.ran == [["ls", "--format", "json"]])
        // Refused before it leaves this Mac.
        await #expect(throws: AllowlistError.self) { try await second.run(["system", "stop"]) }
    }

    @Test func aWrongCodeIsRefusedAndCounted() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.code = PairingCode() }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        await #expect(throws: RemoteHostError.self) {
            try await admin.pair(details: PeerDetails(computerName: "admin"), method: .pairingCode("0000-0000"),
                                 confirmWords: { _, _ in true }, recordEnrolment: { _, _ in .blocked })
        }
        #expect(rig.delegate.locked { rig.delegate.codeFailures } == 1)
        #expect(rig.delegate.locked { rig.delegate.trusted.isEmpty })
    }

    @Test func theHostOwnerCanSayTheWordsDoNotMatch() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let code = PairingCode()
        rig.delegate.locked { rig.delegate.code = code; rig.delegate.hostSaysWordsMatch = false }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        await #expect(throws: RemoteHostError.self) {
            try await admin.pair(details: PeerDetails(computerName: "admin"), method: .pairingCode(code.value),
                                 confirmWords: { _, _ in true }, recordEnrolment: { _, _ in .blocked })
        }
        #expect(rig.delegate.locked { rig.delegate.trusted.isEmpty })
    }

    @Test func enrolmentPutsTheHostInTheApprovalList() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let key = EnrolmentKey.generate(for: rig.adminIdentity.fingerprint)
        rig.delegate.locked { rig.delegate.key = key }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        let outcome = try await admin.pair(details: PeerDetails(computerName: "admin"), method: .enrolmentKey(key),
                                           confirmWords: { _, _ in false },
                                           recordEnrolment: { _, _ in .addedPending })
        guard case .enrolment(let fingerprint, let details, .addedPending) = outcome else {
            Issue.record("unexpected \(outcome)"); return
        }
        #expect(fingerprint == rig.hostIdentity.fingerprint && details.serialNumber == "TEST")
        // The host trusts the admin its key names; the admin still has to approve the host.
        #expect(rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] } == .enrolmentKey)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.delegate.locked { rig.delegate.answers } == [.pending])
    }

    @Test func aHostWithoutTheKeySaysWhyBeforeHangingUp() async throws {
        // Measured 7 October with a VM: the refusal was sent and the connection cancelled at once,
        // so the reason never arrived and the admin reported a protocol violation.
        let rig = try await rig()
        defer { rig.tearDown() }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        do {
            _ = try await admin.pair(details: PeerDetails(computerName: "admin"),
                                     method: .enrolmentKey(EnrolmentKey.generate(for: rig.adminIdentity.fingerprint)),
                                     confirmWords: { _, _ in false }, recordEnrolment: { _, _ in .blocked })
            Issue.record("paired without a key")
        } catch {
            #expect("\(error)".contains("wasn’t set up to enrol") || "\(error)".contains("wasn't set up to enrol"),
                    "got: \(error)")
        }
    }

    @Test func revokingClosesTheLiveConnection() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let admin = rig.admin()
        defer { admin.close() }
        #expect(try await admin.connect().trusted)
        rig.delegate.locked { rig.delegate.trusted = [:] }
        rig.server.disconnect(rig.adminIdentity.fingerprint)
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: RemoteHostError.self) { try await admin.run(["ls"]) }
    }

    // MARK: RemoteHost

    func remote(_ rig: Rig, pinning fingerprint: PeerFingerprint? = nil) -> RemoteHost {
        RemoteHost(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                   fingerprint: fingerprint ?? rig.hostIdentity.fingerprint,
                   identity: rig.adminIdentity, info: WirePeerInfo(name: "admin", appVersion: "test"))
    }

    @Test func aPairedHostRunsTheSameCLICallsAsThisMac() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = remote(rig)
        defer { host.close() }
        let cli = ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: .remotePeer)
        let containers = try await Task.detached { try cli.listContainers() }.value
        #expect(containers.isEmpty)
        #expect(rig.host.ran.count == 1 && rig.host.ran[0].first == "ls")
        #expect(host.hostInfo?.name == "mini-test")
    }

    @Test func aDifferentKeyAtTheSameAddressGetsNothing() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        // Pinned to a fingerprint the host does not have — as if a different Mac answered.
        let host = remote(rig, pinning: rig.adminIdentity.fingerprint)
        defer { host.close() }
        await #expect(throws: RemoteHostError.self) { try await host.run(["ls"], timeout: nil) }
        #expect(rig.host.ran.isEmpty)
    }

    @Test func aHostThatNoLongerTrustsThisMacSaysSo() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let host = remote(rig)
        defer { host.close() }
        await #expect(throws: RemoteHostError.notTrusted) { try await host.run(["ls"], timeout: nil) }
        #expect(rig.host.ran.isEmpty)
    }

    @Test func fortyCallsAtOnceQueueBehindTheLimitWithoutStarvingThePool() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = remote(rig)
        defer { host.close() }
        // Blocking calls from the cooperative pool, more of them than it has threads: if any of
        // them needed the pool to finish, this would never return.
        let results = try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<40 { group.addTask { try host.run(["ls"], timeout: 10).exitCode } }
            return try await group.reduce(into: [Int32]()) { $0.append($1) }
        }
        #expect(results.count == 40 && results.allSatisfy { $0 == 0 })
        #expect(rig.host.ran.count == 40)
    }

    // MARK: Admission (Iris's review)

    @Test func oneAddressGetsAtMostFourConnections() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let admins = (0..<6).map { _ in rig.admin() }
        defer { admins.forEach { $0.close() } }
        var connected = 0
        for admin in admins {
            if (try? await admin.connect()) != nil { connected += 1 }
        }
        #expect(connected == 4)
    }

    @Test func aRunningCommandHoldsTheHostsSlotUntilItEnds() async throws {
        let rig = try await rig { $0.maxRunningCommands = 1 }
        defer { rig.tearDown() }
        rig.host.delay = 1.5
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = remote(rig)
        defer { host.close() }
        // The first command occupies the host's only slot for 1.5 s.
        let first = Task { try await host.run(["ls"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: RemoteHostError.self) { try await host.run(["ls"], timeout: nil) }
        _ = try await first.value
        // Free again once it really ended.
        _ = try await host.run(["ls"], timeout: nil)
    }

    @Test func aRemovedAdminsKeyIsRefusedOverTLS() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        let key = EnrolmentKey.generate(for: rig.adminIdentity.fingerprint)
        rig.delegate.locked {
            rig.delegate.key = key
            rig.delegate.blocked = [rig.adminIdentity.fingerprint]
        }
        let admin = rig.admin()
        defer { admin.close() }
        _ = try await admin.connect()
        do {
            _ = try await admin.pair(details: PeerDetails(computerName: "admin"), method: .enrolmentKey(key),
                                     confirmWords: { _, _ in false }, recordEnrolment: { _, _ in .addedPending })
            Issue.record("a removed admin enrolled again")
        } catch {
            #expect("\(error)".contains("removed"), "got: \(error)")
        }
        #expect(rig.delegate.locked { rig.delegate.trusted.isEmpty })
    }

    @Test func aHostThatRestartsIsReconnectedTo() async throws {
        // Measured 7 October: hosts updated and restarted, and the admin kept reusing the dead
        // connection — every status check said "The connection closed" until relaunch.
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let host = remote(rig)
        defer { host.close() }
        _ = try await host.run(["ls"], timeout: nil)

        // Restart the host on the same port, as an update does.
        rig.server.stop()
        try await Task.sleep(for: .milliseconds(300))
        var configuration = rig.server.configuration
        configuration.port = rig.port
        let restarted = HostServer(configuration: configuration, host: rig.host, delegate: rig.delegate)
        try restarted.start()
        defer { restarted.stop() }
        try await Task.sleep(for: .milliseconds(500))

        // The first call may still meet the dead connection; the next must not.
        _ = try? await host.run(["ls"], timeout: nil)
        let result = try await host.run(["ls"], timeout: nil)
        #expect(result.exitCode == 0)
    }

    @Test func anAttemptThatNeverReachesTheHostIsRetriedThenReported() async throws {
        // Measured 7 October: just after launch macOS can refuse Flotilla's local-network lookups
        // while it applies the Local Network permission, and the connection sits in `preparing`
        // for good. A Bonjour name nobody advertises stays there the same way. Each attempt must
        // give up quickly, be made again, and finally fail saying it never reached the host —
        // not wait out the 20-second welcome deadline once.
        let rig = try await rig()
        defer { rig.tearDown() }
        let host = RemoteHost(endpoint: .service(name: "nobody-\(UUID().uuidString.prefix(8))",
                                                 type: WireTLS.serviceType, domain: "local.", interface: nil),
                              fingerprint: rig.hostIdentity.fingerprint, identity: rig.adminIdentity,
                              info: WirePeerInfo(name: "admin", appVersion: "test"), reachTimeout: 0.4)
        defer { host.close() }
        let started = Date()
        do {
            _ = try await host.run(["ls"], timeout: nil)
            Issue.record("a host nobody advertises answered")
        } catch let error as RemoteHostError {
            guard case .unreachable(let reason) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(reason == AdminConnection.notReachedReason)
        }
        // Three attempts of 0.4s with a second between them: about 3.2s, well inside 20.
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed > 2.5 && elapsed < 8, "took \(elapsed)s")
    }

    // MARK: Streams (D2)

    /// `container system version` as 1.5.0 printed it (captured, Tests/FlotillaCoreTests/Fixtures).
    static func capturedVersion() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FlotillaCoreTests/Fixtures/container-1.5.0/version.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aHostsLogIsFollowedThroughTheSameCLICall() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        // The scripted host's `stream` runs the command and hands over its lines, then ends.
        rig.host.answers["logs --follow"] = CommandResult(stdout: "one\ntwo\nthree\n", stderr: "warn\n", exitCode: 0)
        let host = remote(rig)
        defer { host.close() }
        let cli = ContainerCLI(host: host, mountPolicy: .denyHostPaths, wirePolicy: .remotePeer)
        let lines = LineBox()
        // The handle is held: letting it go stops the follow, as letting go of a local tail does.
        let handle = HandleBox()
        let end: CommandStreamEnd = try await withCheckedThrowingContinuation { continuation in
            do {
                handle.stream = try cli.followLogs("web", lines: 50, onLine: { stream, text in lines.add("\(stream):\(text)") },
                                                   onEnd: { continuation.resume(returning: $0) })
            } catch { continuation.resume(throwing: error) }
        }
        #expect(end.ok && !end.cancelled)
        #expect(lines.all == ["stdout:one", "stdout:two", "stdout:three", "stderr:warn"])
        #expect(rig.host.ran.last == ["logs", "--follow", "-n", "50", "web"])
    }

    @Test func anImageArchiveArrivesWholeAndIsLoadedByTheHost() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        rig.host.answers["system version"] = CommandResult(stdout: try Self.capturedVersion(), stderr: "", exitCode: 0)
        // Three and a half pieces, so credit, the window and a short last piece are all exercised.
        let bytes = (0..<(3 * (1 << 20) + 300_000)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString).tar")
        try Data(bytes).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let digest = SHA256Hex.of(Data(bytes))

        let host = remote(rig)
        defer { host.close() }
        let result = try await host.upload(file: archive, bytes: UInt64(bytes.count), sha256: digest,
                                           label: "example.test/app:1") { _ in }
        #expect(result.exitCode == 0 && result.stdout.contains("example.test/app:1"))
        #expect(rig.host.loaded == [Data(bytes)])
        // The host built the load itself, for a file of its own, and that file is gone now.
        let load = try #require(rig.host.ran.first { $0.starts(with: ["image", "load"]) })
        #expect(load.count == 4 && !FileManager.default.fileExists(atPath: load[3]))
    }

    @Test func aDamagedArchiveIsRefusedAndNotLoaded() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        rig.host.answers["system version"] = CommandResult(stdout: try Self.capturedVersion(), stderr: "", exitCode: 0)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString).tar")
        try Data(count: 100_000).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let host = remote(rig)
        defer { host.close() }
        await #expect(throws: RemoteHostError.self) {
            _ = try await host.upload(file: archive, bytes: 100_000, sha256: String(repeating: "0", count: 64),
                                      label: "x") { _ in }
        }
        #expect(rig.host.loaded.isEmpty)
    }

    @Test func aHostWithAnOldContainerRefusesImages() async throws {
        let rig = try await rig()
        defer { rig.tearDown() }
        rig.delegate.locked { rig.delegate.trusted[rig.adminIdentity.fingerprint] = .pairingCode }
        let old = try Self.capturedVersion().replacingOccurrences(of: "\"1.5.0\"", with: "\"1.3.0\"")
        rig.host.answers["system version"] = CommandResult(stdout: old, stderr: "", exitCode: 0)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString).tar")
        try Data(count: 1000).write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let host = remote(rig)
        defer { host.close() }
        do {
            _ = try await host.upload(file: archive, bytes: 1000, sha256: SHA256Hex.of(Data(count: 1000)), label: "x") { _ in }
            Issue.record("an old host accepted an image")
        } catch {
            #expect(String(describing: error).contains("1.3.1"))
        }
        #expect(rig.host.loaded.isEmpty)
    }
}

final class HandleBox: @unchecked Sendable { var stream: CommandStream? }

final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

import CryptoKit
enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
