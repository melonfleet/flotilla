#!/usr/bin/env bash
#
# Build, sign, notarise, staple and verify a distributable Flotilla.
#
# `make-app.sh` is the dev loop: ad-hoc signed, offline, instant. This is the other thing — the
# build you can hand to someone else's Mac and have it open without a Gatekeeper fight. It needs a
# Developer ID Application certificate and a stored notarytool credential, and it talks to Apple,
# so it is a deliberate separate step and not something the normal build drifts into.
#
# WHAT THIS SCRIPT WILL NOT DO
#
# It never handles your Apple credentials. Notarisation authenticates through a **keychain profile**
# you create once yourself with `xcrun notarytool store-credentials` — after that this script passes
# a profile *name*, and the secret stays in your keychain where no script can read it back. See
# RELEASING.md for the two setup steps that are yours alone.
#
# Usage:
#   Scripts/release.sh                     # version from the current git tag
#   Scripts/release.sh --version 0.3.1     # explicit
#   Scripts/release.sh --allow-dirty       # for testing the pipeline itself
#   Scripts/release.sh --skip-notarize     # sign + staple-less local check, no Apple round trip
#
# Environment:
#   FLOTILLA_SIGN_IDENTITY   signing identity; auto-detected when exactly one Developer ID exists
#   FLOTILLA_NOTARY_PROFILE  notarytool keychain profile name (default: flotilla)
set -euo pipefail

# The system tool directories, prepended rather than assumed.
#
# This script calls `codesign`, `xcrun`, `ditto` and `spctl`, and they do not all live in the same
# place — `spctl` is in **/usr/sbin** while the rest are in /usr/bin. A shell whose PATH is missing
# /usr/sbin therefore gets all the way through signing, archiving and a multi-minute notarisation
# upload before failing at the final Gatekeeper check on "command not found". That is the same class
# of fault as the GUI-launch PATH bug in `LocalHost`: an environment assumption that holds in a
# terminal and not everywhere.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION=""
ALLOW_DIRTY=0
SKIP_NOTARIZE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version)        VERSION="${2:?--version needs a value}"; shift 2 ;;
        --allow-dirty)    ALLOW_DIRTY=1; shift ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "✗ $1" >&2; exit 1; }

# ---------------------------------------------------------------- preconditions
#
# All of them checked before anything is built. A release that fails after the notarisation upload
# has cost minutes and left a half-made artefact; failing in the first second costs nothing.

# 1. A clean tree. What you ship must be what is committed, or the version stamped in the bundle
#    describes something that exists only on this Mac.
if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    fail "working tree is dirty. Commit first, or pass --allow-dirty to test the pipeline."
fi

# 2. A real version. `make-app.sh` falls back to 0.0.0 when there is no tag, which is correct for a
#    dev build and wrong for something you hand to a tester — two people comparing "0.0.0" have no
#    way to tell which build each has.
if [ -z "$VERSION" ]; then
    if git describe --tags --abbrev=0 >/dev/null 2>&1; then
        VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
    else
        fail "no git tag to take a version from. Tag the release (git tag -a v0.1.0 -m 'v0.1.0') or pass --version."
    fi
fi
case "$VERSION" in
    *[!0-9.]*|"") fail "version '$VERSION' is not 1-3 dot-separated numbers, which is what CFBundleShortVersionString requires." ;;
esac

# 3. A signing identity. Auto-detected only when the choice is unambiguous — picking one of several
#    on the user's behalf is how you ship something signed by the wrong team.
if [ -z "${FLOTILLA_SIGN_IDENTITY:-}" ]; then
    MATCHES="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
    COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
    if [ "$COUNT" -eq 0 ]; then
        echo "✗ no 'Developer ID Application' certificate in your keychains." >&2
        echo "  This is the one thing that cannot be scripted for you — see RELEASING.md step 1." >&2
        echo "  Quickest path: Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸ + ▸ Developer ID Application" >&2
        exit 1
    elif [ "$COUNT" -gt 1 ]; then
        echo "✗ more than one Developer ID Application certificate; name the one you want:" >&2
        printf '%s\n' "$MATCHES" | sed 's/^/    /' >&2
        echo "  FLOTILLA_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' Scripts/release.sh" >&2
        exit 1
    fi
    FLOTILLA_SIGN_IDENTITY="$(printf '%s' "$MATCHES" | sed -n 's/.*"\(.*\)".*/\1/p')"
fi
export FLOTILLA_SIGN_IDENTITY

