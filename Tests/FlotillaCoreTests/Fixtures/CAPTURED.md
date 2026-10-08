# Fixture provenance

Captured by `Scripts/capture-fixtures.sh` from a real CLI. Never hand-written.

- **CLI:** `container CLI version 1.4.1 (build: release, commit: 9a8917c)`
- **Captured:** 2026-09-11
- **Account name anonymised to** `example`.

## dns-query-a.bin, dns-query-aaaa.bin (2026-10-08)

Real DNS queries for `web.mini.fleet.internal`, type A and AAAA, as `dig @127.0.0.1 -p 47869`
(macOS 27.0.1) sent them to a throwaway UDP listener. Note the EDNS OPT record dig appends after
the question — the responder must ignore it. Used by `FleetNamesTests`.

## container package fixtures (2026-10-08)

Captured from Apple's `container-1.5.0-installer-signed.pkg` (apple/container 1.5.0 release, 118 MB)
on macOS 27.0.1:

- `pkgutil-check-signature-container-1.5.0.txt` — `pkgutil --check-signature` on Apple's package.
- `container-1.5.0-PackageInfo.xml` — `PackageInfo` from `pkgutil --expand`.
- `pkgutil-pkg-info-container-1.5.0.txt` — `pkgutil --pkg-info com.apple.container-installer` on a
  Mac with 1.5.0 installed.
- `pkgutil-check-signature-unsigned.txt` — a package built with `pkgbuild` and not signed.
- `pkgutil-check-signature-other-team.txt` — the same package signed with a Developer ID Installer
  certificate that is not Apple's; the signer's name, team and fingerprint are replaced with
  placeholders (personal identity stays out of tracked files).
