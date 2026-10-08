import Foundation

/// Bounds for streams (research/WIRE-STREAMS-D2.md, and its "After review" section). Each side
/// holds its own and enforces them on what it receives; they are not negotiated, because a peer
/// has nothing to gain by knowing them — it is told what it may send by the credit it is given.
public struct WireStreamLimits: Sendable, Equatable {
    /// Follows open at once on one connection.
    public var maxFollowsPerConnection = 8
    /// What a follow may hold on the host while the admin grants no credit. Past it, whole lines
    /// are dropped and counted — a stalled admin costs the host this much per stream, never more.
    public var followBufferBytes = 256 << 10
    /// The largest piece of a follow on the wire, and the longest line kept whole.
    public var followChunkBytes = 64 << 10
    /// Credit an admin gives a new follow.
    public var followInitialCredit: UInt64 = 1 << 20
    /// The largest piece of an upload.
    public var uploadChunkBytes = 1 << 20
    /// The smallest piece of an upload but its last, so a peer cannot turn its credit into a flood
    /// of one-byte frames (Iris's review).
    public var minUploadChunkBytes = 64 << 10
    /// How far ahead of the disk an upload may run.
    public var uploadWindowBytes: UInt64 = 16 << 20
    /// The largest upload a host accepts, before the free-space check.
    public var maxUploadBytes: UInt64 = 8 << 30
    /// Uploads at once on one connection.
    public var maxUploadsPerConnection = 1
    /// Credit is clamped here, so a peer granting absurd amounts changes nothing.
    public var maxOutstandingCredit: UInt64 = 64 << 20
    /// What every data frame costs in credit at least, whatever it carries — the work of a frame is
    /// its header and its dispatch, not only its bytes (Iris's review).
    public var frameCharge = 256

    public init() {}
    public static let `default` = WireStreamLimits()

    /// Credit a data frame of `bytes` costs.
    func charge(_ bytes: Int) -> UInt64 { UInt64(max(bytes, frameCharge)) }

    /// The largest payload that fits a frame under `limits`, leaving room for the header.
    static func payloadCeiling(_ limits: WireLimits) -> Int {
        max(4 << 10, limits.maxFrameBytes - (8 << 10))
    }
}

/// Tombstones for ids that have just ended, so frames that crossed the end on the wire are
/// ignored rather than fatal — and an id that never existed still is.
private func remember(_ id: UInt32, in set: inout Set<UInt32>) {
    set.insert(id)
    if set.count > 128, let any = set.first(where: { $0 != id }) { set.remove(any) }
}

/// One followed command on the host: what it may still send, and what is waiting to be.
struct HostFollow: Sendable, Equatable {
    var credit: UInt64 = 0
    var seq: UInt64 = 0
    var pending: [(channel: WireMessage.StreamChannel, line: Data)] = []
    var pendingBytes = 0
    var dropped: UInt64 = 0
    var reportedDropped: UInt64 = 0
    /// The command has ended but output is still waiting for credit: its end is sent once that is
    /// out (or the admin stops the follow). Measured 8 October: a command that ended before the
    /// admin's first credit arrived lost every line, counted as dropped.
    var ending: (exitCode: Int32?, reason: String?)?

    static func == (a: HostFollow, b: HostFollow) -> Bool {
        a.credit == b.credit && a.seq == b.seq && a.pendingBytes == b.pendingBytes && a.dropped == b.dropped
    }
}

/// One upload arriving at the host.
struct HostUpload: Sendable, Equatable {
    let declared: UInt64
    let sha256: String
    var accepted = false
    var received: UInt64 = 0
    var written: UInt64 = 0
    var granted: UInt64 = 0
    var nextSeq: UInt64 = 0
    var ended = false
}

/// One follow the admin is reading.
struct ClientFollow: Sendable, Equatable {
    var nextSeq: UInt64 = 0
    var outstanding: UInt64
}

/// One upload the admin is sending.
struct ClientUpload: Sendable, Equatable {
    let declared: UInt64
    var sent: UInt64 = 0
    var credit: UInt64 = 0
    var seq: UInt64 = 0
    var ended = false
}

