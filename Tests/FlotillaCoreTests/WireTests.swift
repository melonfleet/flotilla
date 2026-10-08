import Foundation
import Testing
@testable import FlotillaCore

@Suite("Wire framing")
struct WireFrameTests {
    let peer = WirePeerInfo(name: "admin", appVersion: "1.5.0.0", macOSVersion: "27.0.1", containerVersion: "1.5.0")

    var everyMessage: [WireMessage] {
        [.hello(.init(versions: 1...1, peer: peer, limits: .default)),
         .welcome(.init(version: 1, peer: peer, limits: .default)),
         .reject(.init(code: .versionMismatch, message: "no")),
         .request(.init(id: 7, arguments: ["ls", "--format", "json"], timeout: 5)),
         .cancel(.init(id: 7)),
         // Bytes JSON would have to escape, and bytes that are not UTF-8 at all.
         .result(.init(id: 7, exitCode: 3, stdout: Data([0, 1, 0x1B, 0xFF, 0x0A]), stderr: Data("oops\n".utf8),
                       stdoutTruncated: true)),
         .failure(.init(id: 7, code: .refused, message: "local only")),
         .ping(.init(nonce: 42)), .pong(.init(nonce: 42)),
         .close(.init(reason: "bye"))]
    }

    @Test func everyMessageSurvivesTheRoundTrip() throws {
        var decoder = WireFrameDecoder()
        for message in everyMessage {
            let frames = try decoder.append(try message.encoded(limits: .default))
            #expect(frames.count == 1)
            #expect(try WireMessage(frame: frames[0]) == message)
        }
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func framesSurviveAnyChunking() throws {
        let stream = try everyMessage.reduce(into: Data()) { $0.append(try $1.encoded(limits: .default)) }
        // One byte at a time: every frame boundary and every length prefix is split somewhere.
        var decoder = WireFrameDecoder()
        var decoded: [WireMessage] = []
        for byte in stream {
            decoded += try decoder.append(Data([byte])).map(WireMessage.init(frame:))
        }
        #expect(decoded == everyMessage)
        // And all at once.
        var whole = WireFrameDecoder()
        #expect(try whole.append(stream).map(WireMessage.init(frame:)) == everyMessage)
    }

    @Test func aHugeDeclaredLengthIsRefusedBeforeItIsBuffered() {
        var decoder = WireFrameDecoder(limits: WireLimits(maxFrameBytes: 1024))
        var prefix = Data()
        prefix.appendBigEndian(UInt32.max)
        #expect(throws: WireError.frameTooLarge(Int(UInt32.max))) { try decoder.append(prefix) }
    }

    @Test func malformedFramesAreRefused() throws {
        func frame(length: UInt32, type: UInt8, headerLength: UInt32, body: Data = Data()) -> Data {
            var data = Data()
            data.appendBigEndian(length)
            data.append(type)
            data.appendBigEndian(headerLength)
            data.append(body)
            return data
        }
        var a = WireFrameDecoder()
        #expect(throws: WireError.self) { try a.append(frame(length: 2, type: 1, headerLength: 0)) }
        // 49 is still reserved: no version speaks it.
        var b = WireFrameDecoder()
        #expect(throws: WireError.unknownFrameType(49)) { try b.append(frame(length: 5, type: 49, headerLength: 0)) }
        var c = WireFrameDecoder()
        #expect(throws: WireError.self) { try c.append(frame(length: 7, type: 1, headerLength: 9, body: Data([1, 2]))) }
        var d = WireFrameDecoder(limits: WireLimits(maxHeaderBytes: 4))
        #expect(throws: WireError.headerTooLarge(10)) {
            try d.append(frame(length: 15, type: 1, headerLength: 10, body: Data(count: 10)))
        }
    }

