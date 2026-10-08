#!/usr/bin/env bash
# Assemble Flotilla.app around the SwiftPM binary.
#
# WHY THIS EXISTS
#
# Run as a bare SwiftPM executable, Flotilla has no Info.plist and therefore no bundle
# identifier — and four Phase 1 features are gated on exactly that, not on any missing code:
#
#   * notifications — `UNUserNotificationCenter.current()` does not degrade without a
#     bundle, it raises `bundleProxyForCurrentProcess is nil` and kills the process
#     (verified 2026-07-30);
#   * "Show Flotilla in: Menu bar / Dock / Both" — needs `LSUIElement`;
#   * launch at login — `SMAppService` registers a bundle, not a loose binary;
#   * hardened runtime, Developer ID signing and notarization.
#
# This is deliberately NOT the Xcode-project migration `CLAUDE.md` describes. It is the
# cheap, reversible half: a real bundle so those features can be built and used now, while
# the build stays SwiftPM and keeps working unchanged on Linux for FlotillaCore. Xcode still
# owns the distribution story (notarization, Sparkle, Jamf) when we get there.
#
# USAGE
#   Scripts/make-app.sh [--release] [--menubar]
#
#   --release  build with -c release (default: debug, for the faster loop)
#   --menubar  ship LSUIElement=true so the app starts as a menu-bar accessory
#
# `LSUIElement` is NOT just a cosmetic starting policy, which is what the old comment here
# claimed and what made a real bug hard to see. Measured on macOS 26: when the app starts as
# an accessory, SwiftUI never instantiates the `Window` scene at all, and switching to
# `.regular` afterwards does not build one — the app takes the Dock tile and the menu bar and
# has no window to show. So this must default to FALSE, matching the shipped `both`
# preference, and menu-bar-only users are dropped to `.accessory` by `AppDelegate` before any
# scene materialises. See `applyPresentation`.

set -euo pipefail

CONFIG="debug"
LSUIELEMENT="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --release) CONFIG="release" ;;
    --menubar) LSUIELEMENT="true" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="dev.melonfleet.Flotilla"      # DECISIONS.md Q8 — fixed, do not vary by config
APP="$ROOT/build/Flotilla.app"

# Before anything is built or copied. A packaged app carrying a screenshot scaffold has
# twice been handed to the owner as a working build and read as a product bug — see
# Scripts/check-defaults.sh for what it checks and why a comment was not enough.
echo "▸ checking view defaults…"
"$ROOT/Scripts/check-defaults.sh"
# Same reason, one level up: a setting whose consumer was deleted, or which was never wired at all,
# must not reach a build. Cheap (a few greps) and it runs before assembly, so a failure stops the
# bundle rather than shipping a Settings screen full of controls that do nothing.
"$ROOT/Scripts/check-settings-consumers.sh"
# Identity, credentials and key files. Cheap, and the release path is exactly when someone has a
# freshly downloaded .p8 sitting in the repo root.
"$ROOT/Scripts/check-hygiene.sh"
"$ROOT/Scripts/check-test-isolation.sh"
# A row whose `⋯` button and right-click offer different things. Broken twice already,
# and invisible unless you open both menus on the same row and compare them by eye.
"$ROOT/Scripts/check-menu-parity.sh"

echo "▸ building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product Flotilla
  swift build -c release --product FlotillaDNSHelper
else
  swift build --product Flotilla
  swift build --product FlotillaDNSHelper
