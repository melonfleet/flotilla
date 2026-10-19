import SwiftUI
import FlotillaCore

/// The runtime's state and menu, in the window's status bar: whether `container` is running, and
/// the few things you might want to do about it. The sidebar used to carry this as a band of its
/// own; the status bar is the one place now.
///
/// **Nothing here reaches the network.** "Check for updates" opens Apple's releases page in the
/// browser rather than comparing versions, because Flotilla makes no requests of its own and a
/// background version check would be precisely the phone-home it promises it does not do.
struct RuntimeStatusBand: View {
    let model: AppModel

    @Environment(\.openURL) private var openURL
    /// Which of the two destructive items is being confirmed, and whether the dialog is up.
    ///
    /// Two properties for one idea, deliberately. The obvious single-property spelling —
    /// `confirming: RuntimeLifecycleAction?` with `isPresented:` a computed `Binding` over
    /// `confirming != nil` — **does not present the dialog at all**: measured, by clicking Stop
    /// and finding no sheet in the accessibility tree while the same menu's Settings item fired
    /// normally. Swapping the computed binding for a real `@State` `Bool` was the only change
    /// that made it appear. So the flag stays real, and `ask(_:)` is the only thing that sets
    /// either — nothing else may, or they drift and the dialog asks the wrong question.
    @State private var confirming: RuntimeLifecycleAction = .stop
    @State private var showingConfirmation = false

    var body: some View {
        // A dot and "Container" (Kamal, 19 October): clicking opens the menu, whose first line states
        // the status. The full status sentence is in the tooltip and the accessibility label.
        statusMenu
            .frame(height: 23)
            .confirmationDialog(confirming.question,
                                isPresented: $showingConfirmation,
                                titleVisibility: .visible) {
                Button(confirming.verb, role: .destructive) { perform(confirming) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirming.consequence)
            }
    }

    private var fullStatus: String {
        status.detail.map { "\(status.title) — \($0)" } ?? status.title
    }

    /// The first line of the menu: "Running", "Stopped" — the short word for the one verdict.
    private var shortStatus: String {
        if let setup = model.runtimeSetup { return RuntimeBanner.setupTitle(setup) }
        return RuntimeStatus.short(model.preflight)
    }