# 4. A notarisation credential, checked *before* the build rather than after.
PROFILE="${FLOTILLA_NOTARY_PROFILE:-flotilla}"
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "✗ no notarytool credential stored under the profile '$PROFILE'." >&2
        echo "  Create it yourself — it takes your App Store Connect key and this script never sees it:" >&2
        echo "    xcrun notarytool store-credentials $PROFILE --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>" >&2
        echo "  See RELEASING.md step 2. Or pass --skip-notarize to build a signed-but-unnotarised bundle." >&2
        exit 1
    fi
fi

echo "▸ releasing Flotilla $VERSION"
echo "   identity: $FLOTILLA_SIGN_IDENTITY"

# ---------------------------------------------------------------- build & sign
#
# Through `make-app.sh`, not a second copy of the packaging. It already runs the two invariant
# checks, generates icons, compiles the asset catalogue and stamps the plist; a release path that
# reimplemented any of that would be a second thing to keep correct. `FLOTILLA_SIGN_IDENTITY` is
# what makes it sign for real, with the hardened runtime and a timestamp.
FLOTILLA_RELEASE_VERSION="$VERSION" bash Scripts/make-app.sh --release
APP="$ROOT/build/Flotilla.app"
[ -d "$APP" ] || fail "no bundle at $APP"

STAMPED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[ "$STAMPED" = "$VERSION" ] || fail "bundle says version $STAMPED, expected $VERSION"

# The hardened runtime is a notarisation requirement, so check it is actually on rather than
# assuming the environment variable did its job.
#
# Captured into a variable rather than piped into `grep -q`. The pipeline version failed on a
# **correctly signed** app: `grep -q` exits at the first match, `codesign` at verbose=4 then writes
# into a closed pipe and dies of SIGPIPE, and `set -o pipefail` reports the pipeline as failed. The
# check said "the hardened runtime flag is not set" about a signature carrying
# `flags=0x10000(runtime)`. `grep -q` and `pipefail` do not mix.
SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
case "$SIGNATURE" in
    *"flags="*"(runtime)"*) ;;
    *) fail "the hardened runtime flag is not set on the signature" ;;
esac

DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/Flotilla-$VERSION.zip"

# `ditto`, not `zip`: it preserves the resource forks and symlinks a bundle's signature is computed
# over. A plain `zip` can produce an archive whose extracted app fails verification.
echo "▸ archiving…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "▸ skipping notarisation (--skip-notarize)"
    echo "   $ZIP"
    echo "   This will still be quarantined on another Mac. Signed, not notarised."
    exit 0
fi

# ---------------------------------------------------------------- notarise
#
# `--wait` blocks until Apple answers, which is usually a couple of minutes. Worth waiting for: the
# alternative is stapling later from memory, and an unstapled app is one that needs the network to
# pass Gatekeeper on first launch.
echo "▸ submitting for notarisation (this takes a few minutes)…"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$DIST/notarize-$VERSION.log"; then
    fail "notarisation submission failed — see $DIST/notarize-$VERSION.log"
fi
# `notarytool submit` exits 0 for a submission that was *accepted for processing* as well as one
# that passed, so the status line is what decides.
grep -q "status: Accepted" "$DIST/notarize-$VERSION.log" || {
    echo "✗ Apple did not accept this build. To read why:" >&2
    SUBMISSION="$(sed -n 's/ *id: //p' "$DIST/notarize-$VERSION.log" | head -1)"
    echo "    xcrun notarytool log $SUBMISSION --keychain-profile $PROFILE" >&2
    exit 1
}

# ---------------------------------------------------------------- staple & verify
#
# Stapling attaches the ticket to the **app**, so it opens on a Mac that is offline or behind a
# captive portal. The zip that was submitted does not carry it, which is why the archive is rebuilt
# afterwards from the stapled bundle.
echo "▸ stapling…"
xcrun stapler staple "$APP" 2>&1 | sed 's/^/   /'
xcrun stapler validate "$APP" 2>&1 | sed 's/^/   /'

echo "▸ verifying as Gatekeeper will…"
# The real question is not "is the signature valid" but "would this be allowed to run". `spctl`
# answers the second one, and it is the only check here that reflects what a tester experiences.
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/   /'
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'

echo "▸ archiving the stapled build…"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "✓ Flotilla $VERSION — signed, notarised, stapled"
echo "   $ZIP"
echo
echo "   Hand that zip to a tester. On their Mac it should open from Finder with no"
echo "   right-click-Open dance and no 'unidentified developer' dialog. If it does not,"
echo "   the fault is real and not their settings — spctl above is the same check they get."
