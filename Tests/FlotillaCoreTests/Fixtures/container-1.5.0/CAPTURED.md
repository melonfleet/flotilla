# Fixture provenance

Captured by `Scripts/capture-fixtures.sh` from a real CLI. Never hand-written.

- **CLI:** `container CLI version 1.5.0 (build: release, commit: d265d66)`
- **Captured:** 2026-10-05
- **Account name anonymised to** `example`.

Not captured this time — each needs something the Mac did not have:

- containers-ports.json — needs a container with -p; run one, then re-run
- pull-progress.txt — capture with: container image pull <ref> 2> pull-progress.txt

Added 2026-10-06, by hand from the live CLI (`container ls --format json`, `container image
inspect`), for the configuration exporter:

- `export-containers.json` — `storefront-db` (named volume, custom network, a password variable)
  and `storefront-web` (a host folder, which 1.5.0 reports as a `virtiofs` mount). Account name
  anonymised to `example`; the demo database password replaced with `example-password`.
- `export-images.json` — `image inspect` of their two images, reduced to the arm64 variant.

Added 2026-10-10, from the live CLI on the development Mac (container 1.5.0), unedited — it names no
account or path of the owner's:

- `system-property-list.json` — `container system property list --format json`: the runtime's own
  settings (`config.toml` merged with its defaults), for a host's Settings tab.
