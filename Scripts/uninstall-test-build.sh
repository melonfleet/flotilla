#!/usr/bin/env bash
#
# Remove a Flotilla test build and everything it left behind on the machine.
#
# For a test Mac after a beta pass: puts the machine back the way it was, so the next install is
# genuinely a fresh install and not a re-install carrying yesterday's preferences.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH
#
# Your containers, images, volumes, machines and the `container` CLI itself. Those belong to
# Apple's runtime, not to Flotilla — removing the app must not remove your work, and a cleanup
# script that quietly did would be the worst possible bug to ship in a cleanup script.
#
# Test containers can be removed, but only ones you NAME:
#     Scripts/uninstall-test-build.sh --containers web,cache --machines testvm
#
# There is no wildcard and no "delete everything" flag. This script cannot tell a container you
# made during testing from one you had before, so it does not guess.
#
# Usage:
#   Scripts/uninstall-test-build.sh --dry-run          # show what would go, change nothing
#   Scripts/uninstall-test-build.sh                    # remove, asking first
#   Scripts/uninstall-test-build.sh --yes              # remove without asking
#   Scripts/uninstall-test-build.sh --list             # what is on this machine right now
#   Scripts/uninstall-test-build.sh --containers a,b   # also remove these, by name
#
# Run it on the TEST machine. It needs sudo only to forget the installer receipt, and says so
# before asking.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -uo pipefail

BUNDLE_ID="dev.melonfleet.Flotilla"
PKG_ID="dev.melonfleet.Flotilla.pkg"
# Overridable so this script can be exercised end to end against fakes rather than shipped
# untested. A destructive script nobody has watched delete something is a destructive script
# nobody has tested — and the one place that matters most is the one you only run once.
APP="${FLOTILLA_APP:-/Applications/Flotilla.app}"

DRY=0; YES=0; LIST=0; RM_CONTAINERS=""; RM_MACHINES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY=1; shift ;;
        --yes|-y)     YES=1; shift ;;
        --list)       LIST=1; shift ;;
        --containers) RM_CONTAINERS="${2:?--containers needs a comma-separated list}"; shift 2 ;;
        --machines)   RM_MACHINES="${2:?--machines needs a comma-separated list}"; shift 2 ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Everything Flotilla can leave in the user's library. Most are created by macOS on behalf of any
# app rather than by Flotilla itself, which is exactly why they are easy to forget.
PATHS=(
    "$APP"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/Application Scripts/$BUNDLE_ID"
    "$HOME/Library/Containers/$BUNDLE_ID"
    "$HOME/Library/Group Containers/$BUNDLE_ID"
)

found=(); missing=0
for p in "${PATHS[@]}"; do
    if [ -e "$p" ]; then found+=("$p"); else missing=$((missing+1)); fi
done

# Support bundles the tester saved. Named, so they can be found — but they are the tester's own
# files and may carry their notes, so they are reported and only removed on confirmation.
bundles=()
while IFS= read -r b; do [ -n "$b" ] && bundles+=("$b"); done < <(
    find "$HOME/Desktop" "$HOME/Downloads" "$HOME/Documents" -maxdepth 2 \
         -name "Flotilla-Support-*" -print 2>/dev/null
)
pkgs=()
while IFS= read -r f; do [ -n "$f" ] && pkgs+=("$f"); done < <(
    find "$HOME/Downloads" -maxdepth 1 -name "Flotilla-*.pkg" -print 2>/dev/null
)

receipt=""
pkgutil --pkgs 2>/dev/null | grep -qx "$PKG_ID" && receipt="$PKG_ID"

echo "▸ Flotilla test-build cleanup"
if [ -e "$APP" ]; then
    V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
    echo "  installed: $V"
else
    echo "  installed: no app at $APP"
fi
echo

report() {
    local title="$1"; shift
    if [ "$#" -eq 0 ]; then echo "  $title: none"; else
        echo "  $title:"
        for x in "$@"; do echo "      $x"; done
    fi
}
report "app and support files" "${found[@]+"${found[@]}"}"
report "saved support bundles"  "${bundles[@]+"${bundles[@]}"}"
report "downloaded packages"    "${pkgs[@]+"${pkgs[@]}"}"
echo "  installer receipt: ${receipt:-none}"

