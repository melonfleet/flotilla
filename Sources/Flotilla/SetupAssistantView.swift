import SwiftUI
import AppKit
import FlotillaCore

/// The first-run setup assistant (option A, decided 13 October; refined by Iris,
/// `research/FIRST-RUN.md`). It replaced `OnboardingView`, a single 460pt sheet.
///
/// A window of its own, 720 × 600 and the same on every step: the steps down the left on the
/// theme's bar colour, "Step n of 5" at the top, and Back and Continue at the bottom — with
/// **Not now** only where the step's offer is optional (`SetupContext.offersNotNow`). Five steps and
/// a Finish; the order and the rules are in `SetupAssistant.swift` in `FlotillaCore`, with tests.
///
/// **What is saved when.** Each step saves its own answers on Continue, except two:
/// - the **appearance** is saved at Finish, because it is the "setup complete" flag
///   (`needsAppearanceOnboarding`) — so a first run abandoned half way is offered again. Until then
///   the window shows it through `AppModel.appearancePreview`;
/// - a **host** role is saved on the Prepare step, when Local Network is asked for, because saving
///   it starts the listener, and the listener is what makes macOS ask. Saving it on the first step
///   would put the system alert up two steps before the explanation of why.
///
/// Nothing here installs or asks for anything without a button: `container` goes through
/// `installContainerInteractively` (Apple's Installer asks for the password), the helper through
/// Login Items, and Local Network through macOS's own alert.
///
/// Return continues and Escape goes back; each step is announced to VoiceOver as it appears.
struct SetupAssistantView: View {
    static let windowID = "setup"
    static let size = CGSize(width: 720, height: 600)

    let model: AppModel

    @Environment(\.themeChoice) private var themes
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var flow = SetupFlow()

    // Answers, pre-selected from what is saved — on a first run, the defaults.
    @State private var role: RunMode
    @State private var launchAtLogin = true
    @State private var appearance: AppearanceMode
    @State private var turnOnGreta = true
    @State private var installContainer = true
    @State private var turnOnHelper = true
    @State private var onlineChecks: [SetupOnlineCheck: Bool]

    // What the system says, read live.
    @State private var greta: GretaAvailability = .current
    @State private var helper = PrivilegedHelper.status
    @State private var localNetwork = LocalNetworkCheck()

    init(model: AppModel) {
        self.model = model
        let store = model.settingsStore
        _role = State(initialValue: store[SettingsKeys.mode])
        // Checked for a host-to-be (Iris); a re-run on a host shows what it has.
        _launchAtLogin = State(initialValue: store[SettingsKeys.mode] == .host ? store[SettingsKeys.launchAtLogin] : true)
        _appearance = State(initialValue: store.effectiveAppearance)
        _turnOnGreta = State(initialValue: store.needsAppearanceOnboarding || store[SettingsKeys.gretaEnabled])
        _onlineChecks = State(initialValue: Dictionary(uniqueKeysWithValues: SetupOnlineCheck.allCases.map { check in
            (check, store.effectiveValues()[check.settingName] == .bool(true))
        }))
    }

    private var store: SettingsStore { model.settingsStore }

    private var context: SetupContext {
        SetupContext(role: role, needsContainer: model.needsContainerInstall, gretaAvailable: greta.isAvailable,
                     helperOn: helper == .enabled || helper == .unavailable)
    }

