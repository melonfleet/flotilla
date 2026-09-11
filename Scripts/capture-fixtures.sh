#!/usr/bin/env bash
# Recapture the JSON fixtures from the `container` CLI actually installed on this Mac.
#
# WHY THIS EXISTS
#
# `CLAUDE.md`: **fixtures must be captured, never written.** A hand-written fixture tests that
# the decoder agrees with whoever typed it, which is the one thing nobody needs to know. Until
# now the sixteen fixtures were captured by hand, one command at a time — which is fine once and
# a liability every time `container` is upgraded, because the boring half (run it, anonymise it,
# write it, note the version) is exactly the half that gets skipped.
#
# Apple guarantees CLI stability only *within* a patch series. Every minor upgrade can therefore
# move a payload, and the only way to find out is to look. This makes looking one command.
#
# WHAT IT DOES NOT DO
#
# Fixtures that need a specific resource to exist — a container with published ports, a named
# volume created with `--size 64M`, a machine — are captured only if something suitable is
# present. It says which ones it skipped rather than writing a plausible-looking file, because a
# fixture that was invented is worse than one that is missing: the missing one fails a test.
#
# USAGE
#   Scripts/capture-fixtures.sh            # capture what this Mac can
#   Scripts/capture-fixtures.sh --dry-run  # print what it would capture, write nothing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Tests/FlotillaCoreTests/Fixtures"
DRY=false
[ "${1:-}" = "--dry-run" ] && DRY=true

command -v container >/dev/null || {
  echo "no \`container\` on PATH — this must run on a Mac with the CLI installed" >&2
  exit 1
}

VERSION="$(container --version 2>/dev/null | head -1)"
echo "▸ capturing against: $VERSION"
echo

# The real account name must never reach a committed fixture. `example` is the placeholder the
# existing fixtures use; `system-status.json` historically used `user`, and this normalises both
# to `example` so the set stops disagreeing with itself.
ME="$(id -un)"
anonymise() {
  sed -e "s|/Users/$ME|/Users/example|g" -e "s|\\\\/Users\\\\/$ME|\\\\/Users\\\\/example|g" \
      -e "s|\"$ME\"|\"example\"|g"
}

captured=0
skipped=()

capture() {   # capture <fixture> <description> <container args…>
  local name="$1" what="$2"; shift 2
  local body
  if ! body="$(container "$@" 2>/dev/null)" || [ -z "$body" ] || [ "$body" = "[]" ]; then
    skipped+=("$name — $what")
    return
  fi
  if $DRY; then
    printf '  would write %-26s (%s)\n' "$name" "$what"
  else
    printf '%s' "$body" | anonymise > "$OUT/$name"
    printf '  ✓ %-26s %s\n' "$name" "$what"
  fi
  captured=$((captured + 1))
}

# Nothing special needed: these describe whatever the Mac has.
capture containers.json     "all containers"        ls --all --format json
capture images.json         "all images"            image list --format json
capture volumes.json        "all volumes"           volume list --format json
capture networks.json       "all networks"          network list --format json
capture machines.json       "all machines"          machine list --format json
capture system-df.json      "disk usage"            system df --format json
capture system-status.json  "service status"        system status --format json
capture version.json        "component versions"    system version --format json
capture stats.json          "one stats sample"      stats --no-stream --format json

