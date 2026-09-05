#!/usr/bin/env bash
#
# Build a signed, notarised, stapled installer package.
#
# `make-app.sh` is the dev loop and `release.sh` produces a zip. This produces the thing you can
# actually hand to another Mac: a .pkg that installs to /Applications, refuses to install on a
# macOS that cannot run it, and opens without a Gatekeeper argument.
#
# It needs BOTH Developer ID certificates, which are different things people routinely conflate:
#   Developer ID Application  signs the .app
#   Developer ID Installer    signs the .pkg
# A pkg signed with the Application certificate is not valid, and the error says almost nothing.
#
# Credentials are never handled here. Notarisation authenticates through a keychain profile you
# created once with `xcrun notarytool store-credentials`; this passes a profile *name*.
#
# Usage:
#   Scripts/make-pkg.sh --version 1.0.0-beta.1
#   Scripts/make-pkg.sh --version 1.0.0-beta.1 --skip-notarize   # signed only, no Apple round trip
#
# VERSIONING
#
#   1.0.0-alpha.N   early test builds; expect breakage
#   1.0.0-beta.N    feature complete, hunting bugs
#   1.0.0-rc.N      release candidate; ship this if nothing turns up
#   1.0.0           the release
#
# Two versions come out of one label, because they answer different questions:
#
#   the LABEL       1.0.0-beta.1 — the filename, the About panel, what a tester quotes back to you
#   the PKG VERSION the commit count — what Apple's installer compares NUMERICALLY
#
# The label cannot be the package version. `installer` orders packages numerically, and
# "1.0.0-beta.2" is not numerically anything — worse, every beta would compare equal, so the
# installer could not tell an older build from a newer one. The commit count always increases and
# keeps ordering correct across alpha → beta → rc → release.
#
# Environment:
#   FLOTILLA_SIGN_IDENTITY       Developer ID Application identity (auto-detected if unique)
#   FLOTILLA_INSTALLER_IDENTITY  Developer ID Installer identity (auto-detected if unique)
#   FLOTILLA_NOTARY_PROFILE      notarytool keychain profile name (default: flotilla)

# /usr/sbin is where spctl lives; /usr/bin has the rest. A PATH missing /usr/sbin gets all the way
# through a multi-minute notarisation before failing the final check on "command not found" — the
# same class of fault as the GUI-launch PATH bug in LocalHost.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION=""
SKIP_NOTARIZE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --version)        VERSION="${2:?--version needs a value}"; shift 2 ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
fail() { echo "✗ $1" >&2; exit 1; }

[ -n "$VERSION" ] || fail "pass --version (there is no release tag to infer one from)."
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*-alpha.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*-beta.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*-rc.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) fail "version '$VERSION' is not X.Y.Z or X.Y.Z-{alpha,beta,rc}.N — see the header." ;;
esac

# What the installer compares. Monotonic by construction; see the header for why the label cannot
# serve as this.
PKG_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
case "$VERSION" in
    *-*) CHANNEL="${VERSION#*-}"; CHANNEL="pre-release (${CHANNEL%%.*})" ;;
    *)   CHANNEL="release" ;;
esac

# ------------------------------------------------------------------ identities
find_identity() {
    local kind="$1" var="$2" matches count
    if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; return; fi
    matches="$(security find-identity -v 2>/dev/null | grep "Developer ID $kind" || true)"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    [ "$count" = "1" ] || {
        echo "✗ expected exactly one 'Developer ID $kind' identity, found $count." >&2
        echo "  Set $var to choose one." >&2
        exit 1
    }
    printf '%s' "$matches" | sed -n 's/.*"\(Developer ID [^"]*\)".*/\1/p'
}
APP_IDENTITY="$(find_identity Application FLOTILLA_SIGN_IDENTITY)"
PKG_IDENTITY="$(find_identity Installer FLOTILLA_INSTALLER_IDENTITY)"
PROFILE="${FLOTILLA_NOTARY_PROFILE:-flotilla}"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || fail "no notarytool credential stored under the profile '$PROFILE'. See RELEASING.md."
fi

echo "▸ Developer ID Application: ${APP_IDENTITY##*: }"
echo "▸ Developer ID Installer:   ${PKG_IDENTITY##*: }"
echo "▸ $VERSION — $CHANNEL, package version $PKG_VERSION"

# ------------------------------------------------------------------ app bundle
echo "▸ building and signing the app"
FLOTILLA_RELEASE_VERSION="$VERSION" FLOTILLA_SIGN_IDENTITY="$APP_IDENTITY" Scripts/make-app.sh >/dev/null

