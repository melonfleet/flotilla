import Foundation
import Network
import Security
import FlotillaCore
import FlotillaTrust

/// TLS for host mode: TLS 1.3 only, each side presenting its own `DeviceIdentity`, and the host
/// requiring the caller's certificate.
///
/// **The TLS layer accepts any certificate; trust is the fingerprint.** There is no certificate
/// authority here — every Mac's certificate is self-signed — so chain evaluation would prove
/// nothing. What TLS does prove, whatever the verify block answers, is that the peer holds the
/// private key for the certificate it presented. Flotilla then reads that certificate's
/// fingerprint and looks it up in its `PeerBook`: a known, approved key gets commands; any other
/// key can only pair (`WireHostSession.trusted`). Pinning lives in one place, above TLS, where it
/// is tested.
public enum WireTLS {
    public static let applicationProtocol = "flotilla/1"
    /// The Bonjour service type, advertised by a listening host (B3b).
    public static let serviceType = "_flotilla._tcp"

    /// The TXT record a host advertises: protocol version and its fingerprint's hex prefix.
    /// Its macOS version too, so two Macs with the same name can be told apart before pairing.
    /// And its local hostname: the name macOS's Sharing pane edits, which people rename expecting it
    /// to be "the name" (measured 7 October — a VM's hostname was renamed, its computer name not).
    public static func txtRecord(for fingerprint: PeerFingerprint, macOSVersion: String? = nil,
                                 hostname: String? = nil) -> NWTXTRecord {
        var entries = ["v": "1", "fp": fingerprintHint(fingerprint)]
        if let macOSVersion { entries["os"] = macOSVersion }
        if let hostname { entries["host"] = hostname }
        return NWTXTRecord(entries)
    }

    /// The first 16 bytes, as hex — enough to tell hosts apart; identity is still checked on connect.
    public static func fingerprintHint(_ fingerprint: PeerFingerprint) -> String {
        String(fingerprint.hex.prefix(32))
    }

    public static func parameters(identity: DeviceIdentity, server: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, applicationProtocol)
        if let secIdentity = identity.secIdentity(), let local = sec_identity_create(secIdentity) {
            sec_protocol_options_set_local_identity(options, local)
        }
        if server { sec_protocol_options_set_peer_authentication_required(options, true) }
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) },
                                              DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

/// One host-mode connection, either side: TLS, framing, and nothing else. It knows who the peer is
/// (the fingerprint of the certificate TLS saw) and turns bytes into `WireMessage`s and back.
/// What the messages mean is the sessions' business.
///
/// Everything happens on `queue`, a serial queue of its own; callbacks are called there.
public final class WireConnection: @unchecked Sendable {
    public let queue: DispatchQueue
    let connection: NWConnection
    private var decoder: WireFrameDecoder
    private var limits: WireLimits
    private var finished = false

    /// The fingerprint of the certificate the peer presented — set once TLS is up.
    public private(set) var peerFingerprint: PeerFingerprint?

    public var onReady: (@Sendable () -> Void)?
    public var onMessage: (@Sendable (WireMessage) -> Void)?
    /// Called once, with a reason when it was not a clean close.
    public var onClose: (@Sendable (String?) -> Void)?

    public init(_ connection: NWConnection, limits: WireLimits = .default, label: String = "wire") {
        self.connection = connection
        self.limits = limits
        decoder = WireFrameDecoder(limits: limits)
        queue = DispatchQueue(label: "dev.melonfleet.Flotilla.\(label)")
    }

    public var remoteEndpoint: NWEndpoint { connection.endpoint }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    /// Sends one message. Fails closed: a message that cannot be encoded within the limits ends
    /// the connection rather than being dropped quietly.
    public func send(_ message: WireMessage) {
        queue.async { [self] in
            guard !finished else { return }
            do {
                let data = try message.encoded(limits: limits)
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish("send failed: \(error.localizedDescription)") }
                })
            } catch {
                finish("couldn't send \(message.frameType): \(error)")
            }
        }
    }

    /// Adopts the limits a handshake agreed. Never looser than the ones it started with.
    public func adopt(_ agreed: WireLimits) {
        queue.async { [self] in
            limits = limits.intersection(agreed)
            decoder.adopt(agreed)
        }
    }

    /// Closes after everything already sent has gone. Sends on one connection are delivered in
    /// order, so an empty final message flushes them: a refusal followed by a hang-up arrives as a
    /// refusal (measured 7 October — cancelling at once dropped the reason, and the other side saw
    /// only a closed connection). Bounded, in case the peer stops reading.
    public func close(_ reason: String? = nil) {
        queue.async { [self] in
            guard !finished else { return }
            // Whichever comes first; `finish` runs once. **Strong** captures, deliberately: the
            // owner often lets go of a connection the moment it asks it to close (a stopping host
            // drops every handler), and a weak reference here meant the close never finished —
            // the socket was never cancelled and the other side held a dead connection
            // (measured 7 October). The closures are released once they run.
            queue.asyncAfter(deadline: .now() + 2) { [self] in finish(reason) }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [self] _ in finish(reason) })
        }
    }

    // MARK: Internals

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            peerFingerprint = Self.peerFingerprint(of: connection)
            guard peerFingerprint != nil else { return finish("the peer presented no usable certificate") }
            onReady?()
            receive()
        case .failed(let error):
            finish(error.localizedDescription)
        case .waiting(let error):
            // Not yet reachable. Treat as failure: the caller decides whether to try again.
            finish(error.localizedDescription)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) {
                        self.onMessage?(try WireMessage(frame: frame))
                        if self.finished { return }
                    }
                } catch {
                    return self.finish("protocol error: \(error)")
                }
            }
            if let error { return self.finish(error.localizedDescription) }
            if isComplete { return self.finish(nil) }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onReady = nil
        onMessage = nil
        onClose?(reason)
    }

    static func peerFingerprint(of connection: NWConnection) -> PeerFingerprint? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        return leaf.flatMap { try? DeviceIdentity.fingerprint(of: $0) }
    }
}
