# Jamf / configuration profiles — Flotilla (Phase 6)

Goal: onboard the physical, Jamf-managed Mac minis with **zero manual setup** —
the profile delivers the identity cert and the managed settings (mode, trust
anchors, allowlist). Because the transport already uses cert identities, this is a
config/source change, not a protocol change.

## Identity and managed policy

### 1. Identity certificate (the "key")

- **PKCS12 payload** (`com.apple.security.pkcs12`): a `.p12` (cert + private key,
  passphrase-protected) installed into the System/login keychain. Simplest for a
  small static fleet.
- **or SCEP/ACME payload**: dynamic per-device enrollment against a CA — better at
  scale, more setup. Overkill for ~8 machines; PKCS12 is fine.
- The app finds its identity in the Keychain by a known label (e.g.
  `Flotilla Identity`) — same lookup whether self-generated or profile-delivered.

### 2. Managed settings: two tiers

- **Custom Settings / Preferences payload** writing to the app's preference domain
  `dev.melonfleet.Flotilla`.
- Q4 settled two logical tiers:
  - **`defaults`** — managed seed values. They apply when the user has not chosen a
    value, but remain editable in Flotilla.
  - **`locked`** — managed overrides. They always win, are immutable in the UI,
    and display a lock with “Managed by configuration profile.”
- Keys include:
  - `mode` → `host` or `client`
  - `listenPort` (host mode)
  - `bonjourEnabled`
  - `trustAnchorFingerprints` → array of SHA-256 hex strings the device trusts
  - `peerAllowlist` → array of allowed peer fingerprints
  - `identityKeychainLabel`
  - update and diagnostics policy, minimum accepted client version, and fleet
    defaults

The profile author chooses the tier per key. For example, a suggested listen port
can be a `defaults` value, while `mode = host`, required mTLS, identity selection,
and trust policy normally belong in `locked`.

Effective precedence, highest first:

1. managed `locked`;
2. user value;
3. managed `defaults`;
4. built-in default.

A value's mere presence in managed policy does **not** make it authoritative; its
tier does.

## App-side requirements (build for this from Phase 2)

- Resolve every managed-capable value through the typed settings registry and an
  injectable managed-preferences source. Do not scatter direct/stringly-typed
  lookups through the app.
- Preserve the `defaults`/user/`locked` precedence above for every accessor.
- Expose value source and `isLocked` so Settings and Diagnostics render the
  effective policy honestly.
- Reject invalid managed values and show the validation error/source rather than
  silently coercing them.
- Resetting user preferences must not touch either managed tier.
- Look up the identity by Keychain label, not by a file path.
- Never allow remote settings messages to switch the app's run mode.

## Jamf mechanics

- Build the `.mobileconfig` (Apple Configurator, `iMazing Profile Editor`, or hand-
  written XML), then upload as a **Configuration Profile** in Jamf Pro and scope it
  to the mini smart group. Jamf can also deploy the `.app` (signed/notarized) and
  trigger it via policy.
- Managed app updates go through Jamf here instead of Sparkle.
- Deliver a unique identity per Mac. Never scope one shared PKCS#12 identity to a
  group.

## Note

This phase is the only one that needs the physical managed minis; everything before
it works with self-generated certs + in-app settings, so it can wait until after
the core app is solid. Test both installation orders, renewal overlap, profile
removal, reboot/logout, revocation, and segmented-network behavior on a staged
smart group before fleet rollout.