// MARK: - Host

extension WireHostSession {
    var streamsNegotiated: Bool {
        if case .ready(let version, _) = state { return version >= WireProtocol.streamsVersion }
        return false
    }

    /// Every id this connection is using, so a stream and a request can never share one.
    func idInUse(_ id: UInt32) -> Bool {
        inFlight.contains(id) || follows[id] != nil || uploads[id] != nil
    }

    /// The largest follow piece this connection's frames can carry.
    var followChunkCeiling: Int { min(streamLimits.followChunkBytes, WireStreamLimits.payloadCeiling(limits)) }
    var uploadChunkCeiling: Int { min(streamLimits.uploadChunkBytes, WireStreamLimits.payloadCeiling(limits)) }

    mutating func handleFollow(_ follow: WireMessage.Follow) throws -> [Event] {
        guard streamsNegotiated else { throw WireError.unexpected(.follow) }
        guard trusted else {
            return [.send(.failure(.init(id: follow.id, code: .refused, message: "This Mac hasn't been paired with this host.")))]
        }
        guard !idInUse(follow.id) else { throw WireError.duplicateRequestID(follow.id) }
        guard follows.count < streamLimits.maxFollowsPerConnection else {
            return [.send(.failure(.init(id: follow.id, code: .busy,
                                         message: "This host is already streaming \(follows.count) logs to you.")))]
        }
        let command: ValidatedCommand
        switch Allowlist.validate(follow.arguments, limits: allowlistLimits, mountPolicy: mountPolicy,
                                  execPolicy: execPolicy, wirePolicy: .remotePeer, followStream: true) {
        case .success(let validated): command = validated
        case .failure(let error):
            return [.send(.failure(.init(id: follow.id, code: .refused, message: String(describing: error))))]
        }
        follows[follow.id] = HostFollow()
        return [.startFollow(id: follow.id, command: command)]
    }

    mutating func handleUpload(_ upload: WireMessage.Upload) throws -> [Event] {
        guard streamsNegotiated else { throw WireError.unexpected(.upload) }
        guard trusted else {
            return [.send(.failure(.init(id: upload.id, code: .refused, message: "This Mac hasn't been paired with this host.")))]
        }
        guard !idInUse(upload.id) else { throw WireError.duplicateRequestID(upload.id) }
        guard uploads.count < streamLimits.maxUploadsPerConnection else {
            return [.send(.failure(.init(id: upload.id, code: .busy, message: "This host is already receiving an image from you.")))]
        }
        if case .ready(let version, _) = state, version < upload.purpose.minimumVersion {
            return [.send(.failure(.init(id: upload.id, code: .refused, message: "Not on this connection's version.")))]
        }
        guard upload.bytes > 0, upload.bytes <= streamLimits.maxUploadBytes else {
            return [.send(.failure(.init(id: upload.id, code: .refused,
                                         message: "That archive is larger than this host accepts.")))]
        }
        guard upload.sha256.count == 64, upload.sha256.allSatisfy(\.isHexDigit) else {
            return [.send(.failure(.init(id: upload.id, code: .invalidRequest, message: "Not a SHA-256 digest.")))]
        }
        inFlight.insert(upload.id)
        uploads[upload.id] = HostUpload(declared: upload.bytes, sha256: upload.sha256.lowercased())
        return [.startUpload(id: upload.id, upload: upload)]
    }

    mutating func handleCredit(_ credit: WireMessage.StreamCredit) throws -> [Event] {
        guard credit.bytes > 0 else { throw WireError.streamViolation("credit of nothing") }
        guard var follow = follows[credit.id] else {
            // Credit for a follow that has just ended crosses its end on the wire — not a fault.
            // Credit for anything else, an upload included, is: only the host grants those.
            if endedFollows.contains(credit.id) { return [] }
            throw WireError.streamViolation("credit for no follow (\(credit.id))")
        }
        let (sum, overflow) = follow.credit.addingReportingOverflow(credit.bytes)
        follow.credit = overflow ? streamLimits.maxOutstandingCredit : min(sum, streamLimits.maxOutstandingCredit)
        follows[credit.id] = follow
        if follow.ending != nil { return finishEnding(credit.id, flushing: true).map { .send($0) } }
        return flush(credit.id).map { .send($0) }
    }

