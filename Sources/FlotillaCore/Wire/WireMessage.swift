import Foundation

/// Who is on the other end, as it describes itself. Informational only — identity and trust come
/// from the pinned TLS key (B2), never from anything a peer says about itself here.
public struct WirePeerInfo: Sendable, Equatable, Codable {
    public var name: String
    public var appVersion: String
    public var macOSVersion: String?
    public var containerVersion: String?

    public init(name: String, appVersion: String, macOSVersion: String? = nil, containerVersion: String? = nil) {
        self.name = name
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.containerVersion = containerVersion
    }
}

/// Why a host turned a connection away. Raw values are the protocol.
public enum WireRejectCode: String, Sendable, Codable {
    case versionMismatch = "version-mismatch"
    case untrusted
    case busy
    case shuttingDown = "shutting-down"
}

/// Why one request failed without a result. Raw values are the protocol.
public enum WireFailureCode: String, Sendable, Codable {
    /// The Allowlist, the WirePolicy or the MountPolicy said no — nothing was spawned.
    case refused
    case timedOut = "timed-out"
    case cancelled
    case busy
    case invalidRequest = "invalid-request"
    case runtimeUnavailable = "runtime-unavailable"
    case internalError = "internal-error"
}

/// Every message, typed. `frame(limits:)` and `init(frame:limits:)` are the only way between a
/// message and bytes, so a header shape and its frame type cannot disagree.
public enum WireMessage: Sendable, Equatable {
    case hello(Hello)
    case welcome(Welcome)
    case reject(Reject)
    case request(Request)
    case cancel(Cancel)
    case result(Result)
    case failure(Failure)
    case ping(Ping)
    case pong(Ping)
    case close(Close)
    case pairStart(PairStart)
    case pairChallenge(PairChallenge)
    case pairProof(PairProof)
    case pairResult(PairResult)
    case pairConfirm(PairConfirm)
    case follow(Follow)
    case streamData(StreamData)
    case streamEnd(StreamEnd)
    case streamCredit(StreamCredit)
    case upload(Upload)

    public struct Hello: Sendable, Equatable, Codable {
        public var minVersion: UInt16
        public var maxVersion: UInt16
        public var peer: WirePeerInfo
        public var limits: WireLimits
        public var versions: ClosedRange<UInt16> { minVersion...max(minVersion, maxVersion) }

        public init(versions: ClosedRange<UInt16>, peer: WirePeerInfo, limits: WireLimits) {
            minVersion = versions.lowerBound
            maxVersion = versions.upperBound
            self.peer = peer
            self.limits = limits
        }
    }

    public struct Welcome: Sendable, Equatable, Codable {
        public var version: UInt16
        public var peer: WirePeerInfo
        /// The limits the host will hold this connection to — already the intersection of both.
        public var limits: WireLimits
        /// Whether the host trusts the caller's key. If not, only pairing is offered on this
        /// connection; every request is refused.
        public var trusted: Bool
        /// The host's whole range (version 2 onward), so the admin can check it was given the
        /// highest version both speak. Absent from an older host's welcome.
        public var minVersion: UInt16?
        public var maxVersion: UInt16?

        public init(version: UInt16, peer: WirePeerInfo, limits: WireLimits, trusted: Bool = true,
                    versions: ClosedRange<UInt16>? = nil) {
            self.version = version
            self.peer = peer
            self.limits = limits
            self.trusted = trusted
            minVersion = versions?.lowerBound
            maxVersion = versions?.upperBound
        }
    }

    public struct Reject: Sendable, Equatable, Codable {
        public var code: WireRejectCode
        public var message: String
        /// What the host speaks, so a version mismatch can say which side to update.
        public var minVersion: UInt16
        public var maxVersion: UInt16

        public init(code: WireRejectCode, message: String,
                    versions: ClosedRange<UInt16> = WireProtocol.supportedVersions) {
            self.code = code
            self.message = message
            minVersion = versions.lowerBound
            maxVersion = versions.upperBound
        }
    }

    public struct Request: Sendable, Equatable, Codable {
        public var id: UInt32
        /// The `container` arguments, without the binary. Validated again by the host.
        public var arguments: [String]
        /// A shorter deadline than the command's own, if the caller wants one. Never a longer one.
        public var timeout: TimeInterval?

