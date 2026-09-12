import SwiftUI
import FlotillaCore

/// The macOS app shell.
///
/// The app owner owns this target because it is the one part of Flotilla that cannot be built or
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
    /// Handed over by `FlotillaApp.init`, which runs before `applicationDidFinishLaunching`.
    ///
    /// It used to be assigned in `MainWindowView.onAppear` instead, and that was too late in a
    /// way that mattered: the delegate then read `.both` as a fallback at launch regardless of
    /// what the user had actually chosen, and — because of the scene behaviour described in
    /// `applyPresentation` — the real preference could not be applied until a window existed,
    /// which is precisely the thing the preference decides.
    ///
    /// A static handoff rather than a second `SettingsStore`: one resolved source of truth,
    /// read at the only moment early enough to be useful.
    static var pendingModel: AppModel?

    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = Self.pendingModel
        applyPresentation()
        pruneEmptyFormatMenu()
    }

    /// Removes the Format menu, which the command audit emptied but could not delete.
    ///
    /// `CommandGroup(replacing:)` with an empty body empties a menu; it does not remove it. After
    /// the audit, **Format** sat in the menu bar with nothing behind it — worse than the items it
    /// used to hold, because a menu that opens onto nothing reads as broken rather than absent.
    ///
    /// **Why this matches on the title**, which is normally the wrong thing to do. The obvious
    /// test — remove any top-level menu whose submenu is empty — is wrong here, and removing
    /// View along with Format is how that was found: AppKit fills View with "Enter Full Screen"
    /// *lazily, on first open*, so it reports zero items indefinitely and is indistinguishable
    /// from a genuinely empty menu at any delay. Measured at one runloop turn, 0.5s and 1.5s:
    /// View is zero at all three, and pruning it cost the app its Full Screen item.
    ///
    /// So the title it is, with the emptiness kept as a second condition so this can never remove
    /// a Format menu that someone later fills. The app ships no `.lproj` and no localised strings,
    /// so the title is "Format" on every system that runs this build; if Flotilla is ever
    /// localised, this needs revisiting and will fail visibly — the menu simply returns.
    private func pruneEmptyFormatMenu() {
        // Half a second, measured rather than guessed: at one runloop turn the removal does not
        // stick — SwiftUI is still assembling `NSApp.mainMenu` and puts Format back. The menu bar
        // is not interactive before then either, so nothing is seen to flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let main = NSApp.mainMenu else { return }
            for item in main.items where item.title == "Format" && item.submenu?.items.isEmpty == true {
                main.removeItem(item)
            }
        }
    }

    /// Shells are live `container exec` processes. Quitting Flotilla must not leave them
    /// attached to containers with nothing on screen owning them — which would also make
    /// "Quit — containers keep running" quietly untrue about the shells.
    func applicationWillTerminate(_ notification: Notification) {
        model?.terminals.closeEverything()
        // Live log tails are the same argument as the shells above, and were missing from it:
        // `container logs --follow` children have no reason to stop when their view goes away
        // with the whole app. Measured — a clean quit while the Logs section streamed five
        // sources left all five running under launchd.
        LiveStreamRegistry.shared.cancelAll()
    }

    /// Honours **Show Dock icon**, which is now a toggle rather than a three-way picker.
    ///
    /// Off maps to `.accessory` — no Dock tile, no app menu bar, which is what a menu-bar app is.
    /// On maps to `.regular`. The old `menuBar`/`dock`/`both` picker collapsed to these same two
    /// states, because macOS has no policy for "Dock icon but no menu bar": `dock` and `both` were
    /// the same policy under two names, so the control offered a distinction the system does not
    /// make. The menu-bar item is always present, which is what makes hiding the Dock icon safe —
    /// there is always a way back to the window.
    ///
    /// **The launch policy decides whether a main window ever exists**, which is the fix here
    /// and was not obvious. Measured, not assumed: with `LSUIElement` true the app starts as
    /// `.accessory`, and SwiftUI then never instantiates the `Window` scene at all — no window
    /// object is created, `onAppear` never fires, and switching to `.regular` a moment later
    /// does not retroactively build one. `setActivationPolicy` returns **true**; the app takes
    /// the Dock tile and the menu bar and still has nothing to show. The owner saw the visible half
    /// of this ("I can only see the icon in the menu bar"); the window had to be summoned from
    /// the menu-bar popover every time, which looked like a preference that did nothing.
    ///
    /// So the bundle now ships `LSUIElement` **false** — matching the shipped default of *shown* —
    /// and users who hide the Dock icon are dropped to `.accessory` here instead.
    ///
    /// Whether a window opens at launch is *not* decided here — `defaultLaunchBehavior` on the
    /// `Window` scene states it outright, and setting `.accessory` from this method does not
    /// stop SwiftUI building and showing one. So this method now governs the **Dock icon**
    /// only, which it does correctly in both directions.
    ///
    /// Changing the setting *later* needs no extra machinery: the picker lives in the main
    /// window, so a window necessarily exists by the time anyone can reach it.
    func applyPresentation() {
        let showsDockIcon = model?.showsDockIcon ?? true
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }

        // The result was discarded before. That is the same shape as the unchecked exit codes
        // in `LocalHost.run`: an API that reports failure to nobody. A refused policy change
        // means the window and Dock state silently disagree with the setting, which is exactly
        // the bug that took a screenshot to find.
        if NSApp.setActivationPolicy(policy) {
            // Coming *back* from .accessory leaves the app without a foreground presence until
            // something asks for one, so a switch to a Dock-visible policy has to activate.
            if policy == .regular {
                NSApp.activate(ignoringOtherApps: false)
            }
        } else {
            model?.record("Could not \(showsDockIcon ? "show" : "hide") the Dock icon.",
                          subsystem: "presentation")
        }
    }
}

