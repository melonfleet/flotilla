#!/usr/bin/env bash
#
# Every setting the app offers must be read by something.
#
# The 2026-08-20 independent audit's largest finding was not a bug but a category: settings that
# persisted, survived a relaunch and changed nothing, because the feature behind them did not exist.
# `launchAtLogin` was the clearest — its summary named `SMAppService` and no file called it.
#
# This is a script rather than a `swift test` because the consumers live in the **Flotilla** target
# and the only test target depends on **FlotillaCore**. A test cannot see the app layer, which is
# the same reason the UI refactors are deferred; that is not a reason to leave the invariant
# unchecked, so it is checked here.
#
# The rule: a key marked `.available` must be mentioned somewhere outside the registry that declares
# it and the Settings screen that displays it. A key marked `.notBuilt` must NOT be — if something
# reads it, the marking is a lie in the other direction and the row is needlessly disabled.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="Sources/FlotillaCore/Settings/SettingsRegistry.swift"
failures=0

# Names of keys, in declaration order, with the availability that follows each.
keys=$(/usr/bin/grep -oE 'public static let [a-zA-Z]+ = SettingsKey<' "$REGISTRY" \
       | /usr/bin/sed -E 's/public static let ([a-zA-Z]+) = SettingsKey</\1/')

for key in $keys; do
    # `notification(_:)` is generated per category rather than declared, and is consumed through
    # `isEnabled(_:)`; it has no `SettingsKeys.<name>` spelling to search for.
    [ "$key" = "notification" ] && continue

    # Availability is read from the declaration block: the 6 lines following the name.
    block=$(/usr/bin/grep -A6 "public static let $key = SettingsKey<" "$REGISTRY" || true)
    if printf '%s' "$block" | /usr/bin/grep -q 'notBuilt'; then
        expected="unbuilt"
    else
        expected="available"
    fi

    # Consumers: any mention of SettingsKeys.<key> outside the registry and the settings screen.
    # `SettingsStore` accessors count — `chosenAppearance` is a real consumer of `appearance`.
    hits=$(/usr/bin/grep -rl "SettingsKeys\.$key\b" Sources/ 2>/dev/null \
           | /usr/bin/grep -v "$REGISTRY" \
           | /usr/bin/grep -v "Sources/Flotilla/SettingsView.swift" || true)

    if [ "$expected" = "available" ] && [ -z "$hits" ]; then
        echo "  MISSING CONSUMER  $key is offered as a working setting and nothing reads it."
        echo "                    Either wire it, or mark it .notBuilt(reason:) in the registry."
        failures=$((failures + 1))
    fi
    # A **mirror** is not a consumer: reporting a preference back to whoever set it (a support
    # bundle listing what the settings say) changes no behaviour. Listed per key and per file so the
    # exception stays reviewable and cannot quietly grow into "nothing counts".
    #
    #   mode — the diagnostics snapshot records the declared run mode. Selecting `host` still opens
    #          no listener, which is why the key is marked unbuilt despite this read.
    if [ "$expected" = "unbuilt" ] && [ "$key" = "mode" ]; then
        hits=$(printf '%s\n' $hits | /usr/bin/grep -v "Sources/Flotilla/AppModel.swift" || true)
    fi

    if [ "$expected" = "unbuilt" ] && [ -n "$hits" ]; then
        echo "  STALE MARKING     $key is marked .notBuilt but is read by:"
        printf '                    %s\n' $hits
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "settings-consumers FAILED ($failures)"
    exit 1
fi
echo "  settings consumers OK"
