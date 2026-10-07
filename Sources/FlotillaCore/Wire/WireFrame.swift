import Foundation

/// The host-mode wire protocol (PLAN.md Phase B, slice B1): framing, messages and limits.
///
/// Transport-free on purpose. Nothing here opens a socket: B3 moves these bytes over
/// Network.framework with mutual TLS, and every rule that keeps a peer honest lives here, where it
/// is tested on macOS and Linux alike. The wire carries **validated `container` argument arrays**
/// and their results (DECISIONS Q1) — never a command string, never a shell.
public enum WireProtocol {
    /// The versions this build speaks. A peer outside them is told so, with this range, so the UI
    /// can say which side needs updating rather than "connection failed".
    /// Version 2 (PLAN.md Phase D, D2) adds bounded streams — following a host's logs and sending
    /// it an image (research/WIRE-STREAMS-D2.md). Their frames are refused on a version-1
    /// connection, so a version-1 peer is unaffected.
    /// Version 3 (D3) adds typed host calls — DNS on a host, through its own helper
    /// (research/FLEET-DNS-D3.md, DECISIONS Q36).
    /// Version 4 adds the `.hostFacts` call — a host's chip, memory and disk, for Overview.
    public static let supportedVersions: ClosedRange<UInt16> = 1...4
    /// The first version that carries streams.
    public static let streamsVersion: UInt16 = 2
    /// The first version that carries host calls.
    public static let hostCallsVersion: UInt16 = 3
    /// The first version that answers `.hostFacts`.
    public static let hostFactsVersion: UInt16 = 4
    /// The owner's choice, 7 October. Changeable in Settings.
    public static let defaultPort: UInt16 = 7868

    /// The highest version both sides speak, or `nil` when the ranges do not meet.
    public static func negotiate(_ a: ClosedRange<UInt16>, _ b: ClosedRange<UInt16>) -> UInt16? {
        let top = min(a.upperBound, b.upperBound)
        return top >= max(a.lowerBound, b.lowerBound) ? top : nil
    }
}

/// Every bound the protocol enforces. Each side has its own and the session uses the **smaller**
/// of the two (`intersection`), so neither can talk the other into a looser limit.
public struct WireLimits: Sendable, Equatable, Codable {
    /// The whole frame, header and payload. Sized to carry one result at the `LocalHost` ceiling
    /// (4 MiB per stream, Q15) with room to spare, and checked against the **declared** length
    /// before a byte is buffered, so a peer cannot make us allocate by claiming a huge frame.
    public var maxFrameBytes: Int
    /// The JSON header. Requests and control messages are small; a large header is an attack or
    /// a bug, and either way it is not parsed.
    public var maxHeaderBytes: Int
    /// Requests in flight per connection.
    public var maxConcurrentRequests: Int
    /// Output kept per stream per result; the rest is dropped and the result says so.
    public var maxOutputBytesPerStream: Int
    /// Seconds a new connection has to say hello.
    public var handshakeTimeout: TimeInterval
    /// Seconds of silence before a ping, and before giving up on the peer.
    public var pingInterval: TimeInterval
    public var idleTimeout: TimeInterval
    /// Added to a command's own deadline on the requesting side, for the round trip.
    public var deadlineGrace: TimeInterval

    public init(maxFrameBytes: Int = 16 << 20, maxHeaderBytes: Int = 64 << 10,
                maxConcurrentRequests: Int = 4, maxOutputBytesPerStream: Int = 4 << 20,
                handshakeTimeout: TimeInterval = 10, pingInterval: TimeInterval = 20,
                idleTimeout: TimeInterval = 60, deadlineGrace: TimeInterval = 10) {
        self.maxFrameBytes = maxFrameBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxOutputBytesPerStream = maxOutputBytesPerStream
        self.handshakeTimeout = handshakeTimeout
        self.pingInterval = pingInterval
        self.idleTimeout = idleTimeout
        self.deadlineGrace = deadlineGrace
    }

    public static let `default` = WireLimits()