/// App-menu commands route through `AppModel`'s one-shot requests, exactly like the menu-bar
/// popover. Presenting forms here would duplicate section-owned state and let the toolbar and
/// menu drift into different behaviour.
private struct FlotillaCommands: Commands {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // A check is an explicit trip to Apple's releases page, never a request made by
        // Flotilla itself. A silent comparison would break the app's no-phone-home promise;
        // handing this URL to the browser keeps the network boundary visible to the user.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NSWorkspace.shared.open(ExternalLinks.appleContainerReleases)
            }
        }

        // Settings is a section of the one main window, not a separate Settings scene. Replacing
        // the standard placement gives it the expected app-menu position and shortcut while the
        // same one-shot request path still works after the main window has been closed.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { present { model.requestSection(.settings) } }
                .keyboardShortcut(",", modifiers: .command)
        }

        // Flotilla manages runtime objects rather than documents. It has no generic import,
        // export, page-layout or print operation for these stock File-menu groups to address.
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}

        // Search on the data screens is an app-level filter, not the responder-chain Find panel,
        // and every editable field is plain text. The inherited spelling, substitutions,
        // transformations, speech, Font and Text commands therefore promise editing surfaces
        // that Flotilla does not have. Pasteboard and Undo/Redo stay in their separate groups.
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}

        // The title bar is intentionally replaced by `WindowBar`, so there is no system toolbar
        // to show or customise. The sidebar group stays: its toggle is translated into the app's
        // rail by `MainWindowView`, and that group also owns the working Full Screen command.
        CommandGroup(replacing: .toolbar) {}

        // There is one main window, and forms and details are embedded in it. Commands for
        // arranging all of an app's windows cannot change this layout. The save group remains
        // for Close, and the size group remains for Minimize and Zoom.
        CommandGroup(replacing: .windowArrangement) {}

        // `.newItem` is the File-menu placement. These are creation actions rather than a new
        // top-level menu: a tester looking for New/Run follows the platform's File convention.
        // Control-Command plus each action's initial is deliberate: bare Command-M and Command-P
        // are the system Minimize and Print commands, while bare Command-N belongs to File's
        // generic New action. One consistent modifier pair keeps all six mnemonic without
        // stealing those established shortcuts.
        CommandGroup(after: .newItem) {
            Button("Run Container…") { present(model.requestRunSheet) }
                .keyboardShortcut("r", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)

            Button("New Machine…") { present(model.requestMachineForm) }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)

            Divider()

            Button("Pull Image…") { present(model.requestPullForm) }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)

            Button("Build Image from Dockerfile…") { present(model.requestBuildForm) }
                .keyboardShortcut("b", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)

            Divider()

            Button("New Volume…") { present(model.requestVolumeForm) }
                .keyboardShortcut("v", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)

            Button("New Network…") { present(model.requestNetworkForm) }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(!model.runtimeUsable)
        }

        // Diagnostics belongs in Help because it is needed when the runtime is unavailable;
        // unlike the File actions, this remains useful and enabled in that state.
        CommandGroup(before: .help) {
            Button("Create Support Bundle…") { present(model.requestSupportBundle) }
        }
    }

    /// A command can be invoked after the last window was closed. Set the one-shot request
    /// before opening so `MainWindowView.onAppear` can consume it on its first pass; activation
    /// then makes that reopened window visible rather than leaving it behind another app.
    private func present(_ request: () -> Void) {
        request()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

// `AppearanceMode.colorScheme` used to live here, mapping the preference to SwiftUI's
// `ColorScheme` for `preferredColorScheme`. Both call sites are gone and so is it: appearance is
// applied through AppKit now (`AppModel.applyAppKitAppearance()`), because SwiftUI's version sets
// a window-level override it never clears, which is what made Auto stick on the previous choice
// until the app was reactivated. Dead code that documents a removed mechanism is worse than no
// code — the reasoning is recorded where the behaviour lives.

@main
struct FlotillaApp: App {
    /// Loaded once. `isTemplate` is set explicitly rather than relying on the filename
    /// convention, which only applies to `NSImage(named:)` and would silently do nothing for
    /// an image loaded from a bundle URL — leaving a black glyph that vanishes on a dark menu
    /// bar. Falls back to an SF Symbol if the resource is missing, so a packaging mistake
    /// degrades to a visible placeholder rather than an invisible menu-bar item.
    static let menuBarIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "sailboat", accessibilityDescription: "Flotilla")
            ?? NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Flotilla")!
        fallback.isTemplate = true
        return fallback
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    /// Runs before `applicationDidFinishLaunching`, which is the whole point: it is the only
    /// hook early enough to tell the delegate the user's presentation preference *before*
    /// SwiftUI decides whether to build the main window. See `applyPresentation`.
    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.pendingModel = model
    }

    var body: some Scene {
        // The glance. `.menuBarExtraStyle(.window)` gives a real popover we can lay out,
        // rather than a plain menu of NSMenuItems.
        MenuBarExtra {
            MenuBarView(model: model)
                // The popover needs it too: appearance applied only to the main window
                // would leave the menu bar disagreeing with the rest of the app.
                // **No `preferredColorScheme`.** It was here, and it was the second writer in a
                // two-writer bug. SwiftUI implements it by setting the *window's* `NSAppearance`
                // — and it does not clear that override when the value goes back to `nil`, nor
                // immediately re-apply on change. So Light and Dark worked, Auto left the window
                // on its last explicit appearance, and switching apps and back fixed it, because
                // reactivation is when SwiftUI finally re-evaluated. The owner found it exactly that
                // way.
                //
                // `AppModel.applyAppKitAppearance()` now owns appearance for app *and* windows,
                // and SwiftUI reads `\.colorScheme` from the window it is drawing in, so views
                // still follow. One authority.
                .tint(Theme.accent)
        } label: {
            // The brand mark, as a **template** image: macOS inverts it for a light or dark
            // menu bar automatically, so one asset serves both and there is no pair to drift.
            // Monochrome is not a compromise here — `research/FEATURES.md` specifies a
            // monochrome template with state shown by shape or badge, which is what every
            // system menu-bar item does. `shippingbox` was a placeholder SF Symbol.
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Flotilla", id: "main") {
            MainWindowView(model: model)
                // The delegate owns activation policy; the model owns the preference. Wire
                // them here rather than giving the delegate its own SettingsStore, which
                // would be a second source of truth for the same setting.
                .onAppear {
                    model.onPresentationChange = { [weak appDelegate] in
                        appDelegate?.applyPresentation()
                    }
                }
                .frame(minWidth: 900, minHeight: 520)
                // Nothing *hardcodes* a scheme — this is the user's own stored choice, and
                // `.auto` resolves to nil so the system value still wins.
                // **No `preferredColorScheme`.** It was here, and it was the second writer in a
                // two-writer bug. SwiftUI implements it by setting the *window's* `NSAppearance`
                // — and it does not clear that override when the value goes back to `nil`, nor
                // immediately re-apply on change. So Light and Dark worked, Auto left the window
                // on its last explicit appearance, and switching apps and back fixed it, because
                // reactivation is when SwiftUI finally re-evaluated. The owner found it exactly that
                // way.
                //
                // `AppModel.applyAppKitAppearance()` now owns appearance for app *and* windows,
                // and SwiftUI reads `\.colorScheme` from the window it is drawing in, so views
                // still follow. One authority.
                // The watermelon accent, applied once at the scene root so every stock
                // control inherits it. Set per-view it would be forgotten somewhere, and
                // one blue segmented control in a pink app is worse than all-blue.
                .tint(Theme.accent)
                .task { await model.reload() }
                // First run: ask, with Auto pre-selected. `needsAppearanceOnboarding` is
                // false once answered, including when the answer was Auto — which is
                // exactly why the store models `notChosen` separately.
                .sheet(isPresented: .constant(model.needsAppearanceOnboarding)) {
                    OnboardingView(model: model)
                }
        }
        // Content to the top of the window, traffic lights floating over it.
        //
        // This is what lets `WindowBar` span the full width with the sidebar *below* it — the
        // arrangement the owner asked for from Docker Desktop. The route matters: an
        // `NSTitlebarAccessoryViewController` was tried first, on the second reviewer's research, and it cannot
        // work here. Measured: AppKit laid the accessory out at `(208, …, 972 × 36)` in a 1180pt
        // window — the content area only — because a full-height sidebar runs up *under* the
        // title bar, so nothing in the titlebar region can span across it.
        //
        // `.hiddenTitleBar` is not `.toolbar(.hidden, for: .windowToolbar)`, which the second reviewer warned
        // takes the traffic lights, window dragging and the sidebar toggle with it. This keeps
        // the window's standard buttons; only the title bar's own drawing goes.
        .windowStyle(.hiddenTitleBar)
        // **Measured against the densest screen, which is the Dashboard.** At the old 1180×720
        // its content ran 59pt past the viewport with only four containers up, so a first launch
        // met a scrolling, squashed dashboard — and nobody saw it, because a window whose frame
        // macOS has restored keeps whatever size it was dragged to. It only shows on a machine
        // that has never run the app, or after the saved frame is lost.
        //
        // 860 is the first height that clears it with headroom: measured by resizing the live
        // window, the vertical scroll indicator disappears at exactly 800 with four utilisation
        // rows, and the panel grows 24pt a row (`utilisationHeight`) to a cap of eight — so 860
        // holds seven of the eight and the fullest possible dashboard scrolls by a sliver rather
        // than the common one scrolling always.
        //
        // And it still fits a 1440×900 display: 860 plus the ~25pt menu bar leaves room, which
        // is the constraint that stops this being simply "make it taller". 1280 wide for the
        // same reason — it gives the side-by-side Throughput and Resources panels and the
        // six-column utilisation table real room without exceeding the narrowest Mac screen.
        .defaultSize(width: 1280, height: 860)
        // **This is the fix for "it only shows in the menu bar".**
        //
        // Left to `.automatic`, SwiftUI infers whether to present this scene at launch from the
        // activation policy and restoration state, and that inference was the bug: under an
        // accessory launch policy the window was never built at all — `onAppear` never ran and
        // switching to `.regular` afterwards did not create one — so Flotilla came up as a menu
        // bar icon with nothing behind it and the "Show Flotilla in" preference looked dead.
        // It was intermittent even at a fixed `LSUIElement`, which is what made it hard to see.
        //
        // Unconditional, and that is a KNOWN LIMITATION rather than an oversight: with
        // "Menu bar only" chosen, the Dock icon does correctly disappear (`.accessory`) but a
        // window still opens at login. Three ways to prevent it were tried and none held —
        // `.suppressed` still produced the window, and closing it from `onAppear` via either
        // `dismissWindow` or AppKit ran before the window was ordered in and did nothing.
        // Shipping `.presented` for everyone beats shipping machinery that does not work:
        // the previous behaviour was no window in ANY mode, for everyone.
        .defaultLaunchBehavior(.presented)
        .commands {
            FlotillaCommands(model: model)
        }

        // Container detail used to be a `WindowGroup` here. It is now a modal sheet presented
        // by `ContainersView`, for the reason the owner gave: a real window brought its own traffic
        // lights back and left the app behind it undimmed, so detail was the one surface that
        // did not behave like every other pop-up in the app. Consistency won.
        //
        // The trade is real and worth naming: detail is no longer resizable, and you can no
        // longer keep several open beside the table. Both were genuine advantages of a window.
    }
}
