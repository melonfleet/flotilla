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

echo "▸ building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product Flotilla
else
  swift build --product Flotilla
fi
BINARY="$(swift build -c "$CONFIG" --product Flotilla --show-bin-path)/Flotilla"
[ -x "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

# Versions, and the two plist keys have different rules — which the first version of this got
# wrong in a way only a build with **no tags** exposed.
#
# `git describe --tags --always` falls back to a bare commit hash when no tag exists, and this repo
# has no tags. So the bundle was stamped `CFBundleShortVersionString = e8f29a6` and
# `CFBundleVersion = e8f29a6-dirty`. Apple's rule for `CFBundleVersion` is one to three
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
case "$SHORT_VERSION" in
    *[!0-9.]*|"") SHORT_VERSION="0.0.0" ;;   # a non-numeric tag is not a version either
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

cp "$ROOT/build/icons/Flotilla.icns" "$APP/Contents/Resources/Flotilla.icns"
# The menu-bar template, at both scales. Loaded by URL at runtime and marked isTemplate
# explicitly — the "…Template" filename convention only applies to NSImage(named:).
cp "$ROOT/Resources/MenuBarIconTemplate.png" "$APP/Contents/Resources/"
cp "$ROOT/Resources/MenuBarIconTemplate@2x.png" "$APP/Contents/Resources/"

# The accent colour, as a compiled asset catalog.
#
# Not decoration and not a duplicate of Theme.swift: macOS takes the *system* accent — the
# one AppKit uses for sidebar-list selection and focus rings — from the app's AccentColor
# asset, and ignores SwiftUI's `.tint()` for those. Without this the app tints every SwiftUI
# control watermelon and then draws the selected sidebar row in stock blue.
#
# Best-effort, because `actool` is not always usable: on this machine it aborts with "A
# required plugin failed to load … try running 'xcodebuild -runFirstLaunch'", which needs an
# administrator. A broken Xcode install must not stop the app being built, so a failure here
# downgrades to a warning and the accent key is omitted rather than left pointing at a
# catalog that is not there. Moving to a real Xcode project makes this step disappear.
ACCENT_ASSET=""
echo "▸ compiling asset catalog…"
if actool "$ROOT/Resources/Assets.xcassets" \
     --compile "$APP/Contents/Resources" \
     --platform macosx --minimum-deployment-target 26.0 \
     --output-format human-readable-text >/dev/null 2>&1; then
  ACCENT_ASSET="    <key>NSAccentColorName</key>            <string>AccentColor</string>"
  echo "   ✓ Assets.car (AccentColor)"
else
  echo "   ! actool unavailable — skipping. Sidebar selection and focus rings will use the"
  echo "     system accent instead of watermelon. Fix with: xcodebuild -runFirstLaunch"
fi

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
    <!-- Names the colorset in Assets.car, when one was compiled. AppKit reads this for
         sidebar selection and focus rings; SwiftUI's .tint() does not reach them. -->
$ACCENT_ASSET
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
if [ -n "${FLOTILLA_SIGN_IDENTITY:-}" ]; then
    echo "▸ signing (Developer ID, hardened runtime)…"
    # No `--deep`. Apple's own guidance is to sign inside-out, and this bundle has nothing inside:
    # one flat executable, no frameworks, no helpers, SwiftTerm statically linked. Verified with
    # `otool -L` — nothing outside /usr/lib and /System. `--deep` on a bundle like this does
    # nothing except make a future nested binary silently inherit the wrong options.
    codesign --force --options runtime --timestamp \
             --sign "$FLOTILLA_SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/   /'
    SIGN_MODE="Developer ID"
else
    echo "▸ signing (ad-hoc)…"
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