    mutating func handleUploadData(_ data: WireMessage.StreamData) throws -> [Event] {
        guard var upload = uploads[data.id] else {
            // Bytes already granted may still be in flight after the host gave up on an upload.
            if retiredUploads.contains(data.id) { return [] }
            throw WireError.streamViolation("data for no upload (\(data.id))")
        }
        guard upload.accepted, !upload.ended, data.channel == .data else {
            throw WireError.streamViolation("data on upload \(data.id) out of turn")
        }
        guard data.seq == upload.nextSeq else { throw WireError.streamViolation("upload \(data.id) out of sequence") }
        guard !data.data.isEmpty, data.data.count <= uploadChunkCeiling else {
            throw WireError.streamViolation("upload piece of \(data.data.count) bytes")
        }
        let total = upload.received + UInt64(data.data.count)
        guard total <= upload.granted else { throw WireError.streamViolation("upload \(data.id) past its credit") }
        guard total <= upload.declared else { throw WireError.streamViolation("upload \(data.id) past its declared size") }
        // Only the last piece may be small.
        guard data.data.count >= min(streamLimits.minUploadChunkBytes, uploadChunkCeiling) || total == upload.declared else {
            throw WireError.streamViolation("upload piece of \(data.data.count) bytes is too small")
        }
        upload.received = total
        upload.nextSeq += 1
        uploads[data.id] = upload
        return [.uploadChunk(id: data.id, data: data.data)]
    }

    mutating func handleEnd(_ end: WireMessage.StreamEnd) throws -> [Event] {
        guard var upload = uploads[end.id] else {
            if retiredUploads.contains(end.id) { return [] }
            throw WireError.streamViolation("end of no upload (\(end.id))")
        }
        guard upload.accepted, !upload.ended else { throw WireError.streamViolation("upload \(end.id) ended twice") }
        upload.ended = true
        uploads[end.id] = upload
        guard upload.received == upload.declared else {
            if let reply = fail(end.id, code: .invalidRequest,
                                message: "The archive ended after \(upload.received) of \(upload.declared) bytes.") {
                return [.abortUpload(id: end.id), .send(reply)]
            }
            return [.abortUpload(id: end.id)]
        }
        return [.uploadFinished(id: end.id, sha256: upload.sha256)]
    }

    // MARK: Called by the host's transport

    /// One line of a followed command's output, buffered until the next `flushFollows`. Kept whole
    /// if it fits the buffer, otherwise dropped and counted; a line longer than a piece is cut to one.
    public mutating func followOutput(_ id: UInt32, channel: WireMessage.StreamChannel, line: Data) {
        guard var follow = follows[id], !line.isEmpty else { return }
        // A line cut to fit still ends in a newline, so the admin never joins it to the next.
        let kept = line.count <= followChunkCeiling ? line : line.prefix(followChunkCeiling - 1) + Data("\n".utf8)
        if follow.pendingBytes + kept.count > streamLimits.followBufferBytes {
            follow.dropped += 1
        } else {
            follow.pending.append((channel, Data(kept)))
            follow.pendingBytes += kept.count
        }
        follows[id] = follow
    }

    /// Everything every follow's credit allows, batched — called on a short tick rather than per
    /// line, so a chatty command becomes a few large frames, not many small ones.
    public mutating func flushFollows() -> [WireMessage] {
        follows.keys.sorted().flatMap { id in
            follows[id]?.ending != nil ? finishEnding(id, flushing: true) : flush(id)
        }
    }

    /// Whether any follow has output waiting.
    public var followsPending: Bool { follows.values.contains { !$0.pending.isEmpty || $0.dropped > $0.reportedDropped } }

