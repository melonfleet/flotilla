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

echo "▸ building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product Flotilla
else
  swift build --product Flotilla
fi
BINARY="$(swift build -c "$CONFIG" --product Flotilla --show-bin-path)/Flotilla"
[ -x "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

# Version comes from the git description so a support bundle can name the exact build it
# came from. A dirty tree is marked as such rather than silently claiming a clean tag.
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")"
SHORT_VERSION="$(printf '%s' "$VERSION" | sed 's/^v//; s/-.*//')"
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.0.0"

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
    <key>CFBundleVersion</key>              <string>$VERSION</string>
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

# Ad-hoc signature. Not distribution signing — that is Developer ID + notarization in
# Phase 5 — but an unsigned bundle gets an unstable identity, and notification
# authorization is remembered per identity, so without this the permission prompt can
# reappear on every rebuild.
echo "▸ signing (ad-hoc)…"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>&1 | sed 's/^/   /'

echo "▸ verifying…"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | sed 's/^/   bundle id: /'
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist" | sed 's/^/   LSUIElement: /'

echo "✓ $APP"
echo "  open it with:  open \"$APP\""