    /// What a peer's limits are combined with ours to give (Iris's review, 7 October).
    ///
    /// **Resource ceilings** — frame, header, output, concurrency — take the smaller of the two, so
    /// neither side can widen what the other accepts. **Timers stay ours**: "smaller is stricter" is
    /// false for a ping interval, where a peer asking for a tiny one would have us ping without
    /// rest, and a negative deadline means nothing. A peer's ceilings are clamped into sane ranges
    /// first, so a negative or zero size cannot reach a `prefix` or a count.
    public func intersection(_ other: WireLimits) -> WireLimits {
        let peer = other.sanitised
        return WireLimits(maxFrameBytes: min(maxFrameBytes, peer.maxFrameBytes),
                          maxHeaderBytes: min(maxHeaderBytes, peer.maxHeaderBytes),
                          maxConcurrentRequests: min(maxConcurrentRequests, peer.maxConcurrentRequests),
                          maxOutputBytesPerStream: min(maxOutputBytesPerStream, peer.maxOutputBytesPerStream),
                          handshakeTimeout: handshakeTimeout,
                          pingInterval: pingInterval,
                          idleTimeout: idleTimeout,
                          deadlineGrace: deadlineGrace)
    }

    /// Every field forced into a range that works. Floors keep a peer from shrinking a limit to
    /// nothing; ceilings keep the numbers within what this build was designed for.
    public var sanitised: WireLimits {
        func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T { Swift.max(low, Swift.min(high, value)) }
        return WireLimits(maxFrameBytes: clamp(maxFrameBytes, 64 << 10, 64 << 20),
                          maxHeaderBytes: clamp(maxHeaderBytes, 4 << 10, 1 << 20),
                          maxConcurrentRequests: clamp(maxConcurrentRequests, 1, 64),
                          maxOutputBytesPerStream: clamp(maxOutputBytesPerStream, 4 << 10, 64 << 20),
                          handshakeTimeout: clamp(handshakeTimeout, 2, 120),
                          pingInterval: clamp(pingInterval, 5, 300),
                          idleTimeout: clamp(idleTimeout, 15, 3600),
                          deadlineGrace: clamp(deadlineGrace, 1, 120))
    }
}

/// What a frame is. The raw values are the protocol: never renumber one.
public enum WireFrameType: UInt8, Sendable, CaseIterable {
    case hello = 1, welcome = 2, reject = 3
    /// Pairing and enrolment (B2), before a peer is trusted: see `PairingAdminSession`.
    case pairStart = 4, pairChallenge = 5, pairProof = 6, pairResult = 7, pairConfirm = 8
    case request = 10, cancel = 11, result = 12, failure = 13
    case ping = 20, pong = 21
    case close = 30
    // Bounded streams, version 2 (D2). A version-1 session refuses them as unexpected, which is
    // the point: they arrive only on a connection that negotiated them.
    case follow = 40, streamData = 41, streamEnd = 42, streamCredit = 43, upload = 44
    // Host calls, version 3 (D3). 46–49 stay reserved.
    case hostCall = 45
}

/// One frame: a type, a JSON header, and raw bytes. Command output rides in `payload` as bytes, so
/// it is never JSON-escaped — escaping can multiply control characters sixfold, and a limit that
/// held for the text would not hold for its encoding.
///
/// On the wire: `[UInt32 length][UInt8 type][UInt32 header length][header][payload]`, big-endian,
/// where `length` counts everything after itself.
public struct WireFrame: Sendable, Equatable {
    public let type: WireFrameType
    public let header: Data
    public let payload: Data

    public init(type: WireFrameType, header: Data, payload: Data = Data()) {
        self.type = type
        self.header = header
        self.payload = payload
    }

    static let prefixBytes = 4
    static let fixedBodyBytes = 1 + 4

    /// The encoded frame. Refuses to build one the peer would refuse to read.
    public func encoded(limits: WireLimits) throws -> Data {
        guard header.count <= limits.maxHeaderBytes else { throw WireError.headerTooLarge(header.count) }
        let length = Self.fixedBodyBytes + header.count + payload.count
        guard length <= limits.maxFrameBytes else { throw WireError.frameTooLarge(length) }
        var data = Data(capacity: Self.prefixBytes + length)
        data.appendBigEndian(UInt32(length))
        data.append(type.rawValue)
        data.appendBigEndian(UInt32(header.count))
        data.append(header)
        data.append(payload)
        return data
    }
}

/// Turns a byte stream into frames, however it is chunked.
///
/// Fails closed: the first malformed frame is an error and the connection must be dropped —
/// there is no resynchronising a length-prefixed stream after a bad length.
public struct WireFrameDecoder: Sendable {
    public private(set) var limits: WireLimits
    private var buffer = Data()

