# Fixture provenance

Captured by `Scripts/capture-fixtures.sh` from a real CLI. Never hand-written.

- **CLI:** `container CLI version 1.4.1 (build: release, commit: 9a8917c)`
- **Captured:** 2026-09-11
- **Account name anonymised to** `example`.

## dns-query-a.bin, dns-query-aaaa.bin (2026-10-08)

Real DNS queries for `web.mini.fleet.internal`, type A and AAAA, as `dig @127.0.0.1 -p 47869`
(macOS 27.0.1) sent them to a throwaway UDP listener. Note the EDNS OPT record dig appends after
the question — the responder must ignore it. Used by `FleetNamesTests`.