fi
BINARY="$(swift build -c "$CONFIG" --product Flotilla --show-bin-path)/Flotilla"
[ -x "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }
HELPER_BINARY="$(swift build -c "$CONFIG" --product FlotillaDNSHelper --show-bin-path)/FlotillaDNSHelper"
[ -x "$HELPER_BINARY" ] || { echo "no binary at $HELPER_BINARY" >&2; exit 1; }
HELPER_ID="dev.melonfleet.Flotilla.dns-helper"

# Versions, and the two plist keys have different rules — which the first version of this got
# wrong in a way only a build with **no tags** exposed.
#
# `git describe --tags --always` falls back to a bare commit hash when no tag exists, and this repo
# has no tags. So the bundle was stamped `CFBundleShortVersionString = 5135510` and
# `CFBundleVersion = 5135510-dirty`. Apple's rule for `CFBundleVersion` is one to three
# period-separated integers; a hash is not a version at all. It reads as harmless right up until
# something in LaunchServices compares two of them — and Flotilla now registers a login item
# through `SMAppService`, which is LaunchServices' opinion of this bundle.
#
# So: a dotted version for the marketing string, a monotonic **integer** for the build number, and
# the git description kept in its own key where a support bundle can still name the exact commit.
DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo "unknown")"

# An explicit version wins over anything derived. `Scripts/release.sh` sets this: a release is
# named deliberately, and a release build that quietly took its version from whatever tag happened
# to be reachable would let two different builds claim the same number.
if [ -n "${FLOTILLA_RELEASE_VERSION:-}" ]; then
    SHORT_VERSION="$FLOTILLA_RELEASE_VERSION"
# The tag, when there is one (`v1.2.3` → `1.2.3`); `0.0.0` when there is not. Never a hash.
elif git describe --tags --abbrev=0 >/dev/null 2>&1; then
    SHORT_VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')"
else
    SHORT_VERSION="0.0.0"
fi
# `CFBundleShortVersionString` is a *display* string, so a pre-release label belongs in it —
# 1.0.0-beta.1 is what a tester should see in About and in the installer. What must stay numeric is
# `CFBundleVersion`, which LaunchServices compares, and that is the commit count below.
#
# The guard still rejects a bare commit hash, which is the case it was written for: with no tags,
# `git describe --always` returns one and it is not a version. It just no longer rejects the
# pre-release labels along with it.
# Matched positively against the shapes that ARE versions, rather than negatively against
# characters that are not. The old negative test accepted `5135510` — an all-digit commit hash is
# still a hash, and stamping one as the version is the exact bug that already shipped once.
# Four components as well as three: Flotilla's version is `<container version>.<revision>`
# (DECISIONS.md, 2026-09-12), so `1.4.1.2` is a real version and must not be rejected into
# `0.0.0`. `CFBundleShortVersionString` is a display string and takes it; `CFBundleVersion`,
# which LaunchServices actually compares, is the commit count below and is unaffected.
case "$SHORT_VERSION" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*-alpha.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*.[0-9]*-beta.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*.[0-9]*-rc.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*-alpha.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*-beta.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*-rc.[0-9]*|\
    [0-9]*.[0-9]*.[0-9]*) : ;;               # X.Y.Z[.R], optionally pre-release
    *) SHORT_VERSION="0.0.0" ;;
esac

# Commit count: monotonic, integer, and meaningful without tags.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER=0

# Icons are generated from the brand geometry, not rasterised from the SVG — see
# Scripts/make-icons.swift for why (the wordmark SVGs fetch a webfont, which an app promising
# no phone-home must not ship).
echo "▸ generating icons…"
swift "$ROOT/Scripts/make-icons.swift" | sed 's/^/   /'
iconutil -c icns "$ROOT/build/icons/Flotilla.iconset" -o "$ROOT/build/icons/Flotilla.icns"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Flotilla"
# The DNS helper (decision 19, amended 7 October) and the launchd plist SMAppService reads. Shipped
# in every build; it only runs once the owner approves it in Login Items, and only in a Developer
# ID build — an ad-hoc helper has no team to require of its callers and refuses to start.
cp "$HELPER_BINARY" "$APP/Contents/MacOS/FlotillaDNSHelper"

# Sparkle (DECISIONS Q40): a dynamic framework, so it is embedded and the executable is told where
# to find it. SwiftPM leaves it beside the binary; the bundle keeps it in Contents/Frameworks.
SPARKLE_FRAMEWORK="$(dirname "$BINARY")/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "✗ Sparkle.framework not found beside $BINARY" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Flotilla" 2>/dev/null || true
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$ROOT/Resources/$HELPER_ID.plist" "$APP/Contents/Library/LaunchDaemons/"