    /// A spinner while the runtime is being started or restarted — "busy" and "unavailable" are
    /// different states, and a dot that stays amber through a restart says neither.
    private var statusMenu: some View {
        Menu {
            runtimeActions()
        } label: {
            // The dot and the word "Container", like the Helper item beside it: two dots side by side
            // can't say which is which (Kamal, 19 October). The status itself is the menu's first line.
            HStack(spacing: 4) {
                Group {
                    if model.startingRuntime || settingUp {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(status.tint).frame(width: 7, height: 7)
                    }
                }
                .frame(width: 10, height: 23)
                Text("Container")
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // On the dot itself: in the collapsed sidebar the block's tooltip lost to the menu's own, so
        // pointing at the dot said nothing (the owner, on Tahoe, 10 October).
        .help(fullStatus)
        .accessibilityLabel("Container runtime: \(status.title)")
        .accessibilityHint("Opens the runtime menu")
        .disabled(model.startingRuntime)
    }

    /// The one builder for the menu, including enablement and confirmations.
    @ViewBuilder
    private func runtimeActions() -> some View {
        // The first line states the status, now that the bar shows only a dot (Kamal, 19 October).
        Text(shortStatus).disabled(true)
        Divider()
        // All three lifecycle items, always, with the ones that do not apply greyed out
        // rather than absent — the owner's call, and the right one: a menu whose items move
        // around teaches nothing, while a disabled Stop says plainly that the system is
        // already stopped. Which is which comes from `enablement` below.
        Button("Start Container System") { Task { await model.startRuntime() } }
            .disabled(!enablement.start)
        Button("Stop Container System…") { ask(.stop) }
            .disabled(!enablement.stopRestart)
        // The remedy for a skewed runtime is exactly this item, and there it runs *without*
        // the confirmation: nothing useful is running in that state anyway.
        if case .needsRestart = model.preflight {
            Button("Restart Container System") { Task { await model.restartRuntime() } }
        } else {
            Button("Restart Container System…") { ask(.restart) }
                .disabled(!enablement.stopRestart)
        }

        // Always present, greyed out unless they apply, like the lifecycle items above: a menu
        // whose items come and go teaches nothing. Installing container was missing from this
        // menu, so with everything else greyed out there was no way in from here (8 October).
        Button("Download and Install container \(ContainerRuntime.expectedVersion)…") {
            if model.hostMode.mode == .host, model.helperEnabled, case .missing? = model.preflight {
                Task { model.hostRuntimeNote = await model.ensureHostRuntime(allowStoppingContainers: true) }
            } else {
                Task { await model.installContainerInteractively() }
            }
        }
        .disabled(!model.needsContainerInstall || settingUp)
        Button("Install Recommended Kernel") { Task { await model.installKernel() } }
            .disabled(!needsKernel)

        Divider()
        Button("Settings…") { model.requestSection(.settings) }

        Divider()
        Button("Check for `container` Updates…") {
            openURL(ExternalLinks.appleContainerReleases)
        }
        Button("Apple `container` on GitHub") { openURL(ExternalLinks.appleContainer) }
        Button("Flotilla on GitHub") { openURL(ExternalLinks.flotilla) }
    }

    private var needsKernel: Bool {
        if case .needsKernel = model.preflight { true } else { false }
    }

    /// The only writer of the confirmation state — see the note on `confirming`.
    private func ask(_ action: RuntimeLifecycleAction) {
        confirming = action
        showingConfirmation = true
    }

    private func perform(_ action: RuntimeLifecycleAction) {
        switch action {
        case .stop: Task { await model.stopRuntime() }
        case .restart: Task { await model.restartRuntime() }
        }
    }

    private var enablement: (start: Bool, stopRestart: Bool) { RuntimeStatus.enablement(model.preflight) }

    /// A setup under way says so here as well as in the banner: this corner is where someone
    /// looks to see whether `container` is being installed (beta 2's test, 8 October).
    private var status: (title: String, detail: String?, tint: Color) {
        if let setup = model.runtimeSetup {
            if case .failed = setup.phase { return (RuntimeBanner.setupTitle(setup), nil, Theme.danger) }
            return (RuntimeBanner.setupTitle(setup), nil, .secondary)
        }
        return RuntimeStatus.describe(model.preflight)
    }

    private var settingUp: Bool {
        guard let setup = model.runtimeSetup else { return false }
        if case .failed = setup.phase { return false }
        return true
    }
}

/// What the runtime is doing and what may be done to it, from the one preflight verdict — shared by
/// the status bar and the Hosts table so the two cannot say different things.
enum RuntimeStatus {
    /// Which lifecycle items are live, from the one verdict the rest of the app already trusts.
    ///
    /// Stop and Restart move together because they are the same requirement: both begin by
    /// tearing the services down, so both need something running to tear down.
    ///
    /// `.unusable` enables everything, which looks inconsistent and is not. The other cases know
    /// whether the services are up; that one explicitly does not — the CLI is installed and
    /// answering, but preflight could not get a usable runtime out of it. Greying all three out
    /// there would leave the user with the one screen that says something is wrong and no control
    /// on it, when the printed remedy for the commonest cause is literally `container system start`.
    ///
    /// `.missing` and `.tooOld` disable everything, because there is no runtime on this Mac to
    /// drive, and so does a nil verdict: preflight has not finished, and offering a control before
    /// knowing what it would do is how you get a Stop that starts things.
    static func enablement(_ preflight: PreflightResult?) -> (start: Bool, stopRestart: Bool) {
        switch preflight {
        case .ok, .needsRestart, .needsKernel: (start: false, stopRestart: true)
        case .serviceStopped:         (start: true, stopRestart: false)
        case .unusable:               (start: true, stopRestart: true)
        case .missing, .tooOld, nil:  (start: false, stopRestart: false)
        }
    }

    /// One word for the menu's first line (Kamal, 19 October): the status bar shows only a dot, and
    /// the menu it opens begins with this. Read from the same verdict as `describe`.
    static func short(_ preflight: PreflightResult?) -> String {
        switch preflight {
        case .ok: "Running"
        case .serviceStopped: "Stopped"
        case .needsRestart: "Restart needed"
        case .needsKernel: "No kernel installed"
        case .tooOld: "Too old"
        case .missing: "Not installed"
        case .unusable: "Not usable"
        case nil: "Checking…"
        }
    }

    /// What the status bar says, straight from the preflight the rest of the app already acts on — so it
    /// cannot claim the runtime is fine while the container list explains that it is not.
    static func describe(_ preflight: PreflightResult?) -> (title: String, detail: String?, tint: Color) {
        switch preflight {
        case .ok(let version, _):
            ("Container system running", "container \(version)", Theme.online)
        case .serviceStopped(let version, _, _):
            ("Container system stopped", "container \(version)", Theme.warning)
        case .needsRestart(let cli, let service, _):
            ("Restart needed after upgrade", "CLI \(cli), service \(service)", Theme.warning)
        case .needsKernel(let version, _, _):
            ("No kernel installed", "container \(version)", Theme.warning)
        case .tooOld(let found, let required):
            ("container \(found) is too old", "needs \(required)", Theme.warning)
        case .missing:
            // Amber, as a host without container is on the admin's Hosts list: something to set
            // up, not something broken (the owner, 10 October). A failed install stays red.
            ("container is not installed", nil, Theme.warning)
        case .unusable:
            ("container is not usable", nil, Theme.danger)
        case nil:
            ("Checking the container system…", nil, .secondary)
        }
    }
}

/// The two items that take the services down. Both ask first, and both ask in their own
/// words: "every running container stops" is the whole story for Stop, and only half of it
/// for Restart, where what matters is that they do not come back on their own.
enum RuntimeLifecycleAction {
    case stop, restart

    var question: String {
        switch self {
        case .stop: "Stop the container system?"
        case .restart: "Restart the container system?"
        }
    }

    var verb: String {
        switch self {
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }

    var consequence: String {
        switch self {
        case .stop:
            "Every running container stops with it. Nothing new can start until you start it again."
        case .restart:
            "Every running container stops with it, and does not come back on its own."
        }
    }
}