    /// A followed command has stopped. What credit allows is sent now; if output is still waiting,
    /// the end waits with it — for credit, or for the admin to stop the follow — within the same
    /// buffer bound a running follow has.
    public mutating func followEnded(_ id: UInt32, exitCode: Int32?, reason: String?) -> [WireMessage] {
        guard var follow = follows[id] else { return [] }
        follow.ending = (exitCode, reason)
        follows[id] = follow
        return finishEnding(id, flushing: true)
    }

    /// Sends what credit allows of an ended follow, then its end once nothing is waiting — or at
    /// once, counting what is left as dropped, when `flushing` is false.
    mutating func finishEnding(_ id: UInt32, flushing: Bool) -> [WireMessage] {
        var out = flushing ? flush(id) : []
        guard let follow = follows[id], let ending = follow.ending else { return out }
        guard !flushing || follow.pending.isEmpty else { return out }
        follows.removeValue(forKey: id)
        remember(id, in: &endedFollows)
        let dropped = follow.dropped + UInt64(follow.pending.count)
        out.append(.streamEnd(.init(id: id, exitCode: ending.exitCode, reason: ending.reason,
                                    dropped: dropped > 0 ? dropped : nil)))
        return out
    }

    /// Sends as much of a follow's buffer as its credit allows: whole lines, grouped by channel,
    /// at most a piece at a time, each piece charged at least `frameCharge`; then a notice if lines
    /// were dropped since the last one.
    mutating func flush(_ id: UInt32) -> [WireMessage] {
        guard var follow = follows[id] else { return [] }
        var out: [WireMessage] = []
        while let first = follow.pending.first {
            // A run of whole lines from one channel, in order, as long as it fits a piece and the
            // credit. A line waits rather than being split.
            var chunk = Data()
            var taken = 0
            for entry in follow.pending {
                let size = chunk.count + entry.line.count
                guard entry.channel == first.channel, size <= followChunkCeiling,
                      streamLimits.charge(size) <= follow.credit else { break }
                chunk.append(entry.line)
                taken += 1
            }
            guard taken > 0 else { break }
            follow.pending.removeFirst(taken)
            follow.pendingBytes -= chunk.count
            follow.credit -= streamLimits.charge(chunk.count)
            out.append(.streamData(.init(id: id, seq: follow.seq, channel: first.channel, data: chunk)))
            follow.seq += 1
        }
        if follow.dropped > follow.reportedDropped {
            let note = Data("\(follow.dropped - follow.reportedDropped) lines dropped: Flotilla fell behind\n".utf8)
            if streamLimits.charge(note.count) <= follow.credit {
                follow.credit -= streamLimits.charge(note.count)
                follow.reportedDropped = follow.dropped
                out.append(.streamData(.init(id: id, seq: follow.seq, channel: .notice, data: note)))
                follow.seq += 1
            }
        }
        follows[id] = follow
        return out
    }

    /// The host has made room for an upload: its first credit.
    public mutating func acceptUpload(_ id: UInt32) -> WireMessage? {
        guard var upload = uploads[id], !upload.accepted else { return nil }
        upload.accepted = true
        upload.granted = min(upload.declared, streamLimits.uploadWindowBytes)
        uploads[id] = upload
        return .streamCredit(.init(id: id, bytes: upload.granted))
    }

    /// `bytes` more of an upload are on disk: credit to keep the window full.
    public mutating func uploadWrote(_ id: UInt32, bytes: UInt64) -> WireMessage? {
        guard var upload = uploads[id] else { return nil }
        upload.written = min(upload.received, upload.written + bytes)
        let target = min(upload.declared, upload.written + streamLimits.uploadWindowBytes)
        defer { uploads[id] = upload }
        guard target > upload.granted, !upload.ended else { return nil }
        let more = target - upload.granted
        upload.granted = target
        return .streamCredit(.init(id: id, bytes: more))
    }

    /// Bytes still to arrive for an upload — what its disk reservation must still cover.
    public func uploadRemaining(_ id: UInt32) -> UInt64? {
        uploads[id].map { $0.declared - $0.received }
    }