# make-app.sh silently falls back to 0.0.0 for anything it does not recognise as a version, so
# confirm the label actually landed rather than discovering it in the About panel on a test Mac.
STAMPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/build/Flotilla.app/Contents/Info.plist" 2>/dev/null || echo "?")"
[ "$STAMPED" = "$VERSION" ] || fail "the bundle is stamped '$STAMPED', not '$VERSION'." 
APP="$ROOT/build/Flotilla.app"
[ -d "$APP" ] || fail "make-app.sh did not produce $APP"

# The hardened runtime is a notarisation requirement. Captured to a variable rather than piped into
# `grep -q`, because grep exits at the first match and codesign then dies on SIGPIPE mid-write —
# which once made this check report a correctly hardened signature as broken.
SIGNATURE="$(codesign -d --verbose=4 "$APP" 2>&1 || true)"
case "$SIGNATURE" in
    *"flags=0x10000(runtime)"*|*"runtime"*) : ;;
    *) fail "the hardened runtime flag is not set on the app signature" ;;
esac
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/   /'

# ------------------------------------------------------------------ package
DIST="$ROOT/dist"
mkdir -p "$DIST"
COMPONENT="$DIST/Flotilla-component-$VERSION.pkg"
PKG="$DIST/Flotilla-$VERSION.pkg"
rm -f "$COMPONENT" "$PKG"

echo "▸ pkgbuild"
pkgbuild --quiet \
         --component "$APP" \
         --install-location /Applications \
         --identifier "dev.melonfleet.Flotilla.pkg" \
         --version "$PKG_VERSION" \
         "$COMPONENT"

# A distribution package rather than a bare component, for one reason that matters: it can refuse
# to install on a macOS that cannot run the app. Apple's container runtime needs macOS 26, so an
# installer that succeeds on macOS 15 and leaves a permanently broken app is worse than one that
# declines with a reason.
DISTXML="$DIST/distribution-$VERSION.xml"
cat > "$DISTXML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Flotilla $VERSION</title>
    <organization>dev.melonfleet</organization>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <allowed-os-versions><os-version min="26.0"/></allowed-os-versions>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" visible="false"><pkg-ref id="dev.melonfleet.Flotilla.pkg"/></choice>
    <pkg-ref id="dev.melonfleet.Flotilla.pkg" version="$PKG_VERSION">$(basename "$COMPONENT")</pkg-ref>
</installer-gui-script>
XML

echo "▸ productbuild + installer signature"
productbuild --quiet \
             --distribution "$DISTXML" \
             --package-path "$DIST" \
             --sign "$PKG_IDENTITY" \
             "$PKG"
rm -f "$COMPONENT" "$DISTXML"

echo "▸ verifying the installer signature"
pkgutil --check-signature "$PKG" | sed 's/^/   /'

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "▸ skipping notarisation (--skip-notarize)"
    echo "  NOT distributable: an un-notarised pkg is blocked on a Mac that has never seen it."
    echo "✓ $PKG"
    exit 0
fi

# ------------------------------------------------------------------ notarise
echo "▸ notarising (this talks to Apple and takes a few minutes)"
LOG="$DIST/notarize-pkg-$VERSION.log"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$LOG"

# `notarytool submit` exits 0 for "accepted for processing" as well as for Accepted, so read the
# status rather than trusting the exit code.
STATUS="$(sed -n 's/^ *status: *//p' "$LOG" | tail -1)"
[ "$STATUS" = "Accepted" ] || {
    SUBMISSION="$(sed -n 's/^ *id: *//p' "$LOG" | head -1)"
    echo "✗ notarisation status is '$STATUS', not Accepted." >&2
    echo "    xcrun notarytool log $SUBMISSION --keychain-profile $PROFILE" >&2
    exit 1
}

echo "▸ stapling"
xcrun stapler staple "$PKG" 2>&1 | sed 's/^/   /'
xcrun stapler validate "$PKG" 2>&1 | sed 's/^/   /'

# The real question is not "is the signature valid" but "would this be allowed to install".
# --type install is the pkg equivalent of --type execute for an app; asking the wrong one passes
# on a package Gatekeeper would still refuse.
echo "▸ Gatekeeper assessment"
spctl --assess --type install --verbose=4 "$PKG" 2>&1 | sed 's/^/   /'

echo "✓ $PKG"
echo "  $(du -h "$PKG" | awk '{print $1}') — $CHANNEL, signed, notarised, stapled, refuses macOS < 26"