    public init(limits: WireLimits = .default) { self.limits = limits }

    /// Holds incoming frames to the limits a handshake agreed, from the next frame on. Never looser
    /// (Iris's review: only outgoing frames were held to them).
    public mutating func adopt(_ agreed: WireLimits) { limits = limits.intersection(agreed) }

    /// Bytes held waiting for the rest of a frame.
    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ bytes: Data) throws -> [WireFrame] {
        buffer.append(bytes)
        var frames: [WireFrame] = []
        while true {
            guard buffer.count >= WireFrame.prefixBytes else { break }
            let length = Int(buffer.readBigEndianUInt32(at: 0))
            // Checked on the declared length, before waiting for the bytes: a peer that claims
            // 4 GB is refused now, not after we have tried to hold it.
            guard length <= limits.maxFrameBytes else { throw WireError.frameTooLarge(length) }
            guard length >= WireFrame.fixedBodyBytes else { throw WireError.malformedFrame("length \(length) is shorter than a frame") }
            guard buffer.count >= WireFrame.prefixBytes + length else { break }

            let start = buffer.startIndex + WireFrame.prefixBytes
            let typeByte = buffer[start]
            guard let type = WireFrameType(rawValue: typeByte) else { throw WireError.unknownFrameType(typeByte) }
            let headerLength = Int(buffer.readBigEndianUInt32(at: WireFrame.prefixBytes + 1))
            guard headerLength <= limits.maxHeaderBytes else { throw WireError.headerTooLarge(headerLength) }
            guard WireFrame.fixedBodyBytes + headerLength <= length else {
                throw WireError.malformedFrame("header length \(headerLength) runs past the frame")
            }
            let headerStart = start + WireFrame.fixedBodyBytes
            let payloadStart = headerStart + headerLength
            let end = start + length
            frames.append(WireFrame(type: type,
                                    header: Data(buffer[headerStart..<payloadStart]),
                                    payload: Data(buffer[payloadStart..<end])))
            buffer = Data(buffer[end...])
        }
        return frames
    }
}

/// Everything that can go wrong on the wire, in words fit for a log line. A protocol error ends the
/// connection; a request's own failure travels back as a `failure` message instead.
public enum WireError: Error, Equatable, Sendable, CustomStringConvertible {
    case frameTooLarge(Int)
    case headerTooLarge(Int)
    case malformedFrame(String)
    case unknownFrameType(UInt8)
    case malformedHeader(WireFrameType)
    /// A message that is valid but not now — a request before the handshake, a second hello.
    case unexpected(WireFrameType)
    case versionMismatch(peer: ClosedRange<UInt16>)
    case duplicateRequestID(UInt32)
    case unknownRequestID(UInt32)
    case tooManyRequests(limit: Int)
    case notConnected
    case closed
    /// A stream on a connection that did not negotiate version 2.
    case streamsUnsupported
    /// A stream message that breaks its rules — out of sequence, beyond its credit, past its
    /// declared size, for a stream that does not exist. Closes the connection.
    case streamViolation(String)
    /// A host call on a connection that did not negotiate version 3.
    case hostCallsUnsupported
    /// A host call its own rules refuse, caught before it is sent.
    case hostCallRefused(String)

    public var description: String {
        switch self {
        case .frameTooLarge(let n): "frame of \(n) bytes is over the limit"
        case .headerTooLarge(let n): "header of \(n) bytes is over the limit"
        case .malformedFrame(let why): "malformed frame: \(why)"
        case .unknownFrameType(let t): "unknown frame type \(t)"
        case .malformedHeader(let t): "unreadable \(t) message"
        case .unexpected(let t): "unexpected \(t) message"
        case .versionMismatch(let r): "no protocol version in common (peer speaks \(r.lowerBound)–\(r.upperBound))"
        case .duplicateRequestID(let id): "request \(id) is already in flight"
        case .unknownRequestID(let id): "no request \(id) is in flight"
        case .tooManyRequests(let n): "more than \(n) requests in flight"
        case .notConnected: "the handshake has not finished"
        case .closed: "the connection is closed"
        case .streamsUnsupported: "this host's Flotilla is too old to stream — update it"
        case .streamViolation(let why): "stream error: \(why)"
        case .hostCallsUnsupported: "this host's Flotilla is too old for that — update it"
        case .hostCallRefused(let why): why
        }
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
