import Foundation
import Testing
@testable import FlotillaCore

/// D2's streams (research/WIRE-STREAMS-D2.md): every rule the design states, one test each.
@Suite("Wire streams")
struct WireStreamTests {
    let admin = WirePeerInfo(name: "admin", appVersion: "0.0.0 (310)")
    let host = WirePeerInfo(name: "mini", appVersion: "0.0.0 (310)")
    let digest = String(repeating: "ab", count: 32)

    /// Both halves through their handshake, at `versions`.
    func connected(versions: ClosedRange<UInt16> = 1...2, limits: WireStreamLimits = .default) throws
        -> (host: WireHostSession, client: WireClientSession) {
        var hostSession = WireHostSession(peer: host, versions: versions, streamLimits: limits)
        var client = WireClientSession(peer: admin, versions: versions, streamLimits: limits)
        let replies = try hostSession.receive(client.hello())
        guard case .send(let welcome) = replies.first else { throw WireError.notConnected }
        _ = try client.receive(welcome)
        return (hostSession, client)
    }

    // MARK: Framing

    @Test func streamMessagesSurviveTheRoundTrip() throws {
        let messages: [WireMessage] = [
            .follow(.init(id: 3, arguments: ["logs", "-n", "100", "--follow", "web"])),
            .streamData(.init(id: 3, seq: 9, channel: .stderr, data: Data([0, 0xFF, 0x0A]))),
            .streamEnd(.init(id: 3, exitCode: 0, reason: "stopped", dropped: 4)),
            .streamCredit(.init(id: 3, bytes: 1 << 20)),
            .upload(.init(id: 4, purpose: .imageLoad, bytes: 4_142_592, sha256: digest, label: "alpine:3.22")),
        ]
        var decoder = WireFrameDecoder()
        for message in messages {
            let frames = try decoder.append(try message.encoded(limits: .default))
            #expect(try WireMessage(frame: frames[0]) == message)
        }
    }

    @Test func aVersionOneConnectionRefusesEveryStreamFrame() throws {
        var (hostSession, client) = try connected(versions: 1...1)
        #expect(throws: WireError.streamsUnsupported) { try client.follow(["logs", "-n", "5", "--follow", "web"]) }
        #expect(throws: WireError.self) { try hostSession.receive(.follow(.init(id: 1, arguments: ["logs", "-n", "5", "--follow", "web"]))) }
        #expect(throws: WireError.self) { try hostSession.receive(.streamCredit(.init(id: 1, bytes: 10))) }
    }

    // MARK: Follow

    @Test func onlyLogsCanBeFollowed() throws {
        var (hostSession, _) = try connected()
        let refused = try hostSession.receive(.follow(.init(id: 1, arguments: ["ls", "--format", "json"])))
        guard case .send(.failure(let failure))? = refused.first else { Issue.record("not refused"); return }
        #expect(failure.code == .refused)
        let started = try hostSession.receive(.follow(.init(id: 2, arguments: ["logs", "-n", "50", "--follow", "web"])))
        guard case .startFollow(2, _)? = started.first else { Issue.record("not started"); return }
    }