        public init(id: UInt32, arguments: [String], timeout: TimeInterval? = nil) {
            self.id = id
            self.arguments = arguments
            self.timeout = timeout
        }
    }

    public struct Cancel: Sendable, Equatable, Codable {
        public var id: UInt32
        public init(id: UInt32) { self.id = id }
    }

    /// A finished command. stdout then stderr travel as raw bytes in the payload.
    public struct Result: Sendable, Equatable {
        public var id: UInt32
        public var exitCode: Int32
        public var stdout: Data
        public var stderr: Data
        public var stdoutTruncated: Bool
        public var stderrTruncated: Bool

        public init(id: UInt32, exitCode: Int32, stdout: Data, stderr: Data,
                    stdoutTruncated: Bool = false, stderrTruncated: Bool = false) {
            self.id = id
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.stdoutTruncated = stdoutTruncated
            self.stderrTruncated = stderrTruncated
        }

        /// As `ContainerHost` callers expect it.
        public var commandResult: CommandResult {
            CommandResult(stdout: String(decoding: stdout, as: UTF8.self),
                          stderr: String(decoding: stderr, as: UTF8.self),
                          exitCode: exitCode,
                          stdoutTruncated: stdoutTruncated, stderrTruncated: stderrTruncated)
        }

        struct Header: Codable {
            var id: UInt32
            var exitCode: Int32
            var stdoutBytes: Int
            var stdoutTruncated: Bool
            var stderrTruncated: Bool
        }
    }

    public struct Failure: Sendable, Equatable, Codable {
        public var id: UInt32
        public var code: WireFailureCode
        public var message: String

        public init(id: UInt32, code: WireFailureCode, message: String) {
            self.id = id
            self.code = code
            self.message = message
        }
    }

    public struct Ping: Sendable, Equatable, Codable {
        public var nonce: UInt64
        public init(nonce: UInt64) { self.nonce = nonce }
    }

    public struct Close: Sendable, Equatable, Codable {
        public var reason: String
        public init(reason: String) { self.reason = reason }
    }

    // MARK: Pairing (B2)

    public enum PairMethod: String, Sendable, Codable { case enrolmentKey = "enrolment-key", pairingCode = "pairing-code" }

    /// Admin → host: how it means to pair, its nonce, and what it says about itself.
    public struct PairStart: Sendable, Equatable, Codable {
        public var method: PairMethod
        public var nonce: Data
        public var details: PeerDetails
        public init(method: PairMethod, nonce: Data, details: PeerDetails) {
            self.method = method
            self.nonce = nonce
            self.details = details
        }
    }

    /// Host → admin, code pairing only: the host's nonce, so the admin's proof is fresh.
    public struct PairChallenge: Sendable, Equatable, Codable {
        public var nonce: Data
        public init(nonce: Data) { self.nonce = nonce }
    }

    /// Either way: an HMAC over the transcript, keyed by the shared secret or code. The host's
    /// carries its nonce (enrolment) and its details.
    public struct PairProof: Sendable, Equatable, Codable {
        public var mac: Data
        public var nonce: Data?
        public var details: PeerDetails?
        public init(mac: Data, nonce: Data? = nil, details: PeerDetails? = nil) {
            self.mac = mac
            self.nonce = nonce
            self.details = details
        }
    }

    public enum PairOutcome: String, Sendable, Codable {
        /// Enrolment: proved, and waiting for the owner's approval on the admin Mac.
        case pending
        case approved
        case refused
        /// Turned away or revoked before.
        case blocked
    }

    public struct PairResult: Sendable, Equatable, Codable {
        public var outcome: PairOutcome
        public var message: String
        public init(outcome: PairOutcome, message: String) {
            self.outcome = outcome
            self.message = message
        }
    }

    /// Code pairing: this side's owner compared the words and said yes (or no).
    public struct PairConfirm: Sendable, Equatable, Codable {
        public var confirmed: Bool
        public init(confirmed: Bool) { self.confirmed = confirmed }
    }

    // MARK: Streams (version 2; research/WIRE-STREAMS-D2.md)