    @Test func onlyAResultMayCarryAPayload() throws {
        let ping = WireFrame(type: .ping, header: Data(#"{"nonce":1}"#.utf8), payload: Data([1]))
        #expect(throws: WireError.self) { try WireMessage(frame: ping) }
        let lying = WireFrame(type: .result,
                              header: Data(#"{"id":1,"exitCode":0,"stdoutBytes":99,"stdoutTruncated":false,"stderrTruncated":false}"#.utf8),
                              payload: Data([1, 2]))
        #expect(throws: WireError.self) { try WireMessage(frame: lying) }
        let garbage = WireFrame(type: .request, header: Data("not json".utf8))
        #expect(throws: WireError.malformedHeader(.request)) { try WireMessage(frame: garbage) }
    }

    @Test func encodingRefusesWhatThePeerWouldRefuse() {
        let big = WireMessage.result(.init(id: 1, exitCode: 0, stdout: Data(count: 2048), stderr: Data()))
        #expect(throws: WireError.self) { try big.encoded(limits: WireLimits(maxFrameBytes: 1024)) }
    }

    @Test func versionsNegotiateToTheHighestShared() {
        #expect(WireProtocol.negotiate(1...3, 2...5) == 3)
        #expect(WireProtocol.negotiate(1...1, 1...1) == 1)
        #expect(WireProtocol.negotiate(1...1, 2...2) == nil)
        #expect(WireProtocol.defaultPort == 7868)
    }

    @Test func limitsIntersectToTheStricter() {
        let mine = WireLimits(maxConcurrentRequests: 4, maxOutputBytesPerStream: 1 << 20)
        let theirs = WireLimits(maxConcurrentRequests: 64, maxOutputBytesPerStream: 64 << 10)
        let both = mine.intersection(theirs)
        #expect(both.maxConcurrentRequests == 4)
        #expect(both.maxOutputBytesPerStream == 64 << 10)
    }

    @Test func aPeersNonsenseLimitsAreClampedAndItsTimersIgnored() {
        // Iris's review: a negative output ceiling trapped in `prefix`; a tiny ping interval would
        // have had the other side ping without rest.
        let mine = WireLimits.default
        let hostile = WireLimits(maxFrameBytes: -1, maxHeaderBytes: 0, maxConcurrentRequests: -5,
                                 maxOutputBytesPerStream: -1, handshakeTimeout: -3, pingInterval: 0.001,
                                 idleTimeout: -1, deadlineGrace: -10)
        let both = mine.intersection(hostile)
        #expect(both.maxOutputBytesPerStream >= 4 << 10 && both.maxConcurrentRequests >= 1)
        #expect(both.maxFrameBytes >= 64 << 10)
        #expect(both.pingInterval == mine.pingInterval && both.idleTimeout == mine.idleTimeout)
        #expect(both.handshakeTimeout == mine.handshakeTimeout && both.deadlineGrace == mine.deadlineGrace)
    }
}

@Suite("Wire sessions")
struct WireSessionTests {
    let admin = WirePeerInfo(name: "admin", appVersion: "1.5.0.0")
    let host = WirePeerInfo(name: "mini-1", appVersion: "1.5.0.0")

    func connectedHost(limits: WireLimits = .default) throws -> WireHostSession {
        var session = WireHostSession(peer: host, limits: limits)
        _ = try session.receive(.hello(.init(versions: 1...1, peer: admin, limits: .default)))
        return session
    }

    func request(_ id: UInt32, _ args: [String], timeout: TimeInterval? = nil) -> WireMessage {
        .request(.init(id: id, arguments: args, timeout: timeout))
    }

    // MARK: Host

    @Test func nothingRunsBeforeTheHandshake() {
        var session = WireHostSession(peer: host)
        #expect(throws: WireError.unexpected(.request)) { try session.receive(request(1, ["ls"])) }
    }

    @Test func aVersionMismatchIsRejectedWithTheHostsRange() throws {
        var session = WireHostSession(peer: host)
        let events = try session.receive(.hello(.init(versions: (WireProtocol.supportedVersions.upperBound + 1)...(WireProtocol.supportedVersions.upperBound + 2), peer: admin, limits: .default)))
        guard case .send(.reject(let reject)) = events.first else { Issue.record("no reject"); return }
        #expect(reject.code == .versionMismatch)
        #expect(reject.minVersion == 1 && reject.maxVersion == WireProtocol.supportedVersions.upperBound)
        #expect(events.last == .close(reason: "version mismatch"))
        #expect(session.state == .closed)
    }

    @Test func theWelcomeCarriesTheStricterLimits() throws {
        var session = WireHostSession(peer: host)
        let asked = WireLimits(maxConcurrentRequests: 2)
        let events = try session.receive(.hello(.init(versions: 1...1, peer: admin, limits: asked)))
        guard case .send(.welcome(let welcome)) = events.first else { Issue.record("no welcome"); return }
        #expect(welcome.limits.maxConcurrentRequests == 2)
        #expect(session.state == .ready(version: 1, peer: admin))
    }

    @Test func theHostValidatesEveryRequestAsARemotePeer() throws {
        var session = try connectedHost()
        // Local-only on this host whatever the admin Mac thinks.
        for args in [["registry", "login", "--username", "me", "--password-stdin", "ghcr.io"],
                     ["machine", "create", "--name", "x", "alpine:3.22"],
                     ["system", "stop"],
                     ["system", "dns", "create", "test"]] {
            let events = try session.receive(request(1, args))
            guard case .send(.failure(let failure)) = events.first else { Issue.record("ran \(args)"); continue }
            #expect(failure.code == .refused)
        }
        // A host path in a bind mount, under this host's deny-host-paths policy.
        let mount = try session.receive(request(2, ["run", "-d", "-v", "/Users/someone:/data", "alpine:3.22"]))
        guard case .send(.failure(let refused)) = mount.first else { Issue.record("mounted a host path"); return }
        #expect(refused.code == .refused)
        #expect(session.inFlight.isEmpty)
        // What the owner approved does run.
        let events = try session.receive(request(3, ["ls", "--format", "json"]))
        guard case .execute(let id, let command, _) = events.first else { Issue.record("refused ls"); return }
        #expect(id == 3 && command.arguments == ["ls", "--format", "json"])
        let create = try session.receive(request(4, ["create", "--name", "web", "nginx:1.27"]))
        guard case .execute = create.first else { Issue.record("refused create"); return }
    }

    @Test func concurrencyIsCappedAndIDsAreUnique() throws {
        var session = try connectedHost(limits: WireLimits(maxConcurrentRequests: 1))
        _ = try session.receive(request(1, ["ls"]))
        let busy = try session.receive(request(2, ["ls"]))
        guard case .send(.failure(let failure)) = busy.first else { Issue.record("ran past the cap"); return }
        #expect(failure.code == .busy)
        #expect(throws: WireError.duplicateRequestID(1)) { try session.receive(request(1, ["ls"])) }
    }

    @Test func aCallerMayShortenADeadlineButNeverLengthenIt() {
        #expect(WireHostSession.deadline(hint: 30, requested: 5) == 5)
        #expect(WireHostSession.deadline(hint: 30, requested: 900) == 30)
        #expect(WireHostSession.deadline(hint: 30, requested: nil) == 30)
        #expect(WireHostSession.deadline(hint: 600, requested: 0) == 600)
    }

    @Test func resultsAreTrimmedAndCancelsAreIdempotent() throws {
        var session = try connectedHost(limits: WireLimits(maxOutputBytesPerStream: 4))
        _ = try session.receive(request(1, ["ls"]))
        #expect(try session.receive(.cancel(.init(id: 1))) == [.cancel(id: 1)])
        let message = session.complete(1, with: CommandResult(stdout: "abcdefgh", stderr: "", exitCode: 0))
        guard case .result(let result) = message else { Issue.record("no result"); return }
        #expect(result.stdout == Data("abcd".utf8) && result.stdoutTruncated && !result.stderrTruncated)
        // Already answered: a late cancel and a second answer are both nothing.
        #expect(try session.receive(.cancel(.init(id: 1))) == [])
        #expect(session.fail(1, code: .cancelled, message: "") == nil)
    }

    @Test func pingIsAnsweredInAnyState() throws {
        var session = WireHostSession(peer: host)
        #expect(try session.receive(.ping(.init(nonce: 9))) == [.send(.pong(.init(nonce: 9)))])
    }

    // MARK: Client

    @Test func theClientRefusesLocallyBeforeAnythingIsSent() throws {
        var client = WireClientSession(peer: admin)
        #expect(throws: WireError.notConnected) { try client.request(["ls"]) }
        _ = client.hello()
        _ = try client.receive(.welcome(.init(version: 1, peer: host, limits: .default)))
        #expect(throws: AllowlistError.self) { try client.request(["system", "stop"]) }
        #expect(client.inFlight.isEmpty)
        let outgoing = try client.request(["ls", "--format", "json"])
        #expect(outgoing.id == 1)
        #expect(outgoing.deadline == 30 + WireLimits.default.deadlineGrace)
    }

    @Test func aHostCannotWidenTheClientsLimits() throws {
        var client = WireClientSession(peer: admin, limits: WireLimits(maxConcurrentRequests: 1))
        _ = client.hello()
        _ = try client.receive(.welcome(.init(version: 1, peer: host, limits: WireLimits(maxConcurrentRequests: 99))))
        _ = try client.request(["ls"])
        #expect(throws: WireError.tooManyRequests(limit: 1)) { try client.request(["ls"]) }
    }

    @Test func theClientHoldsTheHostToTheProtocol() throws {
        var client = WireClientSession(peer: admin, limits: WireLimits(maxOutputBytesPerStream: 4))
        _ = client.hello()
        _ = try client.receive(.welcome(.init(version: 1, peer: host, limits: .default)))
        // An answer to a question nobody asked.
        #expect(throws: WireError.unknownRequestID(5)) {
            try client.receive(.failure(.init(id: 5, code: .internalError, message: "")))
        }
        // More output than agreed.
        let outgoing = try client.request(["ls"])
        #expect(throws: WireError.self) {
            try client.receive(.result(.init(id: outgoing.id, exitCode: 0, stdout: Data(count: 5), stderr: Data())))
        }
        // An abandoned request's late answer is dropped, not an error.
        let late = try client.request(["ls"])
        client.abandon(late.id)
        #expect(try client.receive(.failure(.init(id: late.id, code: .timedOut, message: ""))) == [])
    }

    @Test func aRejectEndsTheClientSession() throws {
        var client = WireClientSession(peer: admin)
        _ = client.hello()
        let events = try client.receive(.reject(.init(code: .untrusted, message: "not approved")))
        #expect(events.count == 1)
        #expect(client.state == .closed)
        #expect(throws: WireError.closed) { try client.receive(.ping(.init(nonce: 1))) }
    }

    // MARK: Both, over bytes

    @Test func aRequestRunsEndToEndOverBytes() throws {
        var client = WireClientSession(peer: admin)
        var server = WireHostSession(peer: host)
        var toHost = WireFrameDecoder(), toClient = WireFrameDecoder()

        func deliverToHost(_ message: WireMessage) throws -> [WireHostSession.Event] {
            try toHost.append(try message.encoded(limits: .default))
                .flatMap { try server.receive(try WireMessage(frame: $0)) }
        }
        func deliverToClient(_ message: WireMessage) throws -> [WireClientSession.Event] {
            try toClient.append(try message.encoded(limits: .default))
                .flatMap { try client.receive(try WireMessage(frame: $0)) }
        }

        guard case .send(let welcome) = try deliverToHost(client.hello()).first else { Issue.record(); return }
        guard case .connected = try deliverToClient(welcome).first else { Issue.record(); return }

        let outgoing = try client.request(["ls", "--format", "json"])
        guard case .execute(let id, _, let deadline) = try deliverToHost(outgoing.message).first else {
            Issue.record(); return
        }
        #expect(deadline == 30)
        let ran = CommandResult(stdout: "[]\n", stderr: "", exitCode: 0)
        let completed = server.complete(id, with: ran)
        let reply = try #require(completed)
        #expect(try deliverToClient(reply) == [.completed(id: outgoing.id, result: ran)])
        #expect(client.inFlight.isEmpty && server.inFlight.isEmpty)
    }
}
