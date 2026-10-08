#!/usr/bin/env bash
#
# Publish a release that Scripts/release.sh has built: the GitHub release with its signed artefacts,
# and the Sparkle appcast entry that tells admin Macs about it (DECISIONS Q38, Q40).
#
# Kept apart from release.sh on purpose: building is local and repeatable, publishing is public and
# is not. Run it only when the owner has said this release goes out.
#
# WHAT IT NEEDS
#
#   dist/Flotilla-<version>.zip (and .tar.gz, .dmg, .pkg when present) from release.sh
#   Sparkle's EdDSA private key in this Mac's login Keychain (generate_keys put it there; the script
#     never sees it — sign_update asks the Keychain)
#   gh, signed in with permission to create releases and push to gh-pages
#
# Usage:
#   Scripts/publish-release.sh --version 1.5.0.0-beta.3 [--notes notes.md]
#
# A version with a pre-release suffix (-alpha, -beta, -rc) is published as a GitHub pre-release and
# on Sparkle's `beta` channel, which only admins who chose pre-releases see.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$(dirname "$0")/.."
ROOT="$PWD"
REPO="melonfleet/flotilla"
FEED_URL="https://melonfleet.github.io/flotilla/appcast.xml"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

fail() { echo "✗ $1" >&2; exit 1; }

VERSION=""
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --notes)   NOTES="$2"; shift 2 ;;
        *) fail "unknown argument $1" ;;
    esac
done
[ -n "$VERSION" ] || fail "--version is required"

DIST="$ROOT/dist"
ZIP="$DIST/Flotilla-$VERSION.zip"
[ -f "$ZIP" ] || fail "$ZIP not found — run Scripts/release.sh --version $VERSION first"
[ -x "$SPARKLE_BIN/sign_update" ] || fail "Sparkle's tools aren't here — run 'swift package resolve'"

# What Sparkle compares: the build number, read from the very app being published.
INFO="$(mktemp)"
unzip -p "$ZIP" "Flotilla.app/Contents/Info.plist" > "$INFO"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
rm -f "$INFO"

PRERELEASE=0
case "$VERSION" in *-*) PRERELEASE=1 ;; esac

echo "▸ signing the zip for Sparkle (the key stays in the Keychain)…"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
[[ "$SIGNATURE" == *edSignature* ]] || fail "sign_update gave no signature: $SIGNATURE"

ASSETS=("$ZIP")
for extra in "$DIST/Flotilla-$VERSION.tar.gz" "$DIST/Flotilla-$VERSION.dmg" "$DIST"/Flotilla-"$VERSION"*.pkg; do
    [ -f "$extra" ] && ASSETS+=("$extra")
done

echo "▸ creating the GitHub release v$VERSION…"
RELEASE_FLAGS=(--title "Flotilla $VERSION")
[ "$PRERELEASE" -eq 1 ] && RELEASE_FLAGS+=(--prerelease)
if [ -n "$NOTES" ]; then RELEASE_FLAGS+=(--notes-file "$NOTES"); else RELEASE_FLAGS+=(--generate-notes); fi
gh release create "v$VERSION" -R "$REPO" "${RELEASE_FLAGS[@]}" "${ASSETS[@]}"
URL="https://github.com/$REPO/releases/download/v$VERSION/Flotilla-$VERSION.zip"

echo "▸ adding it to the appcast on gh-pages…"
PAGES="$(mktemp -d)"
trap 'git -C "$ROOT" worktree remove --force "$PAGES" >/dev/null 2>&1 || true' EXIT
if git -C "$ROOT" ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git -C "$ROOT" fetch -q origin gh-pages
    git -C "$ROOT" worktree add -q "$PAGES" origin/gh-pages
    git -C "$PAGES" checkout -q -B gh-pages
else
    git -C "$ROOT" worktree add -q --detach "$PAGES"
    git -C "$PAGES" checkout -q --orphan gh-pages
    git -C "$PAGES" rm -rq . >/dev/null 2>&1 || true
fi

CHANNEL=""
[ "$PRERELEASE" -eq 1 ] && CHANNEL="beta"
python3 - "$PAGES/appcast.xml" "$VERSION" "$BUILD" "$SHORT" "$MINIMUM" "$URL" "$SIGNATURE" "$CHANNEL" <<'PY'
import sys, os, datetime, html
path, version, build, short, minimum, url, signature, channel = sys.argv[1:]
item = (
    "    <item>\n"
    f"      <title>Flotilla {html.escape(version)}</title>\n"
    f"      <pubDate>{datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>\n"
    f"      <sparkle:version>{html.escape(build)}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>\n"
    f"      <sparkle:minimumSystemVersion>{html.escape(minimum)}</sparkle:minimumSystemVersion>\n"
    + (f"      <sparkle:channel>{channel}</sparkle:channel>\n" if channel else "")
    + f"      <sparkle:releaseNotesLink>https://github.com/melonfleet/flotilla/releases/tag/v{html.escape(version)}</sparkle:releaseNotesLink>\n"
    f"      <enclosure url=\"{html.escape(url)}\" type=\"application/octet-stream\" {signature}/>\n"
    "    </item>\n"
)
if os.path.exists(path):
    text = open(path).read()
    if f"<sparkle:version>{build}</sparkle:version>" in text:
        sys.exit(f"build {build} is already in the appcast")
    marker = "<language>en</language>\n"
    if marker not in text:
        sys.exit("the appcast has no <language> line to insert after")
    text = text.replace(marker, marker + item, 1)
else:
    text = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>Flotilla</title>\n"
        "    <link>https://melonfleet.github.io/flotilla/appcast.xml</link>\n"
        "    <language>en</language>\n"
        + item +
        "  </channel>\n"
        "</rss>\n"
    )
open(path, "w").write(text)
PY
touch "$PAGES/.nojekyll"
git -C "$PAGES" add appcast.xml .nojekyll
git -C "$PAGES" commit -q -m "Appcast: Flotilla $VERSION (build $BUILD)"
git -C "$PAGES" push -q origin gh-pages

echo
echo "✓ Flotilla $VERSION published"
echo "   release:  https://github.com/$REPO/releases/tag/v$VERSION"
echo "   appcast:  $FEED_URL"
if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    echo
    echo "   GitHub Pages is not on for this repo yet, so the appcast isn't served. Once, with the"
    echo "   owner's OK:  gh api repos/$REPO/pages -X POST -f 'source[branch]=gh-pages' -f 'source[path]=/'"
fi
