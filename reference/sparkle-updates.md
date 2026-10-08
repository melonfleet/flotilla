# Sparkle auto-updates via GitHub releases — Flotilla (Phase 5)

Self-update for dev machines and unmanaged hosts. (Jamf-managed minis update via
Jamf instead — Phase 6.)

## Setup

1. **Add Sparkle** via Swift Package Manager: `https://github.com/sparkle-project/Sparkle`.
2. **Info.plist:**
   - `SUFeedURL` → the appcast URL (a stable GitHub URL, e.g. a `appcast.xml` in a
     `gh-pages` branch or a permalink to a release asset).
   - `SUPublicEDKey` → your EdDSA public key (Sparkle signs updates; generate keys
     with Sparkle's `generate_keys`).
   - `CFBundleVersion` must increment per release (Sparkle compares these).
3. **SwiftUI wiring:** create an `SPUStandardUpdaterController` and add a
   "Check for updates…" command to the app menu.

```swift
import Sparkle

final class Updater: ObservableObject {
    let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
}
// In the Scene: .commands { CommandGroup(after: .appInfo) {
//   Button("Check for updates…") { updater.controller.checkForUpdates(nil) } } }
```

## Release flow

1. Build + archive the `.app`, sign and **notarize** it (required for Gatekeeper),
   then zip it.
2. Run Sparkle's `generate_appcast <dir>` over a folder of release zips — it writes
   `appcast.xml` with correct lengths, EdDSA signatures, and delta updates.
3. Upload the zip as a **GitHub release asset**; host `appcast.xml` where `SUFeedURL`
   points. Ensure the `<enclosure url=…>` in the appcast matches the asset's public
   download URL.
4. (Optional) Automate steps 1–3 with GitHub Actions on tag push.

## Gotchas

- The app must be signed + notarized or updates won't apply cleanly.
- Keep the EdDSA **private** key out of the repo (it signs releases).
- `CFBundleShortVersionString` is the display version; `CFBundleVersion` is the
  comparison key — bump the latter every release.

## Sources

- [Sparkle](https://github.com/sparkle-project/Sparkle) · [docs](https://sparkle-project.org/documentation/)
- [Integrating Sparkle in SwiftUI](https://medium.com/@borto_ale/integrating-sparkle-updater-in-swiftui-for-macos-82ae4e0b4ac6)
- [Automating Sparkle releases with GitHub Actions](https://medium.com/@alex.pera/automating-xcode-sparkle-releases-with-github-actions-bd14f3ca92aa)
