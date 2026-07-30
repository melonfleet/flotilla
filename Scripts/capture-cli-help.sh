#!/usr/bin/env bash
# Capture `--help` for every `container` subcommand into reference/cli-help/.
#
# WHY THIS EXISTS
#
# The `Allowlist` table is our security boundary, and it is only as good as its agreement with
# the real CLI. Two flags in it could never have worked:
#
#   * `network create --subnet-v6` and `--plugin` were simply absent, so the choices were
#     unreachable — and since a network's addressing can only be set at creation, permanently so.
#   * `volume create` declared `long: "size"`. The CLI has no long form; only `-s` exists. Since
#     canonicalisation prefers a long spelling, every sized volume would have emitted `--size`
#     and been rejected. The exhaustive shape test asserted the wrong argv, so it encoded the
#     bug instead of catching it.
#
# Both were found by hand, one at a time, because someone happened to look. This file makes the
# comparison mechanical: capture the CLI's own words, then audit the table against them.
#
# The agent VMs have no `container` installed, so this must run on a Mac. That is the whole
# point of committing the output — it is the only way a reviewer without the CLI can check the
# table against reality rather than against documentation, which has already proved wrong in
# several places (see reference/container-cli.md).
#
# Re-run after any `container` upgrade. The version is recorded in the header so a stale
# capture is obvious rather than silently trusted.

set -euo pipefail

command -v container >/dev/null || {
  echo "no \`container\` on PATH — this must run on a Mac with the CLI installed" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/reference/cli-help/container-1.0.0-help.txt"
mkdir -p "$(dirname "$OUT")"

SUBCOMMANDS=(
  "" run create start stop kill delete list inspect logs exec prune copy export build
  image "image pull" "image push" "image list" "image inspect" "image delete" "image tag"
  "image save" "image load" "image prune"
  volume "volume create" "volume delete" "volume list" "volume inspect" "volume prune"
  network "network create" "network delete" "network list" "network inspect" "network prune"
  system "system start" "system stop" "system status" "system logs" "system df" "system property"
  registry "registry login" "registry logout" builder machine
)

{
  echo "# Captured from a live \`container\` install — the authority for the Allowlist."
  echo "#"
  echo "# Regenerate with Scripts/capture-cli-help.sh on a Mac. The agent VMs have no"
  echo "# \`container\`, so this file is how a flag audit gets real evidence."
  echo "#"
  container --version 2>&1 | sed 's/^/# version: /'
  echo
} > "$OUT"

for cmd in "${SUBCOMMANDS[@]}"; do
  echo "===== container $cmd =====" >> "$OUT"
  # `--help` exits non-zero for an unknown subcommand; record whatever it says rather than
  # aborting, because "this subcommand does not exist" is itself a finding.
  container $cmd --help >> "$OUT" 2>&1 || true
  echo >> "$OUT"
done

echo "✓ $OUT"
echo "  $(grep -c '^===== ' "$OUT") subcommands, $(wc -l < "$OUT" | tr -d ' ') lines"
