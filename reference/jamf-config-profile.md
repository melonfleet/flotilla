# Jamf / configuration profiles — Flotilla (Phase 6)

Goal: onboard the physical, Jamf-managed Mac minis with **zero manual setup** —
the profile delivers the identity cert and the managed settings (mode, trust
anchors, allowlist). Because the transport already uses cert identities, this is a
config/source change, not a protocol change.

## Two payloads in one profile

### 1. Identity certificate (the "key")

- **PKCS12 payload** (`com.apple.security.pkcs12`): a `.p12` (cert + private key,
  passphrase-protected) installed into the System/login keychain. Simplest for a
  small static fleet.
- **or SCEP/ACME payload**: dynamic per-device enrollment against a CA — better at
  scale, more setup. Overkill for ~8 machines; PKCS12 is fine.
- The app finds its identity in the Keychain by a known label (e.g.
  `Flotilla Identity`) — same lookup whether self-generated or profile-delivered.

### 2. Managed settings (mode + trust)

- **Custom Settings / Preferences payload** writing to the app's preference domain
  (e.g. `com.<you>.Flotilla`). Managed (force-installed) preferences appear in the
  app via `UserDefaults.standard` as read-only values. Keys:
  - `mode` → `host` or `client`
  - `listenPort` (host mode)
  - `trustAnchorFingerprints` → array of SHA-256 hex strings the device trusts
  - `peerAllowlist` → array of allowed peer fingerprints
- The app reads these on launch; if a managed value is present it wins over the
  local UI setting (so an admin can pin a mini to host mode).

## App-side requirements (build for this from Phase 2)

- Read `mode`, port, trust anchors, and allowlist from `UserDefaults` so a managed
  profile can override them later without code changes.
- Look up the identity by Keychain label, not by a file path.
- Treat "managed value present" as authoritative; fall back to in-app UI config
  when unmanaged.

## Jamf mechanics

- Build the `.mobileconfig` (Apple Configurator, `iMazing Profile Editor`, or hand-
  written XML), then upload as a **Configuration Profile** in Jamf Pro and scope it
  to the mini smart group. Jamf can also deploy the `.app` (signed/notarized) and
  trigger it via policy.
- Managed app updates go through Jamf here instead of Sparkle.

## Note

This phase is the only one that needs the physical managed minis; everything before
it works with self-generated certs + in-app settings, so it can wait until after
the core app is solid.