    /// Admin → host: run this argv and stream its output — only a command whose spec declares
    /// `wireStreamFlags` (today `logs --follow`), validated by the host as a remote peer.
    public struct Follow: Sendable, Equatable, Codable {
        public var id: UInt32
        public var arguments: [String]
        public init(id: UInt32, arguments: [String]) { self.id = id; self.arguments = arguments }
    }

    public enum StreamChannel: String, Sendable, Codable {
        case stdout, stderr
        /// The host's own word about the stream — "N lines dropped" — never the command's output.
        case notice
        /// Upload bytes.
        case data
    }

    /// Either way: the next piece of a stream. Bytes ride in the payload, unescaped; `seq` counts
    /// from 0 with no gaps, so a lost or replayed piece is a protocol error, not silent corruption.
    public struct StreamData: Sendable, Equatable {
        public var id: UInt32
        /// 64-bit so it cannot wrap within any stream this protocol allows (Iris's review).
        public var seq: UInt64
        public var channel: StreamChannel
        public var data: Data
        public init(id: UInt32, seq: UInt64, channel: StreamChannel, data: Data) {
            self.id = id; self.seq = seq; self.channel = channel; self.data = data
        }

        struct Header: Codable {
            var id: UInt32
            var seq: UInt64
            var channel: StreamChannel
        }
    }

    /// The end of a stream. Host → admin when a follow stops (with the child's exit code, why, and
    /// how many lines were dropped for want of credit); admin → host when an upload's last byte
    /// has been sent.
    public struct StreamEnd: Sendable, Equatable, Codable {
        public var id: UInt32
        public var exitCode: Int32?
        public var reason: String?
        public var dropped: UInt64?
        public init(id: UInt32, exitCode: Int32? = nil, reason: String? = nil, dropped: UInt64? = nil) {
            self.id = id; self.exitCode = exitCode; self.reason = reason; self.dropped = dropped
        }
    }

    /// Permission to send `bytes` more on stream `id`. A sender never sends beyond its credit.
    public struct StreamCredit: Sendable, Equatable, Codable {
        public var id: UInt32
        public var bytes: UInt64
        public init(id: UInt32, bytes: UInt64) { self.id = id; self.bytes = bytes }
    }

    public enum UploadPurpose: String, Sendable, Codable {
        /// An OCI archive from `image save`, loaded with `image load` by the host itself.
        case imageLoad = "image-load"
    }

    /// Admin → host: about to send `bytes` bytes whose SHA-256 is `sha256`, for `purpose`. The host
    /// accepts with credit, or refuses with a `failure`. `label` is for the host's record only.
    public struct Upload: Sendable, Equatable, Codable {
        public var id: UInt32
        public var purpose: UploadPurpose
        public var bytes: UInt64
        public var sha256: String
        public var label: String
        public init(id: UInt32, purpose: UploadPurpose, bytes: UInt64, sha256: String, label: String) {
            self.id = id; self.purpose = purpose; self.bytes = bytes; self.sha256 = sha256; self.label = label
        }
    }

    public var frameType: WireFrameType {
        switch self {
        case .follow: .follow
        case .streamData: .streamData
        case .streamEnd: .streamEnd
        case .streamCredit: .streamCredit
        case .upload: .upload
        case .pairStart: .pairStart
        case .pairChallenge: .pairChallenge
        case .pairProof: .pairProof
        case .pairResult: .pairResult
        case .pairConfirm: .pairConfirm
        case .hello: .hello
        case .welcome: .welcome
        case .reject: .reject
        case .request: .request
        case .cancel: .cancel
        case .result: .result
        case .failure: .failure
        case .ping: .ping
        case .pong: .pong
        case .close: .close
        }
    }

    // MARK: To and from frames