# What is deliberately out of scope, stated rather than assumed.
if command -v container >/dev/null 2>&1; then
    C="$(container ls -a 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    M="$(container machine ls 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    echo
    echo "  left alone: $C container(s), $M machine(s), all images and volumes, and the CLI."
    echo "              Name them with --containers / --machines to remove specific ones."
fi

if [ "$LIST" -eq 1 ]; then exit 0; fi

if [ "${#found[@]}" -eq 0 ] && [ -z "$receipt" ] && [ "${#bundles[@]}" -eq 0 ] && [ "${#pkgs[@]}" -eq 0 ]; then
    echo
    echo "✓ nothing to remove — this machine is already clean."
    exit 0
fi

if [ "$DRY" -eq 1 ]; then
    echo
    echo "▸ --dry-run: nothing was changed."
    exit 0
fi

# --------------------------------------------------------------- confirm
if [ "$YES" -eq 0 ]; then
    echo
    printf "Remove all of the above? [y/N] "
    read -r reply </dev/tty || reply=""
    case "$reply" in [yY]|[yY][eE][sS]) : ;; *) echo "  cancelled."; exit 0 ;; esac
fi

# --------------------------------------------------------------- login item
# Unregistering needs the app to still be here: SMAppService registration is keyed to the bundle,
# and once the bundle is gone there is nothing left to ask. So this happens FIRST, and the app is
# only removed afterwards.
if [ -e "$APP" ]; then
    echo
    echo "▸ login item"
    echo "  If you enabled 'Launch at login', turn it off in Flotilla ▸ Settings before continuing,"
    echo "  or clear it afterwards in System Settings ▸ General ▸ Login Items. macOS keys the"
    echo "  registration to the bundle, so deleting the app first can leave a stale entry that no"
    echo "  script can remove without resetting every background item on the machine."
    pkill -x Flotilla 2>/dev/null && echo "  quit the running app"
    sleep 1
fi

# --------------------------------------------------------------- remove
echo
echo "▸ removing"
for p in "${found[@]+"${found[@]}"}"; do
    if rm -rf "$p" 2>/dev/null; then echo "  removed  $p"; else echo "  FAILED   $p"; fi
done
for p in "${bundles[@]+"${bundles[@]}"}" "${pkgs[@]+"${pkgs[@]}"}"; do
    if rm -rf "$p" 2>/dev/null; then echo "  removed  $p"; else echo "  FAILED   $p"; fi
done

# The preference cache holds values even after the plist is gone, so a re-install can read back
# yesterday's settings and the "fresh install" is not fresh.
#
# Skipped in test mode, and that guard is not theoretical: `defaults` and `cfprefsd` talk to the
# per-user preference daemon and **ignore $HOME**, so exercising this script against a fake home
# reaches through and deletes the real domain. It did exactly that once.
if [ -n "${FLOTILLA_APP:-}" ]; then
    echo "  skipped  preferences cache — FLOTILLA_APP is set, so this is a test run"
else
    defaults delete "$BUNDLE_ID" 2>/dev/null && echo "  cleared  preferences cache ($BUNDLE_ID)"
    killall -u "$USER" cfprefsd 2>/dev/null && echo "  restarted cfprefsd"
fi

if [ -n "$receipt" ]; then
    echo
    echo "▸ installer receipt (needs sudo)"
    if sudo -n true 2>/dev/null || [ "$YES" -eq 0 ]; then
        sudo pkgutil --forget "$PKG_ID" 2>&1 | sed 's/^/  /'
    else
        echo "  skipped — run: sudo pkgutil --forget $PKG_ID"
    fi
fi

# --------------------------------------------------------------- named containers only
remove_named() {
    local kind="$1" list="$2" sub="$3"
    [ -n "$list" ] || return 0
    command -v container >/dev/null 2>&1 || { echo "  container CLI not present; skipping $kind"; return 0; }
    echo
    echo "▸ $kind named on the command line"
    local IFS=','
    for name in $list; do
        [ -n "$name" ] || continue
        # shellcheck disable=SC2086
        if container $sub delete "$name" >/dev/null 2>&1; then
            echo "  deleted  $name"
        else
            echo "  not deleted (may not exist, or is running)  $name"
        fi
    done
}
remove_named "containers" "$RM_CONTAINERS" ""
remove_named "machines"   "$RM_MACHINES"   "machine"

# --------------------------------------------------------------- verify
echo
echo "▸ verifying"
left=0
for p in "${PATHS[@]}"; do [ -e "$p" ] && { echo "  still present: $p"; left=1; }; done
pkgutil --pkgs 2>/dev/null | grep -qx "$PKG_ID" && { echo "  receipt still registered: $PKG_ID"; left=1; }
if [ -z "${FLOTILLA_APP:-}" ] && [ -n "$(defaults read "$BUNDLE_ID" 2>/dev/null)" ]; then
    echo "  preferences still readable"; left=1
fi

if [ "$left" -eq 0 ]; then
    echo "  nothing left"
    echo
    echo "✓ clean. Check System Settings ▸ General ▸ Login Items has no Flotilla entry, and the"
    echo "  next install will be a genuine first run."
else
    echo
    echo "✗ some items remain — listed above. Re-run, or remove them by hand."
    exit 1
fi