    @Test func followOutputWaitsForCreditAndKeepsOrder() throws {
        var (hostSession, client) = try connected()
        let (outgoing, credit) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        // Nothing goes out before the admin's credit arrives.
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("one\n".utf8))
        #expect(hostSession.flushFollows().isEmpty)
        let sent = try hostSession.receive(credit).compactMap { event -> WireMessage? in
            if case .send(let message) = event { return message } else { return nil }
        }
        #expect(sent.count == 1)
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("two\n".utf8))
        let more = hostSession.flushFollows()
        var lines = ""
        for message in sent + more {
            for event in try client.receive(message) {
                if case .streamData(_, .stdout, let data) = event { lines += String(decoding: data, as: UTF8.self) }
            }
        }
        #expect(lines == "one\ntwo\n")
    }

    @Test func aStalledAdminCostsTheHostAFixedBufferThenLinesAreDroppedAndSaidSo() throws {
        var limits = WireStreamLimits()
        limits.followBufferBytes = 100
        var (hostSession, _) = try connected(limits: limits)
        _ = try hostSession.receive(.follow(.init(id: 1, arguments: ["logs", "-n", "50", "--follow", "web"])))
        let line = Data(String(repeating: "x", count: 39).utf8 + Data("\n".utf8))
        for _ in 0..<10 { hostSession.followOutput(1, channel: .stdout, line: line) }
        // Two 40-byte lines fit in 100; the other eight are dropped, and nothing was sent. The two
        // go as one frame, and the notice as another.
        let sent = try hostSession.receive(.streamCredit(.init(id: 1, bytes: 10_000)))
        let messages = sent.compactMap { event -> WireMessage? in if case .send(let m) = event { return m } else { return nil } }
        #expect(messages.count == 2)
        guard case .streamData(let notice)? = messages.last else { Issue.record("no notice"); return }
        #expect(notice.channel == .notice && String(decoding: notice.data, as: UTF8.self).contains("8 lines dropped"))
        let end = hostSession.followEnded(1, exitCode: 0, reason: "stopped")
        guard case .streamEnd(let ended)? = end.last else { Issue.record("no end"); return }
        #expect(ended.dropped == 8)
    }

    @Test func aHostThatSendsPastItsCreditOrOutOfSequenceIsCutOff() throws {
        var (_, client) = try connected()
        let (outgoing, _) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        let tooMuch = Data(count: Int(WireStreamLimits.default.followInitialCredit) + 1)
        #expect(throws: WireError.self) {
            try client.receive(.streamData(.init(id: outgoing.id, seq: 0, channel: .stdout, data: tooMuch)))
        }
        var (_, client2) = try connected()
        let (second, _) = try client2.follow(["logs", "-n", "50", "--follow", "web"])
        #expect(throws: WireError.self) {
            try client2.receive(.streamData(.init(id: second.id, seq: 1, channel: .stdout, data: Data("x".utf8))))
        }
    }

    @Test func creditIsClampedAndLateDataAfterStoppingIsIgnored() throws {
        var (_, client) = try connected()
        let (outgoing, _) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        guard case .streamCredit(let more)? = client.grant(outgoing.id, bytes: .max) else { Issue.record("no credit"); return }
        #expect(more.bytes <= WireStreamLimits.default.maxOutstandingCredit)
        #expect(client.stopFollow(outgoing.id) == .cancel(.init(id: outgoing.id)))
        #expect(try client.receive(.streamData(.init(id: outgoing.id, seq: 0, channel: .stdout, data: Data("x".utf8)))).isEmpty)
        #expect(try client.receive(.streamEnd(.init(id: outgoing.id, reason: "cancelled"))).isEmpty)
    }

    @Test func tooManyFollowsAreRefused() throws {
        var limits = WireStreamLimits()
        limits.maxFollowsPerConnection = 1
        var (hostSession, _) = try connected(limits: limits)
        _ = try hostSession.receive(.follow(.init(id: 1, arguments: ["logs", "-n", "5", "--follow", "a"])))
        let second = try hostSession.receive(.follow(.init(id: 2, arguments: ["logs", "-n", "5", "--follow", "b"])))
        guard case .send(.failure(let failure))? = second.first else { Issue.record("not refused"); return }
        #expect(failure.code == .busy)
    }

    // MARK: Upload

    func acceptedUpload(bytes: UInt64, limits: WireStreamLimits = .default) throws
        -> (host: WireHostSession, client: WireClientSession, id: UInt32) {
        var (hostSession, client) = try connected(limits: limits)
        let outgoing = try client.upload(bytes: bytes, sha256: digest, label: "alpine:3.22")
        let started = try hostSession.receive(outgoing.message)
        guard case .startUpload(let id, _)? = started.first else { throw WireError.notConnected }
        let accepted = hostSession.acceptUpload(id)
        let credit = try #require(accepted)
        _ = try client.receive(credit)
        return (hostSession, client, id)
    }

    @Test func anUploadRunsOnCreditToItsDeclaredSizeThenFinishes() throws {
        var limits = WireStreamLimits()
        limits.uploadWindowBytes = 8
        limits.minUploadChunkBytes = 4
        var (hostSession, client, id) = try acceptedUpload(bytes: 12, limits: limits)
        #expect(client.uploadCredit(id) == 8)
        let first = try client.uploadChunk(id, Data(count: 8))
        #expect(throws: WireError.self) { try client.uploadChunk(id, Data(count: 1)) }   // no credit left
        guard case .uploadChunk(_, let data)? = try hostSession.receive(first).first else { Issue.record("no chunk"); return }
        let wrote = hostSession.uploadWrote(id, bytes: UInt64(data.count))
        let more = try #require(wrote)
        _ = try client.receive(more)
        #expect(client.uploadCredit(id) == 4)   // never more than is left to send
        _ = try hostSession.receive(try client.uploadChunk(id, Data(count: 4)))
        guard case .uploadFinished(id, let sha)? = try hostSession.receive(try client.uploadEnd(id)).first else {
            Issue.record("not finished"); return
        }
        #expect(sha == digest)
    }

    @Test func anUploadPastItsCreditOrSizeOrOutOfSequenceClosesTheConnection() throws {
        var limits = WireStreamLimits()
        limits.uploadWindowBytes = 8
        var (hostSession, _, id) = try acceptedUpload(bytes: 12, limits: limits)
        #expect(throws: WireError.self) {
            try hostSession.receive(.streamData(.init(id: id, seq: 0, channel: .data, data: Data(count: 9))))
        }
        var (second, _, id2) = try acceptedUpload(bytes: 12, limits: limits)
        #expect(throws: WireError.self) {
            try second.receive(.streamData(.init(id: id2, seq: 3, channel: .data, data: Data(count: 1))))
        }
        var (third, _, id3) = try acceptedUpload(bytes: 4)
        #expect(throws: WireError.self) {
            try third.receive(.streamData(.init(id: id3, seq: 0, channel: .data, data: Data(count: 5))))
        }
    }

    @Test func anUploadThatEndsShortIsRefusedAndItsFileDiscarded() throws {
        var limits = WireStreamLimits()
        limits.minUploadChunkBytes = 1
        var (hostSession, client, id) = try acceptedUpload(bytes: 10, limits: limits)
        _ = try hostSession.receive(try client.uploadChunk(id, Data(count: 6)))
        let events = try hostSession.receive(.streamEnd(.init(id: id)))
        #expect(events.first == .abortUpload(id: id))
        guard case .send(.failure(let failure))? = events.last else { Issue.record("not refused"); return }
        #expect(failure.code == .invalidRequest)
    }

    @Test func aRefusedUploadIgnoresBytesAlreadyInFlight() throws {
        var (hostSession, _, id) = try acceptedUpload(bytes: 10)
        _ = hostSession.fail(id, code: .internalError, message: "disk full")
        #expect(try hostSession.receive(.streamData(.init(id: id, seq: 0, channel: .data, data: Data(count: 4)))).isEmpty)
        // But bytes for an upload that never existed are a violation.
        #expect(throws: WireError.self) {
            try hostSession.receive(.streamData(.init(id: 999, seq: 0, channel: .data, data: Data(count: 1))))
        }
    }

    @Test func anUploadIsRefusedBeforeAnyByteWhenTooLargeOrBadlyDescribed() throws {
        var (hostSession, _) = try connected()
        for upload in [WireMessage.Upload(id: 1, purpose: .imageLoad, bytes: (8 << 30) + 1, sha256: digest, label: "x"),
                       WireMessage.Upload(id: 2, purpose: .imageLoad, bytes: 0, sha256: digest, label: "x"),
                       WireMessage.Upload(id: 3, purpose: .imageLoad, bytes: 10, sha256: "not-hex", label: "x")] {
            guard case .send(.failure)? = try hostSession.receive(.upload(upload)).first else {
                Issue.record("accepted \(upload.id)"); return
            }
        }
    }

    @Test func cancellingAnUploadDiscardsItsFile() throws {
        var (hostSession, _, id) = try acceptedUpload(bytes: 10)
        let events = try hostSession.receive(.cancel(.init(id: id)))
        #expect(events == [.abortUpload(id: id), .cancel(id: id)])
    }

    // MARK: After review (Iris, 7 October)

    @Test func emptyDataAndCreditOfNothingAreViolations() throws {
        var (hostSession, client) = try connected()
        let (outgoing, credit) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        _ = try hostSession.receive(credit)
        #expect(throws: WireError.self) { try hostSession.receive(.streamCredit(.init(id: outgoing.id, bytes: 0))) }
        #expect(throws: WireError.self) {
            try client.receive(.streamData(.init(id: outgoing.id, seq: 0, channel: .stdout, data: Data())))
        }
    }

    @Test func outputOfACommandThatEndsBeforeAnyCreditStillArrives() throws {
        var (hostSession, client) = try connected()
        let (outgoing, credit) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        // The command writes and exits before the admin's credit has arrived.
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("one\n".utf8))
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("two\n".utf8))
        #expect(hostSession.followEnded(outgoing.id, exitCode: 0, reason: nil).isEmpty)
        var lines = ""
        var ended: WireMessage.StreamEnd?
        for event in try hostSession.receive(credit) {
            guard case .send(let message) = event else { continue }
            for got in try client.receive(message) {
                if case .streamData(_, _, let data) = got { lines += String(decoding: data, as: UTF8.self) }
                if case .streamEnded(let end) = got { ended = end }
            }
        }
        #expect(lines == "one\ntwo\n")
        #expect(ended?.exitCode == 0 && ended?.dropped == nil)
    }

    @Test func stoppingAFollowThatIsOnlyWaitingForCreditEndsItAtOnce() throws {
        var (hostSession, _) = try connected()
        _ = try hostSession.receive(.follow(.init(id: 1, arguments: ["logs", "-n", "5", "--follow", "web"])))
        hostSession.followOutput(1, channel: .stdout, line: Data("one\n".utf8))
        _ = hostSession.followEnded(1, exitCode: 0, reason: nil)
        let events = try hostSession.receive(.cancel(.init(id: 1)))
        guard case .send(.streamEnd(let end))? = events.last else { Issue.record("not ended"); return }
        #expect(end.dropped == 1)
    }

    @Test func creditForAFollowJustEndedIsIgnoredButForNoneIsAViolation() throws {
        var (hostSession, _) = try connected()
        _ = try hostSession.receive(.follow(.init(id: 1, arguments: ["logs", "-n", "5", "--follow", "web"])))
        _ = hostSession.followEnded(1, exitCode: 0, reason: nil)
        #expect(try hostSession.receive(.streamCredit(.init(id: 1, bytes: 1024))).isEmpty)
        #expect(throws: WireError.self) { try hostSession.receive(.streamCredit(.init(id: 77, bytes: 1024))) }
    }

    @Test func everyFrameCostsAtLeastItsChargeSoTinyCreditBuysLittle() throws {
        var (hostSession, client) = try connected()
        let (outgoing, _) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        // Two one-byte lines on different channels need two frames: 512 of credit, not 2.
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("a".utf8))
        hostSession.followOutput(outgoing.id, channel: .stderr, line: Data("b".utf8))
        let sent = try hostSession.receive(.streamCredit(.init(id: outgoing.id, bytes: 300)))
        #expect(sent.count == 1)
        #expect(try hostSession.receive(.streamCredit(.init(id: outgoing.id, bytes: 256))).count == 1)
    }

    @Test func linesFromOneChannelGoAsOneFrame() throws {
        var (hostSession, client) = try connected()
        let (outgoing, credit) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        _ = try hostSession.receive(credit)
        for n in 0..<100 { hostSession.followOutput(outgoing.id, channel: .stdout, line: Data("line \(n)\n".utf8)) }
        #expect(hostSession.flushFollows().count == 1)
    }

    @Test func aPieceNeverOutgrowsTheNegotiatedFrame() throws {
        var limits = WireLimits.default
        limits.maxFrameBytes = 16 << 10
        var hostSession = WireHostSession(peer: host, limits: limits)
        var client = WireClientSession(peer: admin, limits: limits)
        guard case .send(let welcome)? = try hostSession.receive(client.hello()).first else { Issue.record("no welcome"); return }
        _ = try client.receive(welcome)
        #expect(client.uploadChunkCeiling < 16 << 10)
        let (outgoing, credit) = try client.follow(["logs", "-n", "50", "--follow", "web"])
        _ = try hostSession.receive(outgoing.message)
        _ = try hostSession.receive(credit)
        hostSession.followOutput(outgoing.id, channel: .stdout, line: Data(count: 64 << 10))
        for message in hostSession.flushFollows() {
            #expect(try message.encoded(limits: limits).count <= limits.maxFrameBytes)
        }
    }

    @Test func anUploadInTinyPiecesIsAViolationButItsLastPieceMayBeSmall() throws {
        let bytes = UInt64(WireStreamLimits.default.minUploadChunkBytes) + 10
        var (hostSession, client, id) = try acceptedUpload(bytes: bytes)
        #expect(throws: WireError.self) {
            try hostSession.receive(.streamData(.init(id: id, seq: 0, channel: .data, data: Data(count: 10))))
        }
        var (second, client2, id2) = try acceptedUpload(bytes: bytes)
        _ = try second.receive(try client2.uploadChunk(id2, Data(count: WireStreamLimits.default.minUploadChunkBytes)))
        guard case .uploadChunk? = try second.receive(try client2.uploadChunk(id2, Data(count: 10))).first else {
            Issue.record("last piece refused"); return
        }
        _ = client
    }

    @Test func creditForAFinishedUploadIsIgnoredByTheAdmin() throws {
        var (hostSession, client, id) = try acceptedUpload(bytes: 10)
        _ = try hostSession.receive(try client.uploadChunk(id, Data(count: 10)))
        _ = try hostSession.receive(try client.uploadEnd(id))
        let completed = hostSession.complete(id, with: CommandResult(stdout: "Loaded", stderr: "", exitCode: 0))
        let result = try #require(completed)
        _ = try client.receive(result)
        #expect(try client.receive(.streamCredit(.init(id: id, bytes: 100))).isEmpty)
        #expect(throws: WireError.self) { try client.receive(.streamCredit(.init(id: 4242, bytes: 100))) }
    }

    @Test func aHostMustChooseTheHighestVersionBothSpeak() throws {
        var client = WireClientSession(peer: admin, versions: 1...2)
        _ = client.hello()
        let lowball = WireMessage.welcome(.init(version: 1, peer: host, limits: .default, versions: 1...2))
        #expect(throws: WireError.self) { try client.receive(lowball) }
        // An older host that sends no range is taken at its word.
        var client2 = WireClientSession(peer: admin, versions: 1...2)
        _ = client2.hello()
        _ = try client2.receive(.welcome(.init(version: 1, peer: host, limits: .default)))
        #expect(!client2.canStream)
    }

    @Test func aHostLoadsOnlyWithAContainerAboveTheAdvisories() {
        #expect(!ImageTransfer.hostCanLoad(containerVersion: "1.3.0"))
        #expect(!ImageTransfer.hostCanLoad(containerVersion: nil))
        #expect(!ImageTransfer.hostCanLoad(containerVersion: "dev"))
        #expect(ImageTransfer.hostCanLoad(containerVersion: "1.3.1"))
        #expect(ImageTransfer.hostCanLoad(containerVersion: "1.5.0"))
    }

    @Test func aHostHoldingTheSentVariantAlreadyHasTheImage() throws {
        let url = try #require(Bundle.module.url(forResource: "images", withExtension: "json", subdirectory: "Fixtures"))
        let images = try JSONDecoder.flotilla.decode([ContainerImage].self, from: Data(contentsOf: url))
        let image = try #require(images.first { ImageTransfer.platform(for: $0) != nil })
        #expect(ImageTransfer.hostHasSame(image, as: image))
        // The host's index is a different, single-platform one, but its arm64 variant is ours.
        var single = image
        single.configuration.descriptor?.digest = "sha256:" + String(repeating: "0", count: 64)
        single.variants = image.variants?.filter { $0.platform?.architecture == "arm64" }
        #expect(ImageTransfer.hostHasSame(image, as: single))
        let other = try #require(images.first { $0.id != image.id && ImageTransfer.platform(for: $0) != nil
            && $0.configuration.descriptor?.digest != image.configuration.descriptor?.digest })
        #expect(!ImageTransfer.hostHasSame(image, as: other))
    }

    @Test func theArmVariantIsSentWhenThereIsOne() throws {
        let url = try #require(Bundle.module.url(forResource: "images", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let images = try JSONDecoder.flotilla.decode([ContainerImage].self, from: data)
        for image in images {
            let platform = ImageTransfer.platform(for: image)
            let hasArm = image.variants?.contains { $0.platform?.architecture == "arm64" && $0.platform?.os == "linux" } ?? false
            if hasArm { #expect(platform == "linux/arm64") }
        }
        #expect(images.contains { ImageTransfer.platform(for: $0) == "linux/arm64" })
    }
}
