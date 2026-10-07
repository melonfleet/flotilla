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

        public init(version: UInt16, peer: WirePeerInfo, limits: WireLimits) {
            self.version = version
            self.peer = peer
            self.limits = limits
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

    public var frameType: WireFrameType {
        switch self {
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
        // Only a result carries a payload. Bytes after any other header are a malformed frame,
        // not something to ignore: a peer that sends them is not speaking this protocol.
        if frame.type != .result, !frame.payload.isEmpty {
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