# These need a subject. First of each kind, whatever it is — the decoder does not care which
# container it was, only that the shape is the CLI's own.
first() { container "$1" list --format json 2>/dev/null | python3 -c "
import json,sys
try: items = json.load(sys.stdin)
except Exception: sys.exit(1)
if not items: sys.exit(1)
item = items[0]
print(item.get('id') or item.get('name') or item.get('configuration',{}).get('name',''))
" 2>/dev/null; }

# A running container for preference, for the same reason as the machine below: `status.networks`
# and the address in it exist only while one is up.
if id="$(container ls --all --format json | python3 -c "
import json,sys
items=json.load(sys.stdin)
def running(c):
    s = c.get('status')
    return (s.get('state') if isinstance(s, dict) else s) == 'running'
up = [c for c in items if running(c)]
print((up or items or [{}])[0].get('configuration',{}).get('id',''))" 2>/dev/null)" && [ -n "$id" ]; then
  capture inspect-container.json "inspect $id" inspect "$id"
else
  skipped+=("inspect-container.json — no container exists")
fi

# A volume created with an explicit `--size` for preference: `options.size` only exists on one,
# and it is the field that shows the reported size is a *capacity*, not usage.
VOLUME="$(container volume list --format json 2>/dev/null | python3 -c "
import json,sys
try: items = json.load(sys.stdin)
except Exception: sys.exit(0)
sized = [v for v in items if (v.get('configuration') or {}).get('options', {}).get('size')]
print((sized or items or [{}])[0].get('id',''))
" 2>/dev/null)"
if [ -n "$VOLUME" ]; then
  capture inspect-volume.json "inspect $VOLUME" volume inspect "$VOLUME"
else
  skipped+=("inspect-volume.json — no volume exists")
fi

# The built-in network for preference: it is the one every container lands on by default, and
# the one whose `builtin` role label gates whether Flotilla offers to delete it.
NETWORK="$(container network list --format json 2>/dev/null | python3 -c "
import json,sys
try: items = json.load(sys.stdin)
except Exception: sys.exit(0)
names = [n.get('id') for n in items]
print('default' if 'default' in names else (names[0] if names else ''))
" 2>/dev/null)"
if [ -n "$NETWORK" ]; then
  capture inspect-network.json "inspect $NETWORK" network inspect "$NETWORK"
else
  skipped+=("inspect-network.json — no network exists")
fi

if ref="$(container image list --format json | python3 -c "
import json,sys
items=json.load(sys.stdin)
print(items[0].get('configuration',{}).get('name','') if items else '')" 2>/dev/null)" && [ -n "$ref" ]; then
  capture inspect-image.json "inspect $ref" image inspect "$ref"
else
  skipped+=("inspect-image.json — no image exists")
fi

# A **running** machine for preference. `ipAddress`, `startedDate` and `containerId` exist only
# while one is up, so a fixture captured from a stopped machine silently drops three fields from
# the decoder's coverage — which is how those three would rot unnoticed.
MACHINE="$(container machine list --format json 2>/dev/null | python3 -c "
import json,sys
try: items = json.load(sys.stdin)
except Exception: sys.exit(0)
running = [m for m in items if (m.get('status') or '').lower() == 'running']
print((running or items or [{}])[0].get('id',''))
" 2>/dev/null)"
if [ -n "$MACHINE" ]; then
  capture machine-inspect.json "inspect $MACHINE" machine inspect "$MACHINE"
else
  skipped+=("machine-inspect.json — no machine exists")
fi

# Needs a container with a published port, which this cannot conjure.
skipped+=("containers-ports.json — needs a container with -p; run one, then re-run")
# Needs a pull in flight; `pull-progress.txt` is stderr, not JSON.
skipped+=("pull-progress.txt — capture with: container image pull <ref> 2> pull-progress.txt")

echo
if ! $DRY; then
  {
    echo "# Fixture provenance"
    echo
    echo "Captured by \`Scripts/capture-fixtures.sh\` from a real CLI. Never hand-written."
    echo
    echo "- **CLI:** \`$VERSION\`"
    echo "- **Captured:** $(date -u +%Y-%m-%d)"
    echo "- **Account name anonymised to** \`example\`."
  } > "$OUT/CAPTURED.md"
  echo "▸ wrote $captured fixtures and CAPTURED.md"
else
  echo "▸ would write $captured fixtures"
fi

if [ ${#skipped[@]} -gt 0 ]; then
  echo
  echo "Not captured — each needs something this Mac does not have right now:"
  for s in "${skipped[@]}"; do echo "  · $s"; done
fi