    /// The upload's state is gone; late bytes for it are ignored rather than fatal.
    mutating func retireUpload(_ id: UInt32) {
        guard uploads.removeValue(forKey: id) != nil else { return }
        remember(id, in: &retiredUploads)
    }
}

// MARK: - Admin

extension WireClientSession {
    var streamsNegotiated: Bool {
        if case .ready(let version, _) = state { return version >= WireProtocol.streamsVersion }
        return false
    }

    /// Whether the host this session talks to can stream.
    public var canStream: Bool { streamsNegotiated }

    /// The largest upload piece this connection's frames can carry.
    public var uploadChunkCeiling: Int { min(streamLimits.uploadChunkBytes, WireStreamLimits.payloadCeiling(limits)) }

    /// A follow for `arguments`, and the credit that opens it. Throws if the host is too old, the
    /// command cannot be followed, or too many are open.
    public mutating func follow(_ arguments: [String]) throws -> (outgoing: Outgoing, credit: WireMessage) {
        guard case .ready = state else { throw state == .closed ? WireError.closed : WireError.notConnected }
        guard streamsNegotiated else { throw WireError.streamsUnsupported }
        guard follows.count < streamLimits.maxFollowsPerConnection else {
            throw WireError.tooManyRequests(limit: streamLimits.maxFollowsPerConnection)
        }
        _ = try Allowlist.validated(arguments, wirePolicy: .remotePeer, followStream: true)
        let id = takeID()
        follows[id] = ClientFollow(outstanding: streamLimits.followInitialCredit)
        return (Outgoing(id: id, message: .follow(.init(id: id, arguments: arguments)), deadline: 0),
                .streamCredit(.init(id: id, bytes: streamLimits.followInitialCredit)))
    }

    /// More credit for a follow whose output has been handed on. `nil` once the follow is over, or
    /// when it already holds the most it may.
    public mutating func grant(_ id: UInt32, bytes: UInt64) -> WireMessage? {
        guard var follow = follows[id] else { return nil }
        let room = streamLimits.maxOutstandingCredit - min(follow.outstanding, streamLimits.maxOutstandingCredit)
        let more = min(bytes, room)
        guard more > 0 else { return nil }
        follow.outstanding += more
        follows[id] = follow
        return .streamCredit(.init(id: id, bytes: more))
    }

    /// Stops reading a follow: the host is asked to stop, and anything still arriving is ignored.
    public mutating func stopFollow(_ id: UInt32) -> WireMessage? {
        guard follows.removeValue(forKey: id) != nil else { return nil }
        remember(id, in: &stoppedFollows)
        return .cancel(.init(id: id))
    }

    /// An upload of `bytes` bytes with this SHA-256. Its answer is an ordinary result or failure.
    public mutating func upload(bytes: UInt64, sha256: String, label: String,
                                purpose: WireMessage.UploadPurpose = .imageLoad) throws -> Outgoing {
        guard case .ready = state else { throw state == .closed ? WireError.closed : WireError.notConnected }
        guard streamsNegotiated else { throw WireError.streamsUnsupported }
        if case .ready(let version, _) = state, version < purpose.minimumVersion { throw WireError.appUpdatesUnsupported }
        guard bytes > 0 else { throw WireError.streamViolation("an empty archive") }
        guard inFlight.count < limits.maxConcurrentRequests else {
            throw WireError.tooManyRequests(limit: limits.maxConcurrentRequests)
        }
        let id = takeID()
        inFlight.insert(id)
        uploads[id] = ClientUpload(declared: bytes)
        // Saving and loading an image can each take a while; the host's own deadline governs.
        return Outgoing(id: id, message: .upload(.init(id: id, purpose: purpose, bytes: bytes, sha256: sha256, label: label)),
                        deadline: 0)
    }

    /// How much of upload `id` may be sent now.
    public func uploadCredit(_ id: UInt32) -> UInt64 {
        guard let upload = uploads[id], !upload.ended else { return 0 }
        return upload.credit
    }