cp "$ROOT/build/icons/Flotilla.icns" "$APP/Contents/Resources/Flotilla.icns"
# The menu-bar template, at both scales. Loaded by URL at runtime and marked isTemplate
# explicitly — the "…Template" filename convention only applies to NSImage(named:).
cp "$ROOT/Resources/MenuBarIconTemplate.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuBarIconTemplate@2x.png" "$APP/Contents/Resources/"

# No asset catalog, and no `NSAccentColorName`, on purpose (26 September, `design/THEMES.md`).
#
# There used to be one here, holding a single `AccentColor`: macOS takes the accent AppKit uses for
# sidebar selection, table selection and focus rings from that asset, so it forced watermelon onto
# them. Themes put those controls back on the **system accent** — the colour the user chose in
# System Settings, as Finder and System Settings use — and an app that declares its own accent can
# never follow the user's. Do not add it back to "fix" a blue selection: blue is the default system
# accent, and that is the design.

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Flotilla</string>
    <key>CFBundleDisplayName</key>          <string>Flotilla</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>Flotilla</string>
    <key>CFBundleIconFile</key>             <string>Flotilla</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <!-- Not an Apple key. The exact commit, dirty flag included, so a support bundle can name the
         build it came from without CFBundleVersion having to carry something it may not. -->
    <key>FLGitDescribe</key>                <string>$DESCRIBE</string>
    <key>LSMinimumSystemVersion</key>       <string>26.0</string>
    <!-- False by default, matching the shipped "both" preference. This decides whether a
         main window is ever created, not merely how the app looks at launch — AppDelegate
         narrows to .accessory for menu-bar-only users before any scene exists. -->
    <key>LSUIElement</key>                  <$LSUIELEMENT/>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Sparkle (Q40): the appcast on GitHub Pages, and the public half of the EdDSA key every
         update is signed with. The private half is in the owner's Keychain, never here. -->
    <key>SUFeedURL</key>                    <string>https://melonfleet.github.io/flotilla/appcast.xml</string>
    <key>SUPublicEDKey</key>                <string>pV97YwpduTDPjELSVIM8vE9rOHtx82OAngnMyR34psk=</string>
    <!-- .flotilla configuration files (Q29): Flotilla owns the type, so a double-click opens
         its import review. JSON inside, so it conforms to public.json. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
      <dict>
        <key>UTTypeIdentifier</key>         <string>dev.melonfleet.flotilla-configuration</string>
        <key>UTTypeDescription</key>        <string>Flotilla Configuration</string>
        <key>UTTypeConformsTo</key>         <array><string>public.json</string></array>
        <key>UTTypeTagSpecification</key>
        <dict>
          <key>public.filename-extension</key> <array><string>flotilla</string></array>
        </dict>
      </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key>         <string>Flotilla Configuration</string>
        <key>CFBundleTypeRole</key>         <string>Viewer</string>
        <key>LSHandlerRank</key>            <string>Owner</string>
        <key>LSItemContentTypes</key>       <array><string>dev.melonfleet.flotilla-configuration</string></array>
      </dict>
    </array>
    <!-- Names the colorset in Assets.car, when one was compiled. AppKit reads this for
         sidebar selection and focus rings; SwiftUI's .tint() does not reach them. -->
    <!-- No telemetry, no account, no phone-home (FEATURES.md). Nothing here requests a
         network entitlement or a usage string beyond what Phase 2 mTLS will need. -->
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing. Two modes, and the difference is one environment variable.
#
# Default is **ad-hoc**, which is right for the dev loop: no network, no credentials, no waiting.
# An unsigned bundle gets an unstable identity, and notification authorization is remembered per
# identity, so even ad-hoc is worth doing — without it the permission prompt reappears on every
# rebuild.
#
# `FLOTILLA_SIGN_IDENTITY` switches to real signing: a Developer ID Application certificate, the
# **hardened runtime** and a **secure timestamp**. Both of those are notarisation requirements
# rather than preferences — `notarytool` rejects a bundle without them — so they are attached here
# at signing time and not bolted on by the release script. `Scripts/release.sh` sets the variable;
# nothing else needs to.
# Sparkle's parts, inside-out, as Sparkle's own documentation lays out for a non-sandboxed app: its
# two XPC services (the Downloader keeping its entitlements), Autoupdate, Updater.app, then the
# framework. Signed with our identity, so a host checking an update (Q38) finds every nested binary
# ours.
sign_sparkle() {
    local identity="$1" stamp="$2" framework="$APP/Contents/Frameworks/Sparkle.framework"
    for item in "$framework/Versions/B/XPCServices/Installer.xpc" \
                "$framework/Versions/B/XPCServices/Downloader.xpc" \
                "$framework/Versions/B/Autoupdate" \
                "$framework/Versions/B/Updater.app" \
                "$framework"; do
        [ -e "$item" ] || continue
        local keep=()
        [[ "$item" == *Downloader.xpc ]] && keep=(--preserve-metadata=entitlements)
        codesign --force --options runtime "$stamp" ${keep[@]+"${keep[@]}"} --sign "$identity" "$item" 2>&1 | sed 's/^/   /'
    done
}

