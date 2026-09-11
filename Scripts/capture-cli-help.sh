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
# **Named for the version it captured, derived — not hardcoded.** It used to say `1.0.0`
# literally, so running it after an upgrade overwrote the 1.0.0 record with 1.4.1 output under
# the 1.0.0 name: the exact "stale capture silently trusted" failure the header above warns
# about, in the file that is supposed to prevent it. Now each version gets its own file and the
# old one stays as evidence of what that version said.
CLI_VERSION="$(container --version 2>/dev/null | sed -nE 's/.*version ([0-9][0-9A-Za-z.-]*).*/\1/p' | head -1)"
[ -n "$CLI_VERSION" ] || CLI_VERSION="unknown"
OUT="$ROOT/reference/cli-help/container-$CLI_VERSION-help.txt"
mkdir -p "$(dirname "$OUT")"

# Every leaf, including the ones Flotilla deliberately does not allow — the point is to see what
# the CLI offers, not what we use. The 1.4.1 additions are at the end: `clean`, the `machine`
# leaves that were only reachable through the parent before, and the experimental `k8s` family,
# which is listed precisely so a future audit can see it is still out of scope on purpose.
SUBCOMMANDS=(
  "" run create start stop kill delete list inspect logs exec prune copy export build clean
  image "image pull" "image push" "image list" "image inspect" "image delete" "image tag"
  "image save" "image load" "image prune"
  volume "volume create" "volume delete" "volume list" "volume inspect" "volume prune"
  network "network create" "network delete" "network list" "network inspect" "network prune"
  system "system start" "system stop" "system status" "system logs" "system df" "system property"
  "system kernel" "system kernel set"
  registry "registry login" "registry logout" builder
  machine "machine create" "machine delete" "machine inspect" "machine list" "machine logs"
  "machine run" "machine set" "machine set-default" "machine stop"
  k8s "k8s create" "k8s start" "k8s delete" "k8s list" "k8s load-image" "k8s write-config"
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