    /// Bytes of upload `id` not yet sent.
    public func uploadRemaining(_ id: UInt32) -> UInt64 {
        uploads[id].map { $0.declared - $0.sent } ?? 0
    }

    /// The next piece of an upload — never beyond credit or the declared size.
    public mutating func uploadChunk(_ id: UInt32, _ data: Data) throws -> WireMessage {
        guard var upload = uploads[id], !upload.ended else { throw WireError.streamViolation("no upload \(id) to send on") }
        guard !data.isEmpty, data.count <= uploadChunkCeiling, UInt64(data.count) <= upload.credit,
              upload.sent + UInt64(data.count) <= upload.declared else {
            throw WireError.streamViolation("upload piece of \(data.count) bytes doesn't fit")
        }
        let message = WireMessage.streamData(.init(id: id, seq: upload.seq, channel: .data, data: data))
        upload.seq += 1
        upload.sent += UInt64(data.count)
        upload.credit -= UInt64(data.count)
        uploads[id] = upload
        return message
    }

    /// The last byte has been sent.
    public mutating func uploadEnd(_ id: UInt32) throws -> WireMessage {
        guard var upload = uploads[id], !upload.ended else { throw WireError.streamViolation("no upload \(id) to end") }
        guard upload.sent == upload.declared else {
            throw WireError.streamViolation("upload \(id) ended after \(upload.sent) of \(upload.declared) bytes")
        }
        upload.ended = true
        uploads[id] = upload
        return .streamEnd(.init(id: id))
    }

    mutating func retire(upload id: UInt32) { remember(id, in: &finishedUploads) }

    mutating func receiveStream(_ message: WireMessage) throws -> [Event] {
        guard streamsNegotiated else { throw WireError.unexpected(message.frameType) }
        switch message {
        case .streamData(let data):
            guard var follow = follows[data.id] else {
                if stoppedFollows.contains(data.id) { return [] }
                throw WireError.streamViolation("data for no follow (\(data.id))")
            }
            guard data.channel != .data, !data.data.isEmpty else {
                throw WireError.streamViolation("empty or misdirected data on follow \(data.id)")
            }
            guard data.seq == follow.nextSeq else { throw WireError.streamViolation("follow \(data.id) out of sequence") }
            let cost = streamLimits.charge(data.data.count)
            guard cost <= follow.outstanding else { throw WireError.streamViolation("follow \(data.id) past its credit") }
            follow.outstanding -= cost
            follow.nextSeq += 1
            follows[data.id] = follow
            return [.streamData(id: data.id, channel: data.channel, data: data.data)]

        case .streamEnd(let end):
            guard follows.removeValue(forKey: end.id) != nil else {
                if stoppedFollows.contains(end.id) { return [] }
                throw WireError.streamViolation("end of no follow (\(end.id))")
            }
            remember(end.id, in: &stoppedFollows)
            return [.streamEnded(end)]

        case .streamCredit(let credit):
            guard credit.bytes > 0 else { throw WireError.streamViolation("credit of nothing") }
            guard var upload = uploads[credit.id] else {
                if finishedUploads.contains(credit.id) { return [] }
                throw WireError.streamViolation("credit for no upload (\(credit.id))")
            }
            // Never more than is left to send: a host cannot invite more than was declared.
            let (sum, overflow) = upload.credit.addingReportingOverflow(credit.bytes)
            upload.credit = min(overflow ? .max : sum, upload.declared - upload.sent)
            uploads[credit.id] = upload
            return [.uploadCredit(id: credit.id)]

        default:
            throw WireError.unexpected(message.frameType)
        }
    }

    mutating func takeID() -> UInt32 {
        var id = nextID
        // Skip anything still in use, so a stream and a request never share an id after a wrap.
        while inFlight.contains(id) || follows[id] != nil || uploads[id] != nil
            || stoppedFollows.contains(id) || finishedUploads.contains(id) {
            id = id == .max ? 1 : id + 1
        }
        nextID = id == .max ? 1 : id + 1
        return id
    }
}