if [ -n "${FLOTILLA_SIGN_IDENTITY:-}" ]; then
    echo "▸ signing (Developer ID, hardened runtime)…"
    # No `--deep`: Apple's guidance is to sign inside-out. The one nested binary is the DNS helper,
    # signed first under its own identifier — the app requires exactly that identifier of it, and
    # `--deep` would have stamped the app's onto it. SwiftTerm is statically linked (`otool -L`).
    codesign --force --options runtime --timestamp \
             --sign "$FLOTILLA_SIGN_IDENTITY" --identifier "$HELPER_ID" \
             "$APP/Contents/MacOS/FlotillaDNSHelper" 2>&1 | sed 's/^/   /'
    sign_sparkle "$FLOTILLA_SIGN_IDENTITY" --timestamp
    codesign --force --options runtime --timestamp \
             --sign "$FLOTILLA_SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/   /'
    SIGN_MODE="Developer ID"
else
    echo "▸ signing (ad-hoc)…"
    codesign --force --sign - --identifier "$HELPER_ID" --timestamp=none \
             "$APP/Contents/MacOS/FlotillaDNSHelper" 2>&1 | sed 's/^/   /'
    sign_sparkle - --timestamp=none
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/   /'
    SIGN_MODE="ad-hoc"
fi

echo "▸ verifying…"
# `--strict` and `--deep` on *verification* (unlike signing): they check what is actually in the
# bundle rather than what we believe is in it.
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | sed 's/^/   bundle id: /'
echo "   version:   $SHORT_VERSION ($BUILD_NUMBER) — $DESCRIBE"

if [ "$SIGN_MODE" = "Developer ID" ]; then
    TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    echo "   signing:   Developer ID, hardened runtime, timestamped — team ${TEAM:-unknown}"
    echo "              not notarised yet; Gatekeeper on another Mac needs Scripts/release.sh"
else
    # Said out loud rather than left to be discovered. `--sign -` produces a signature with no Team
    # ID: enough to launch locally, not enough for notarisation or for a Gatekeeper-clean install on
    # another Mac. It is also why `SMAppService` registration can be refused on a fresh build — a
    # login item is keyed to the bundle's signing identity, and an ad-hoc identity changes when the
    # binary does.
    echo "   signing:   ad-hoc (no Team ID) — fine locally, not distributable, and login-item"
    echo "              registration may be refused after a rebuild"
fi
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist" | sed 's/^/   LSUIElement: /'

echo "✓ $APP"
echo "  open it with:  open \"$APP\""
