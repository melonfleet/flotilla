# Network.framework + mTLS + Bonjour — Flotilla transport recipe

Reference notes for Phase 2. Code sketches are illustrative — adapt and let the
compiler guide you. Stable Apple API (not version-sensitive like Liquid Glass).

## Pieces

- **Service type:** `_flotilla._tcp` advertised/browsed over Bonjour.
- **Transport:** TCP + TLS 1.3, mutual auth (both ends present a cert).
- **Identity:** a `SecIdentity` (cert + private key) per app instance, stored in the
  Keychain. Self-signed now; Jamf-delivered later (see `jamf-config-profile.md`).
- **Authorization ("key list"):** each side keeps an allowlist of *peer* cert
  fingerprints (SHA-256 of the DER cert). Reject anything not on the list.
- **Framing:** length-prefixed messages — 4-byte big-endian UInt32 length + JSON
  body (see `wire-protocol.md`). Optionally implement as an `NWProtocolFramer`.

## TLS options (shared)

```swift
import Network

func tlsOptions(identity: sec_identity_t,
                verifyPeer: @escaping (SecCertificate) -> Bool) -> NWProtocolTLS.Options {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    sec_protocol_options_set_local_identity(sec, identity)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_set_verify_block(sec, { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        // pull leaf cert, hash it, check against allowlist
        guard let leaf = SecTrustCopyCertificateChain(secTrust).flatMap({ ($0 as? [SecCertificate])?.first }),
              verifyPeer(leaf) else { complete(false); return }
        complete(true)
    }, .main)
    return tls
}
```

- Wrap a `SecIdentity` into `sec_identity_t` via `sec_identity_create(secIdentity)`.
- On the **host (server)** side also require the client to present a cert:
  `sec_protocol_options_set_peer_authentication_required(sec, true)`.

## Host mode — listen + advertise

```swift
let params = NWParameters(tls: tlsOptions(identity: hostID, verifyPeer: allowlist.contains))
let listener = try NWListener(using: params)
listener.service = NWListener.Service(name: Host.current().localizedName,
                                      type: "_flotilla._tcp")
listener.newConnectionHandler = { conn in /* read framed requests, run CLI, stream back */ }
listener.start(queue: .main)
```

## Client mode — browse + connect

```swift
let browser = NWBrowser(for: .bonjour(type: "_flotilla._tcp", domain: nil), using: .init())
browser.browseResultsChangedHandler = { results, _ in /* update fleet list */ }
browser.start(queue: .main)

// connect to a chosen result (or a manual host:port endpoint)
let conn = NWConnection(to: endpoint,
                        using: NWParameters(tls: tlsOptions(identity: clientID,
                                                            verifyPeer: pinnedHosts.contains)))
conn.start(queue: .main)
```

## Manual host-add (mandatory — mDNS doesn't cross subnets/VLANs)

Accept `hostname/IP` + `port`, build `NWEndpoint.hostPort(host:port:)`, connect with
the same TLS params. Persist manual hosts alongside Bonjour-discovered ones.

## Trust bootstrap flow (manual, pre-Jamf)

1. On first run each app generates a self-signed identity (label `Flotilla Identity`)
   and shows its SHA-256 fingerprint (+ a QR/string to copy).
2. Pair: paste/scan the peer fingerprint into the other side's allowlist.
3. Connection succeeds only when each side's fingerprint is on the other's list.

Phase 6 replaces steps 1–2 with a Jamf-delivered identity + allowlist.

## Gotchas

- Run `NWListener`/`NWBrowser`/`NWConnection` callbacks off a consistent queue; bridge
  to the main actor for UI updates.
- `local network` usage prompts the user on macOS — set `NSLocalNetworkUsageDescription`
  and the `NSBonjourServices` array (`_flotilla._tcp`) in Info.plist.
- TLS verify block must `complete(false)` on every failure path or the handshake hangs.
- Fingerprint = SHA-256 over the cert's DER bytes (`SecCertificateCopyData`).