    var body: some View {
        HStack(spacing: 0) {
            stepList
            VStack(spacing: 0) {
                Text(flow.step.progressLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 22)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)    // announced with the step, below
                // Every step scrolls inside a fixed frame, so none can grow the window (CLAUDE.md,
                // "one unbounded child can scroll the whole window").
                ScrollView {
                    page
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .bottom) {
                    if flow.step == .welcome {
                        // The seascape across the lower third, as on Overview's Get started.
                        FlotillaSeascape().frame(height: Self.size.height / 3)
                    }
                }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBackground(themes, opaque: true))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { refreshSystemState() }
        .onDisappear {
            // Finished or closed half way, the window stops previewing; Finish has saved by then.
            model.appearancePreview = nil
            localNetwork.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: Login Items, Apple Intelligence or Local Network.
            refreshSystemState()
            localNetwork.recheck()
        }
        .onChange(of: appearance) { model.appearancePreview = appearance }
        .onChange(of: flow.step) {
            AccessibilityNotification.Announcement("\(flow.step.progressLabel). \(flow.step.title)").post()
        }
        // Greta's model can become ready while the window is open (a download finishing, Apple
        // Intelligence switched on): looked at again every few seconds while her step shows.
        .task(id: flow.step) {
            guard flow.step == .greta else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                greta = .current
            }
        }
    }

    private func refreshSystemState() {
        greta = .current
        helper = PrivilegedHelper.status
    }

    // MARK: The list of steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 13, lockup: .bar)
                .fixedSize()
                .padding(.top, 46)    // clear of the traffic lights
                .padding(.bottom, 28)
                .accessibilityLabel("Flotilla setup")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupStep.allCases, id: \.self) { step in stepRow(step) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.titleBar(themes))
    }

    private func stepRow(_ step: SetupStep) -> some View {
        let ink = Theme.onTitleBar(themes)
        let current = step == flow.step
        let done = flow.done.contains(step) && !current
        return HStack(spacing: 9) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                } else if let number = step.number {
                    Circle().strokeBorder(ink.opacity(current ? 1 : 0.55), lineWidth: 1.2)
                    Text("\(number)").font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "flag.checkered").font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 20, height: 20)
            Text(step.title)
                .font(.body.weight(current ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink.opacity(current || done ? 1 : 0.62))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ink.opacity(current ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue(current ? "Current step" : done ? "Done" : "")
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch flow.step {
        case .welcome: welcomePage
        case .appearance: appearancePage
        case .greta: gretaPage
        case .prepare: preparePage
        case .onlineChecks: onlineChecksPage
        case .finish: finishPage
        }
    }

    private func heading(_ title: String, _ lead: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let lead {
                Text(lead).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 1 · Welcome and role

    private var modeLocked: Bool { store.isLocked(SettingsKeys.mode) }

    private var welcomePage: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Flotilla")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Run containers here and manage them across your Macs.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                Text("How will you use this Mac?").font(.headline)
                if modeLocked {
                    Text("As \(role == .host ? "a host" : "an admin Mac") — set by your organisation.")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 12) {
                    roleCard(.client, symbol: "macbook.and.iphone",
                             points: ["Run containers on this Mac.", "Add other Macs as hosts and manage them from here."],
                             consequence: "Listens for nothing on the network.")
                    roleCard(.host, symbol: "desktopcomputer",
                             points: ["Run containers on this Mac.", "An admin Mac you pair with manages it."],
                             consequence: "Accepts connections from the admin Mac you pair with.")
                }
                .disabled(modeLocked)
                if role == .host {
                    Toggle("Open Flotilla at login, so its admin can reach it after a restart", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .disabled(store.isLocked(SettingsKeys.launchAtLogin))
                }
                Text("You can change this later in Settings ▸ Host Mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func roleCard(_ mode: RunMode, symbol: String, points: [String], consequence: String) -> some View {
        let selected = role == mode
        return Button { role = mode } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.info)
                    Text(mode.title).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                ForEach(points, id: \.self) { point in
                    Label(point, systemImage: "checkmark").font(.callout).labelStyle(SetupBulletLabel())
                }
                Label(consequence, systemImage: "network").font(.callout).foregroundStyle(.secondary)
                    .labelStyle(SetupBulletLabel())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                              lineWidth: selected ? 2 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.title). \(points.joined(separator: " ")) \(consequence)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: 2 · Make it yours

    private var appearanceLocked: Bool { store.isLocked(SettingsKeys.appearance) }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Make It Yours", "How Flotilla looks. Everything here is in Settings ▸ General too.")
            VStack(alignment: .leading, spacing: 6) {
                Picker("Appearance", selection: $appearance) {
                    Text("Auto").tag(AppearanceMode.auto)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(appearanceLocked)
                Text(appearanceExplanation).font(.callout).foregroundStyle(.secondary)
            }
            SetupThemeGrid(appearance: .light, model: model)
            SetupThemeGrid(appearance: .dark, model: model)
        }
    }

    private var appearanceExplanation: String {
        if appearanceLocked { return "Set by your organisation." }
        return switch appearance {
        case .auto: "Follows macOS, with the light theme by day and the dark one after sunset if macOS switches."
        case .light: "Always light, whatever macOS is set to."
        case .dark: "Always dark, whatever macOS is set to."
        }
    }

    // MARK: 3 · Greta

    private var gretaPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                GretaAvatarView(style: model.gretaAvatar, size: 64, tiled: true)
                    .accessibilityHidden(true)
                heading("Meet Greta", "Flotilla's assistant, on this Mac.")
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Runs on this Mac with Apple's on-device model. Nothing is sent away.", systemImage: "lock")
                Label("Answers questions about Flotilla and your containers.", systemImage: "text.bubble")
                Label("Reads and drafts — she never runs anything. You review every draft.", systemImage: "hand.raised")
            }
            .labelStyle(SetupBulletLabel())

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: greta.isAvailable ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(greta.isAvailable ? Theme.online : Theme.warning)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Text(greta.message)
                    if greta.offersSettings {
                        HStack(spacing: 10) {
                            Button("Open Apple Intelligence Settings") { SystemSettingsLink.appleIntelligence() }
                            Text("System Settings ▸ Apple Intelligence & Siri")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)

            Toggle(greta.isAvailable ? "Turn on Greta" : "Turn on Greta, so she's ready when Apple's model is",
                   isOn: $turnOnGreta)
                .toggleStyle(.checkbox)
                .disabled(store.isLocked(SettingsKeys.gretaEnabled))
        }
    }

    // MARK: 4 · Prepare this Mac

    private var preparePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Prepare This Mac", role == .host
                    ? "What a host needs to run containers and be reached by its admin."
                    : "What this Mac needs to run containers.")
            containerTask
            if role == .host {
                helperTask
                localNetworkTask
            } else {
                Text("Flotilla asks for Local Network access when you first add a host, not before.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func setupTask<Content: View>(_ title: String, done: Bool?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch done {
                case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.online)
                case false?: Image(systemName: "circle").foregroundStyle(.secondary)
                case nil: ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 16))
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var containerTask: some View {
        let version = ContainerRuntime.expectedVersion
        if let setup = model.runtimeSetup {
            setupTask("Apple's container", done: { if case .failed = setup.phase { false } else { nil } }()) {
                Text(RuntimeBanner.setupTitle(setup))
                Text(RuntimeBanner.setupDetail(setup)).font(.callout).foregroundStyle(.secondary)
            }
        } else if model.preflight == nil {
            setupTask("Apple's container", done: nil) {
                Text("Checking for container…").foregroundStyle(.secondary)
            }
        } else if !model.needsContainerInstall {
            setupTask("Apple's container", done: true) {
                Text("Installed. Flotilla runs your containers with it.").foregroundStyle(.secondary)
            }
        } else if role == .host {
            setupTask("Apple's container", done: false) {
                Text("Not installed yet. As a host, Flotilla installs container \(version) and its kernel by itself "
                     + "once the Flotilla Helper is on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            setupTask("Apple's container", done: false) {
                Toggle("Download and install container \(version) when I continue", isOn: $installContainer)
                    .toggleStyle(.checkbox)
                Text("Apple's installer, about 118 MB from Apple's releases on github.com. Flotilla checks it is "
                     + "Apple's, then Apple's Installer asks for your password. Then the kernel containers run on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var helperTask: some View {
        switch helper {
        case .enabled:
            setupTask("Flotilla Helper", done: true) {
                Text("On. It installs and updates container on this host, and keeps its DNS names.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .awaitingApproval:
            setupTask("Flotilla Helper", done: false) {
                Text("Waiting for you to switch on Flotilla in System Settings ▸ General ▸ Login Items & Extensions.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Login Items…") { PrivilegedHelper.openLoginItems() }
            }
        case .notInstalled:
            setupTask("Flotilla Helper", done: false) {
                Toggle("Turn on the Flotilla Helper when I continue", isOn: $turnOnHelper)
                    .toggleStyle(.checkbox)
                Text("Flotilla's one helper for the jobs that need an administrator: installing Apple's container, DNS "
                     + "domains and names across Macs. macOS asks you to approve it in Login Items; Flotilla still asks "
                     + "you to confirm every change.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .unavailable:
            setupTask("Flotilla Helper", done: false) {
                Text("Only a signed copy of Flotilla can use the helper, so this build can't install container by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var localNetworkTask: some View {
        let state = localNetwork.state
        let done: Bool? = switch state {
        case .allowed: true
        case .asking: nil
        case .notAsked, .denied, .unconfirmed: false
        }
        return setupTask("Local Network", done: done) {
            Text("Allow Local Network so an admin Mac can find and manage this host, and so published container "
                 + "ports can accept connections.")
                .font(.callout)
            switch state {
            case .notAsked:
                Text("macOS asks once. Choose Request Access, then Allow.")
                    .font(.callout).foregroundStyle(.secondary)
            case .asking:
                Text("Waiting for your answer…").font(.callout).foregroundStyle(.secondary)
            case .allowed:
                Text("Allowed.").font(.callout).foregroundStyle(.secondary)
            case .denied, .unconfirmed:
                Text(state == .denied
                     ? "Not allowed. Switch on Flotilla in System Settings ▸ Privacy & Security ▸ Local Network."
                     : "Flotilla couldn't confirm it yet. If macOS didn't ask, check System Settings ▸ Privacy & "
                        + "Security ▸ Local Network.")
                    .font(.callout).foregroundStyle(Theme.warning)
                HStack {
                    Button("Open Local Network Settings") { SystemSettingsLink.localNetwork() }
                    Button("Check Again") { localNetwork.start() }
                }
            }
        }
    }

    /// Saves the host role, which starts the listener, which is what makes macOS ask; and watches
    /// for the answer.
    private func requestLocalNetwork() {
        saveRole(.host)
        localNetwork.start()
    }

    // MARK: 5 · Online checks

    private var onlineChecksPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Online Checks",
                    "Flotilla reaches the internet by itself for these, and nothing else. Each is separate.")
            ForEach(context.onlineChecks, id: \.self) { check in
                let locked = store.isLocked(keyNamed: check.settingName)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(check.title, isOn: Binding(get: { onlineChecks[check] ?? true },
                                                      set: { onlineChecks[check] = $0 }))
                        .toggleStyle(.checkbox)
                        .disabled(locked)
                    Group {
                        Text(check.detail)
                        Text("Contacts: \(check.contacts.joined(separator: ", "))")
                        if locked { Text("Set by your organisation.") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 20)
                }
            }
            if role == .host {
                Text("A host is updated by its admin Mac, so it has no update check of its own.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Finish

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("You're Set Up", "Here's where this Mac stands. Overview has a checklist for what's next.")
            VStack(spacing: 0) {
                summaryRow("Role", role.title, ok: true)
                summaryRow("Appearance", "\(appearanceTitle) · \(model.themeChoice.light.title) and "
                           + "\(model.themeChoice.dark.title)", ok: true)
                summaryRow("container", runtimeSummary.text, ok: runtimeSummary.ok)
                summaryRow("Greta", gretaSummary.text, ok: gretaSummary.ok)
                if role == .host {
                    summaryRow("Flotilla Helper", helperSummary.text, ok: helperSummary.ok)
                    summaryRow("Local Network", localNetworkSummary.text, ok: localNetworkSummary.ok)
                }
                summaryRow("Online checks", onlineSummary, ok: true, last: true)
            }
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            Label("Flotilla's status is also in the menu bar, at the top of the screen.", systemImage: "menubar.rectangle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ title: String, _ value: String, ok: Bool?, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    switch ok {
                    case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.online)
                    case false?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warning)
                    case nil: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16)
                Text(title).frame(width: 120, alignment: .leading)
                Text(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if !last { Divider().padding(.leading, 38) }
        }
        .accessibilityElement(children: .combine)
    }

    private var appearanceTitle: String {
        switch appearance {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var runtimeSummary: (text: String, ok: Bool?) {
        if let setup = model.runtimeSetup {
            if case .failed = setup.phase { return ("Not installed — Overview offers it again", false) }
            return (RuntimeBanner.setupTitle(setup), nil)
        }
        switch model.preflight {
        case nil: return ("Checking…", nil)
        case .ok?: return ("Ready", true)
        case .missing?, .tooOld?:
            return role == .host ? ("Installed by the helper once it's on", false)
                                 : ("Not installed — Overview offers it", false)
        default: return ("Installed — Overview says what it needs", false)
        }
    }

    private var gretaSummary: (text: String, ok: Bool?) {
        guard store[SettingsKeys.gretaEnabled] else { return ("Off — turn her on in Settings", nil) }
        return (greta.isAvailable ? "On and ready" : "On — \(greta.summary.lowercased())", greta.isAvailable)
    }

    private var helperSummary: (text: String, ok: Bool?) {
        switch helper {
        case .enabled: ("On", true)
        case .awaitingApproval: ("Waiting for your approval in Login Items", false)
        case .notInstalled: ("Off — Settings ▸ Advanced", nil)
        case .unavailable: ("Not available in this build", nil)
        }
    }

    private var localNetworkSummary: (text: String, ok: Bool?) {
        switch localNetwork.state {
        case .allowed: ("Allowed", true)
        case .asking: ("Waiting for your answer", nil)
        case .denied: ("Not allowed — System Settings ▸ Privacy & Security ▸ Local Network", false)
        case .unconfirmed, .notAsked: ("Not confirmed yet", false)
        }
    }

    private var onlineSummary: String {
        let values = store.effectiveValues()
        let on = context.onlineChecks.filter { values[$0.settingName] == .bool(true) }
        if on.isEmpty { return "None" }
        return on.map { $0 == .appUpdates ? "Flotilla updates" : "suggestions" }
            .joined(separator: " and ").capitalizedFirst + ", daily"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if flow.canGoBack {
                Button("Back") { flow.goBack() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if showsNotNow {
                Button("Not now") { notNow() }
            }
            Button(continueTitle) { proceed() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    /// On a host's Prepare step the first press is Request Access: Iris's pre-alert has one button,
    /// and macOS's own alert follows it. Not now waits until it has been asked, because a host has to
    /// be asked either way.
    private var asksLocalNetworkFirst: Bool {
        flow.step == .prepare && role == .host && localNetwork.state == .notAsked
    }

    private var showsNotNow: Bool { context.offersNotNow(on: flow.step) && !asksLocalNetworkFirst }

    private var continueTitle: String {
        if asksLocalNetworkFirst { return "Request Access" }
        return flow.isFinished ? "Start Using Flotilla" : "Continue"
    }

    private func proceed() {
        switch flow.step {
        case .welcome:
            // Admin is saved now: it stops a listener a re-run might find running. Host waits for
            // Prepare, where Local Network is explained before macOS asks.
            if role == .client { saveRole(.client) }
            if role == .host, !store.isLocked(SettingsKeys.launchAtLogin) {
                try? store.set(launchAtLogin, for: SettingsKeys.launchAtLogin)
            }
        case .appearance:
            break    // themes are saved as they're picked; the appearance at Finish
        case .greta:
            saveGreta(turnOnGreta)
        case .prepare:
            if asksLocalNetworkFirst { requestLocalNetwork(); return }
            prepareThisMac(installing: true)
        case .onlineChecks:
            for check in context.onlineChecks where !store.isLocked(keyNamed: check.settingName) {
                try? store.setRaw(.bool(onlineChecks[check] ?? true), forKeyNamed: check.settingName)
            }
        case .finish:
            finish()
            return
        }
        flow.advance()
    }

    private func notNow() {
        switch flow.step {
        case .greta: saveGreta(false)
        case .prepare: prepareThisMac(installing: false)
        default: break
        }
        flow.advance()
    }

    private func saveRole(_ mode: RunMode) {
        guard !modeLocked, store[SettingsKeys.mode] != mode else { return }
        do { try store.set(mode, for: SettingsKeys.mode) } catch {
            model.actionError = "Couldn't save the role: \(error)"
        }
    }

    private func saveGreta(_ on: Bool) {
        guard !store.isLocked(SettingsKeys.gretaEnabled) else { return }
        try? store.set(on, for: SettingsKeys.gretaEnabled)
    }

    /// Leaving Prepare: a host is saved as a host whichever button was pressed; the rest happens only
    /// on Continue with its box ticked.
    private func prepareThisMac(installing: Bool) {
        if role == .host {
            if localNetwork.state == .notAsked { requestLocalNetwork() }
            guard installing, turnOnHelper, helper == .notInstalled else { return }
            do { try PrivilegedHelper.install() } catch {
                // Registration that waits for approval throws and still registers (measured 7
                // October, `HelperSettingsSection`): only a status that didn't move is a failure.
                if PrivilegedHelper.status == .notInstalled {
                    model.actionError = "Couldn't install the Flotilla Helper: \(error.localizedDescription)"
                }
            }
            helper = PrivilegedHelper.status
            if helper == .awaitingApproval { PrivilegedHelper.openLoginItems() }
        } else if installing, installContainer, model.needsContainerInstall, model.runtimeSetup == nil {
            Task { await model.installContainerInteractively() }
        }
    }

    /// Saves the appearance — which is what marks setup complete — and hands over to Overview, whose
    /// Get started card is now the checklist for this role.
    private func finish() {
        if !appearanceLocked { model.chooseAppearance(appearance) }
        model.appearancePreview = nil
        UserDefaults.standard.set(false, forKey: OverviewView.getStartedDismissedKey)
        model.requestSection(.overview)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        dismissWindow(id: Self.windowID)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A bullet with its symbol in a fixed column, so wrapped lines align under the text.
private struct SetupBulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(Theme.info).frame(width: 16)
            configuration.title
        }
    }
}

/// The Appearance step's themes: the same drawn sketches as Settings (`ThemeSketch`, from
/// `ThemePalette`, so a sketch can't disagree with the window), at 80% so four fit across the
/// assistant's page. Picking one saves it at once, as in Settings, and the step list down the left
/// repaints in its bar colour.
private struct SetupThemeGrid: View {
    let appearance: ThemePickerRow.Appearance
    let model: AppModel

    private static let scale: CGFloat = 0.8
    private static var cell: CGSize {
        CGSize(width: ThemeSketch.size.width * scale, height: ThemeSketch.size.height * scale)
    }

    private struct Option: Identifiable {
        let id: String, title: String, palette: ThemePalette, selected: Bool, choose: () -> Void
    }

    private var store: SettingsStore { model.settingsStore }
    private var isDark: Bool { appearance == .dark }

    private var locked: Bool {
        store.isLocked(keyNamed: isDark ? SettingsKeys.darkTheme.name : SettingsKeys.lightTheme.name)
    }

    private var options: [Option] {
        if isDark {
            DarkTheme.allCases.map { theme in
                Option(id: theme.rawValue, title: theme.title, palette: theme.palette,
                       selected: theme == model.themeChoice.dark,
                       choose: { try? store.set(theme, for: SettingsKeys.darkTheme) })
            }
        } else {
            LightTheme.allCases.map { theme in
                Option(id: theme.rawValue, title: theme.title, palette: theme.palette,
                       selected: theme == model.themeChoice.light,
                       choose: { try? store.set(theme, for: SettingsKeys.lightTheme) })
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isDark ? "Dark theme" : "Light theme").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell.width), spacing: 10, alignment: .topLeading),
                                     count: 4),
                      alignment: .leading, spacing: 8) {
                ForEach(options) { option in
                    Button(action: option.choose) {
                        VStack(alignment: .leading, spacing: 3) {
                            ThemeSketch(palette: option.palette, isDark: isDark)
                                .scaleEffect(Self.scale, anchor: .topLeading)
                                .frame(width: Self.cell.width, height: Self.cell.height, alignment: .topLeading)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(option.selected ? AnyShapeStyle(Color.accentColor)
                                                                      : AnyShapeStyle(.separator),
                                                      lineWidth: option.selected ? 2.5 : 1)
                                }
                            Text(option.title)
                                .font(.caption)
                                .fontWeight(option.selected ? .semibold : .regular)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title) \(isDark ? "dark" : "light") theme")
                    .accessibilityAddTraits(option.selected ? [.isSelected, .isButton] : .isButton)
                }
            }
            .disabled(locked)
            if locked { Text("Set by your organisation.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// System Settings panes the assistant points at. Both URLs are undocumented, so each falls back to
/// System Settings itself, and the screen always names the pane in words as well.
enum SystemSettingsLink {
    static func appleIntelligence() {
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }

    static func localNetwork() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    private static func open(_ pane: String) {
        if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        if let settings = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(settings) }
    }
}
