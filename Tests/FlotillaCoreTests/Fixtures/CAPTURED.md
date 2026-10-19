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

## vulnerability-report.json (2026-10-18)

`report.json` as built by `flotilla-library/tools/build_report.py` from two **real** Grype 0.120.1 runs
(`grype registry:docker.io/library/nats:2.15.0 --platform linux/arm64 -o json`, and the same for
`registry:3.1.2`). Its index digest for nats was checked against the registry's own manifest
(`sha256` of the index body matched). It has two of the library's 32 images because only those two
were scanned for this fixture; it is unsigned, as the signature is checked separately. Used by
`VulnerabilityReportTests`.

## vulnerability-report-platform.json (2026-10-19)

`vulnerability-report.json` above with the `platform` section `build_report.py platform` made on
19 October 2026 from the **real** sources, fetched by the scan workflow's own fetch step:
https://gdmf.apple.com/v2/pmv (pinned Apple Root CA), https://support.apple.com/en-us/100100 and the
14 macOS 26 and 27 notes it links, apple/container's release tags 1.0.0 to 1.5.0 (their
`ContainerSystemConfig.swift`, and https://github.com/apple/container/releases/latest), and
https://osv-vulnerabilities.storage.googleapis.com/Linux/all.zip (33,014 records). The raw sources
are captured in the library repo's `tools/fixtures/platform/` (see its `CAPTURED.md`); this file is
what the builder made of them, checked by `platform_section`. Used by `PlatformAdvisoryTests`.
