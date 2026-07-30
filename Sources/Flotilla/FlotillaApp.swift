import SwiftUI
import FlotillaCore

/// The macOS app shell.
///
/// the app owner owns this target because it is the one part of Flotilla that cannot be built or
/// verified anywhere but a Mac with Xcode — `FlotillaCore` is deliberately Foundation-only
/// so the data/backend agents can compile and test their own work on Linux. Nothing in
/// this target may leak back into `FlotillaCore`.
///
/// Shape per `DECISIONS.md` and the approved mockups in `research/review/mockups/`:
/// - the **menu-bar popover is a glance**, not the product — status, quick start/stop, and a
///   way into the real window. No text entry, no destructive confirmations.
/// - the **main window is the product** — a cross-host container **table** (Q2: table is the
///   default, cards are a toggle).
/// - appearance is **chosen at first run**, `auto` pre-selected — so nothing here hardcodes a
///   `preferredColorScheme`; the system value is honoured until the user picks.
/// Run as a bare SwiftPM executable there is no app bundle and no Info.plist, so AppKit
/// never assigns a real activation policy — and a process that isn't a "regular" app
/// cannot put a window on screen. `openWindow` then fires and nothing appears. Claiming
/// `.regular` at launch makes windows work before the Xcode project exists.
///
/// When this moves to a bundle, the menu-bar behaviour is set by `LSUIElement` in the
/// Info.plist instead and this shim should go.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

/// `AppearanceMode` lives in `FlotillaCore`, which is Foundation-only and so cannot name
/// SwiftUI's `ColorScheme`. The mapping therefore belongs here, in the one target allowed
/// to import SwiftUI. `nil` is what makes `.auto` follow the system.
extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct FlotillaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // The glance. `.menuBarExtraStyle(.window)` gives a real popover we can lay out,
        // rather than a plain menu of NSMenuItems.
        MenuBarExtra("Flotilla", systemImage: "shippingbox") {
            MenuBarView(model: model)
                // The popover needs it too: appearance applied only to the main window
                // would leave the menu bar disagreeing with the rest of the app.
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)

        Window("Flotilla", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 520)
                // Nothing *hardcodes* a scheme — this is the user's own stored choice, and
                // `.auto` resolves to nil so the system value still wins.
                .preferredColorScheme(model.appearance.colorScheme)
                .task { await model.reload() }
                // First run: ask, with Auto pre-selected. `needsAppearanceOnboarding` is
                // false once answered, including when the answer was Auto — which is
                // exactly why the store models `notChosen` separately.
                .sheet(isPresented: .constant(model.needsAppearanceOnboarding)) {
                    OnboardingView(model: model)
                }
        }
        .defaultSize(width: 1180, height: 720)
    }
}
