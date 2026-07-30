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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `FlotillaApp` before launch finishes, so the delegate can read the user's
    /// presentation preference without owning a second `SettingsStore`.
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyPresentation()
    }

    /// Honours **Show Flotilla in: Menu bar / Dock / Both**, which had been a picker driving
    /// nothing: this shim previously hardcoded `.regular` regardless of the setting.
    ///
    /// `LSUIElement` in the bundle sets only the *starting* policy. Switching at runtime is
    /// what makes the preference take effect without a relaunch, and is why the setting can
    /// now be honest.
    ///
    /// `menuBar` maps to `.accessory` — no Dock icon, no menu bar for the app itself, which
    /// is the point of a menu-bar app. `dock` and `both` are both `.regular`: macOS has no
    /// policy for "Dock icon but no menu bar", so the two collapse, and the distinction is
    /// only meaningful once the menu-bar extra itself can be hidden (Phase 5 territory).
    func applyPresentation() {
        let presentation = model?.presentation ?? .both
        let policy: NSApplication.ActivationPolicy = presentation == .menuBar ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming *back* from .accessory leaves the app without a foreground presence until
        // something asks for one, so a switch to a Dock-visible policy has to activate.
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: false)
        }
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
                // The delegate owns activation policy; the model owns the preference. Wire
                // them here rather than giving the delegate its own SettingsStore, which
                // would be a second source of truth for the same setting.
                .onAppear {
                    appDelegate.model = model
                    model.onPresentationChange = { [weak appDelegate] in
                        appDelegate?.applyPresentation()
                    }
                    appDelegate.applyPresentation()
                }
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
