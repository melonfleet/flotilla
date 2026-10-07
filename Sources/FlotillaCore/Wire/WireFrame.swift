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
    public static let supportedVersions: ClosedRange<UInt16> = 1...1
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

    /// The stricter of two sets, field by field.
    public func intersection(_ other: WireLimits) -> WireLimits {
        WireLimits(maxFrameBytes: min(maxFrameBytes, other.maxFrameBytes),
                   maxHeaderBytes: min(maxHeaderBytes, other.maxHeaderBytes),
                   maxConcurrentRequests: min(maxConcurrentRequests, other.maxConcurrentRequests),
                   maxOutputBytesPerStream: min(maxOutputBytesPerStream, other.maxOutputBytesPerStream),
                   handshakeTimeout: min(handshakeTimeout, other.handshakeTimeout),
                   pingInterval: min(pingInterval, other.pingInterval),
                   idleTimeout: min(idleTimeout, other.idleTimeout),
                   deadlineGrace: min(deadlineGrace, other.deadlineGrace))
    }
}

/// What a frame is. The raw values are the protocol: never renumber one.
public enum WireFrameType: UInt8, Sendable, CaseIterable {
    case hello = 1, welcome = 2, reject = 3
    case request = 10, cancel = 11, result = 12, failure = 13
    case ping = 20, pong = 21
    case close = 30
    // 40–49 are reserved for bounded streams (image transfer, followed logs). A version-1 peer
    // refuses them as unknown, which is the point: they arrive with a version that negotiates them.
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
    public let limits: WireLimits
    private var buffer = Data()

    public init(limits: WireLimits = .default) { self.limits = limits }

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