    public func frame() throws -> WireFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
        switch self {
        case .hello(let m): return WireFrame(type: .hello, header: try json(m))
        case .welcome(let m): return WireFrame(type: .welcome, header: try json(m))
        case .reject(let m): return WireFrame(type: .reject, header: try json(m))
        case .request(let m): return WireFrame(type: .request, header: try json(m))
        case .cancel(let m): return WireFrame(type: .cancel, header: try json(m))
        case .failure(let m): return WireFrame(type: .failure, header: try json(m))
        case .ping(let m): return WireFrame(type: .ping, header: try json(m))
        case .pong(let m): return WireFrame(type: .pong, header: try json(m))
        case .close(let m): return WireFrame(type: .close, header: try json(m))
        case .pairStart(let m): return WireFrame(type: .pairStart, header: try json(m))
        case .pairChallenge(let m): return WireFrame(type: .pairChallenge, header: try json(m))
        case .pairProof(let m): return WireFrame(type: .pairProof, header: try json(m))
        case .pairResult(let m): return WireFrame(type: .pairResult, header: try json(m))
        case .pairConfirm(let m): return WireFrame(type: .pairConfirm, header: try json(m))
        case .follow(let m): return WireFrame(type: .follow, header: try json(m))
        case .streamEnd(let m): return WireFrame(type: .streamEnd, header: try json(m))
        case .streamCredit(let m): return WireFrame(type: .streamCredit, header: try json(m))
        case .upload(let m): return WireFrame(type: .upload, header: try json(m))
        case .streamData(let m):
            return WireFrame(type: .streamData,
                             header: try json(StreamData.Header(id: m.id, seq: m.seq, channel: m.channel)),
                             payload: m.data)
        case .result(let m):
            let header = Result.Header(id: m.id, exitCode: m.exitCode, stdoutBytes: m.stdout.count,
                                       stdoutTruncated: m.stdoutTruncated, stderrTruncated: m.stderrTruncated)
            return WireFrame(type: .result, header: try json(header), payload: m.stdout + m.stderr)
        }
    }

    public func encoded(limits: WireLimits) throws -> Data {
        try frame().encoded(limits: limits)
    }

    public init(frame: WireFrame) throws {
        let decoder = JSONDecoder()
        func json<T: Decodable>(_ type: T.Type) throws -> T {
            do { return try decoder.decode(type, from: frame.header) }
            catch { throw WireError.malformedHeader(frame.type) }
        }
        // Only a result and stream data carry a payload. Bytes after any other header are a
        // malformed frame, not something to ignore: a peer that sends them is not speaking this
        // protocol.
        if frame.type != .result, frame.type != .streamData, !frame.payload.isEmpty {
            throw WireError.malformedFrame("\(frame.type) carries a payload")
        }
        switch frame.type {
        case .hello: self = .hello(try json(Hello.self))
        case .welcome: self = .welcome(try json(Welcome.self))
        case .reject: self = .reject(try json(Reject.self))
        case .request: self = .request(try json(Request.self))
        case .cancel: self = .cancel(try json(Cancel.self))
        case .failure: self = .failure(try json(Failure.self))
        case .ping: self = .ping(try json(Ping.self))
        case .pong: self = .pong(try json(Ping.self))
        case .close: self = .close(try json(Close.self))
        case .pairStart: self = .pairStart(try json(PairStart.self))
        case .pairChallenge: self = .pairChallenge(try json(PairChallenge.self))
        case .pairProof: self = .pairProof(try json(PairProof.self))
        case .pairResult: self = .pairResult(try json(PairResult.self))
        case .pairConfirm: self = .pairConfirm(try json(PairConfirm.self))
        case .follow: self = .follow(try json(Follow.self))
        case .streamEnd: self = .streamEnd(try json(StreamEnd.self))
        case .streamCredit: self = .streamCredit(try json(StreamCredit.self))
        case .upload: self = .upload(try json(Upload.self))
        case .streamData:
            let header = try json(StreamData.Header.self)
            self = .streamData(StreamData(id: header.id, seq: header.seq, channel: header.channel,
                                          data: frame.payload))
        case .result:
            let header = try json(Result.Header.self)
            guard header.stdoutBytes >= 0, header.stdoutBytes <= frame.payload.count else {
                throw WireError.malformedFrame("result claims \(header.stdoutBytes) bytes of stdout")
            }
            let split = frame.payload.startIndex + header.stdoutBytes
            self = .result(Result(id: header.id, exitCode: header.exitCode,
                                  stdout: Data(frame.payload[..<split]),
                                  stderr: Data(frame.payload[split...]),
                                  stdoutTruncated: header.stdoutTruncated,
                                  stderrTruncated: header.stderrTruncated))
        }
    }
}
