#!/usr/bin/env bash
#
# A test that needs a file on disk must create it, not inherit it from a sibling.
#
# The first CI run ever executed failed on exactly this: `buildImageRoutesThroughAllowlist…`
# referenced `/tmp/flotilla/Dockerfile`, which `hostBuildPath` requires to *exist*, and never
# created it. Six other tests do — so on a developer's Mac `/tmp/flotilla` survives between runs
# forever and the dependency is unobservable, while in a fresh container it is a test-ordering coin
# flip. Eleven more tests had the same shape, and the "refuses" ones among them were worse than
# flaky: they could pass because the path was missing rather than because the flag was banned. A
# test that passes for the wrong reason is this project's most expensive recurring bug.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib, re, sys
bad = []
for p in sorted(pathlib.Path('Tests/FlotillaCoreTests').glob('*.swift')):
    for part in re.split(r'\n(?=@Test)', p.read_text()):
        m = re.search(r'func\s+(\w+)\s*\(', part)
        if not m:
            continue
        needs = re.search(r'/tmp/(flotilla|allowed|build)\b', part)
        if needs and 'makeBuildFixtures()' not in part:
            bad.append(f"{p.name}: {m.group(1)}")
if bad:
    print("✗ tests reference on-disk build fixtures without creating them:")
    for b in bad:
        print("   ", b)
    print("  Add makeBuildFixtures() as the first statement — it is idempotent.")
    sys.exit(1)
print("  test isolation OK")
PY
