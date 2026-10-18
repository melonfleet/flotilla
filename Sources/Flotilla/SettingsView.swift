import SwiftUI
import FlotillaCore

/// One labelled row bound to a single `SettingsKey`, drawn as "Label: [control]" with the
/// registry's own explanation under it. Handles the two-tier model uniformly: a locked key shows a
/// padlock, a "Managed by your organization" note, and a disabled control; everything else —
/// including a `defaults`-seeded value the user may still change — stays editable. `key.summary`
/// is the registry's own description, so this never invents wording that could drift from the
/// declared key.
///
/// A checkbox is `SettingToggle`; this is for everything else (pop-ups, steppers, fields).
struct SettingRow<V: SettingRepresentable, Control: View>: View {
    let store: SettingsStore
    let key: SettingsKey<V>
    let title: String
    /// Whether the label takes a trailing colon. Off for a label that reads on into its control
    /// ("Refresh containers every 5 s").
    let colon: Bool
    let control: (Binding<V>) -> Control

    @State private var value: V

    init(store: SettingsStore, key: SettingsKey<V>, title: String, colon: Bool = true,
         @ViewBuilder control: @escaping (Binding<V>) -> Control) {
        self.store = store
        self.key = key
        self.title = title
        self.colon = colon
        self.control = control
        _value = State(initialValue: store[key])
    }

    private var locked: Bool { store.isLocked(key) }

    /// Why this control does nothing yet, or nil when it works. See `SettingAvailability` — the
    /// audit's largest finding was a whole class of settings that persisted and changed nothing, and
    /// the fix is that the row itself has to say so.
    private var unbuiltReason: String? { key.availability.unbuiltReason }

    var body: some View {
        SettingInline(label: colon ? title + ":" : title,
                      help: locked ? "Managed by your organization." : key.summary,
                      lockNote: locked ? "Managed by your organization" : nil,
                      unbuiltReason: unbuiltReason,
                      // Only meaningful for a setting that takes effect at all.
                      requiresRestart: key.requiresRestart && !locked && unbuiltReason == nil,
                      // Disabled when it is managed **or** when nothing reads it (`SettingInline`
                      // adds the second). A live control over an unbuilt feature is the exact
                      // shape the audit objected to.
                      disabled: locked) {
            control(Binding(
                get: { value },
                set: { newValue in
                    value = newValue
                    try? store.set(newValue, for: key)
                }
            ))
            // The controls are `Toggle("")`, `Picker("")`: the title beside them is their name.
            .accessibilityLabel(title)
        }
    }
}

/// A checkbox setting: the box, the title, the registry's explanation in grey under it. Locking and
/// availability behave exactly as `SettingRow`'s do.
struct SettingToggle: View {
    let store: SettingsStore
    let key: SettingsKey<Bool>
    let title: String

    @State private var value: Bool

    init(store: SettingsStore, key: SettingsKey<Bool>, title: String) {
        self.store = store
        self.key = key
        self.title = title
        _value = State(initialValue: store[key])
    }

    private var locked: Bool { store.isLocked(key) }
    private var unbuiltReason: String? { key.availability.unbuiltReason }

    var body: some View {
        SettingCheck(title: title,
                     help: locked ? "Managed by your organization." : key.summary,
                     lockNote: locked ? "Managed by your organization" : nil,
                     unbuiltReason: unbuiltReason,
                     requiresRestart: key.requiresRestart && !locked && unbuiltReason == nil,
                     disabled: locked,
                     isOn: Binding(get: { value },
                                   set: { newValue in
                                       value = newValue
                                       try? store.set(newValue, for: key)
                                   }))
    }
}

/// Launch at login, showing what macOS actually did rather than only what was asked.
///
/// Its own view rather than a `SettingToggle` for the same reason `AppearanceRow` is: the caption has
/// to be live. `SettingToggle` prints `key.summary`, a fixed sentence from the registry — fine for a
/// preference the app fully controls, wrong for one the system can park in
/// `.requiresApproval` or refuse outright. A toggle that reads "on" while macOS has the
/// registration switched off in System Settings is the same lie this setting used to tell by
/// having no code behind it at all.
private struct LaunchAtLoginRow: View {
    let store: SettingsStore
    let model: AppModel

    @State private var enabled: Bool

    init(store: SettingsStore, model: AppModel) {
        self.store = store
        self.model = model
        _enabled = State(initialValue: store[SettingsKeys.launchAtLogin])
    }

    private var locked: Bool { store.isLocked(SettingsKeys.launchAtLogin) }

    /// The system's word, unless there is no app bundle to register — in which case say so because
    /// this row is also visible when Flotilla is run as a bare SwiftPM executable.
    private var caption: String {
        if locked { return "Managed by your organization." }
        if let failure = model.loginItemFailure { return failure }
        return model.loginItemStatus.summary
    }

    var body: some View {
        SettingCheck(title: "Launch at login",
                     help: caption,
                     helpStyle: model.loginItemFailure == nil ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(Theme.warning),
                     lockNote: locked ? "Managed by your organization" : nil,
                     disabled: locked || model.loginItemStatus == .unavailable,
                     isOn: Binding(get: { enabled },
                                   set: { newValue in
                                       enabled = newValue
                                       try? store.set(newValue, for: SettingsKeys.launchAtLogin)
                                   })) {
            if model.loginItemStatus == .awaitingApproval {
                Text("Open System Settings ▸ General ▸ Login Items to approve it.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

/// The appearance control needs `AppearanceMode` (Light/Dark/Auto), not the stored
/// `AppearancePreference` (which also carries `notChosen`) — so it is its own small view
/// rather than a `SettingRow`, going through `SettingsStore.chooseAppearance` instead of a
/// raw `set(_:for:)`.
private struct AppearanceRow: View {
    let store: SettingsStore
    @State private var mode: AppearanceMode

    init(store: SettingsStore) {
        self.store = store
        _mode = State(initialValue: store.effectiveAppearance)
    }

    private var locked: Bool { store.isLocked(SettingsKeys.appearance) }

    var body: some View {
        SettingInline(label: "Appearance:",
                      help: locked
                          ? "Managed by your organization."
                          : "Chosen during first run. Auto follows the system appearance.",
                      lockNote: locked ? "Managed by your organization" : nil,
                      disabled: locked) {
            Picker("Appearance", selection: Binding(
                get: { mode },
                set: { newMode in
                    mode = newMode
                    try? store.chooseAppearance(newMode)
                }
            )) {
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
                Text("Auto").tag(AppearanceMode.auto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The settings section root view: a sidebar of sections and the selected section's pane, drawn in
/// the style of 1Password's Settings (the owner's reference, 18 October). It renders the whole
/// `SettingsRegistry`, honouring the two-tier managed model end to end via
/// `SettingRow`/`SettingToggle`/`AppearanceRow`.
struct SettingsView: View {
    let model: AppModel

    private var store: SettingsStore { model.settingsStore }
    @State private var pendingReset: ResetAction?
    /// Why the last reset stopped short — `nil` when none is showing.
    @State private var resetFailure: (title: String, message: String)?
    /// What the last settings import did, for its report — `nil` when none is showing.
    @State private var importReport: String?

    /// Which section is showing.
    @State private var section: Section = .general

    /// The sections, in sidebar order. Where each setting went is in `pane(for:)`.
    ///
    /// Tags sits between Resources and Notifications: it is about the things the app manages, like
    /// Resources, rather than about the app itself. No `registries`: it is a sidebar section under
    /// Images since 5 October. `Advanced` and `About` are the group below the divider.
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case general, appearance, updates, hosts, resources, tags, notifications, greta
        case advanced, about
        var id: Self { self }

        static let main: [Section] = [.general, .appearance, .updates, .hosts, .resources, .tags,
                                      .notifications, .greta]
        static let last: [Section] = [.advanced, .about]

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .updates: "Updates"
            case .hosts: "Hosts and Fleet"
            case .resources: "Resources"
            case .tags: "Tags"
            case .notifications: "Notifications"
            case .greta: "Greta"
            case .advanced: "Advanced"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .updates: "arrow.down.circle"
            case .hosts: "antenna.radiowaves.left.and.right"
            case .resources: "cpu"
            case .tags: "tag"
            case .notifications: "bell.badge"
            case .greta: "sparkles"
            case .advanced: "slider.horizontal.3"
            case .about: "info.circle"
            }
        }

        var tile: SettingsTileStyle {
            switch self {
            case .general: .green
            case .appearance: .pink
            case .updates: .teal
            case .hosts: .deepGreen
            case .resources: .yellow
            case .tags: .pale
            case .notifications: .orange
            case .greta: .pink
            case .advanced, .about: .grey
            }
        }
    }


    private var sidebarGroups: [[SettingsSidebarItem<Section>]] {
        [Section.main, Section.last].map { group in
            group.map { SettingsSidebarItem(id: $0, title: $0.title, symbol: $0.systemImage, tile: $0.tile) }
        }
    }

    /// The sidebar at a fixed width and the pane filling the rest. The pane scrolls; the sidebar is
    /// short enough not to need to, and a `List` scrolls itself if the window is very short.
    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(groups: sidebarGroups, selection: $section)
                .frame(width: 232)
            Divider()
            pane(for: section)
                // A new section starts at its top, not wherever the last one was scrolled to.
                .id(section)
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .navigationTitle("Settings")
        .sheet(isPresented: Binding(
            get: { model.showingSupportBundle },
            set: { model.showingSupportBundle = $0 }
        )) {
            SupportBundleView(model: model) { model.showingSupportBundle = false }
        }
        .sheet(isPresented: Binding(
            get: { model.showingAbout },
            set: { model.showingAbout = $0 }
        )) {
            AboutView(model: model) { model.showingAbout = false }
        }
        .confirmationDialog(
            pendingReset?.title ?? "",
            isPresented: Binding(get: { pendingReset != nil },
                                 set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            if let reset = pendingReset {
                Button(reset.confirmLabel, role: .destructive) {
                    pendingReset = nil
                    Task {
                        // Said, not swallowed: a reset that stopped short must not look like one that worked.
                        do { try await reset.perform(model) }
                        catch { resetFailure = ("Couldn\u{2019}t \(reset.title.lowercased())", "\(error)") }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: {
            Text(pendingReset?.message ?? "")
        }
        .alert(resetFailure?.title ?? "", isPresented: Binding(get: { resetFailure != nil },
                                                               set: { if !$0 { resetFailure = nil } })) {
            Button("OK") { resetFailure = nil }
        } message: {
            Text(resetFailure?.message ?? "")
        }
    }

    @ViewBuilder
    private func pane(for section: Section) -> some View {
        SettingsPane(title: section.title) {
            switch section {
            case .general: generalPane
            case .appearance: appearancePane
            case .updates: updatesPane
            case .hosts: HostModePane(model: model)
            case .resources: resourcesPane
            case .tags: TagManagerPane(model: model, store: model.tags)
            case .notifications: notificationsPane
            case .greta: gretaPane
            case .advanced: advancedPane
            case .about: SettingsAboutPane(model: model)
            }
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalPane: some View {
        SettingsGroup {
            LaunchAtLoginRow(store: store, model: model)
            SettingToggle(store: store, key: SettingsKeys.showDockIcon, title: "Show Dock icon")
            SettingToggle(store: store, key: SettingsKeys.confirmDestructiveActions,
                          title: "Confirm destructive actions")
            SettingToggle(store: store, key: SettingsKeys.keepAwakeWhileContainersRun,
                          title: "Keep this Mac awake while containers run")
        }

        SettingsGroup("Refreshing") {
            SettingRow(store: store, key: SettingsKeys.pollIntervalSeconds,
                       title: "Refresh containers every", colon: false) { binding in
                Stepper(value: binding, in: 0...300) { Text("\(binding.wrappedValue) s") }
            }
            SettingRow(store: store, key: SettingsKeys.statsPollIntervalSeconds,
                       title: "Refresh stats every", colon: false) { binding in
                Stepper(value: binding, in: 0...300) { Text("\(binding.wrappedValue) s") }
            }
        }
    }

    // MARK: Appearance

    /// Everything about how the app looks, together: the mode, then the pair of themes the
    /// mode switches between. `design/THEMES.md`.
    @ViewBuilder
    private var appearancePane: some View {
        SettingsGroup {
            AppearanceRow(store: store)
        }
        SettingsGroup("Themes") {
            ThemePickerRow(appearance: .light, model: model)
            ThemePickerRow(appearance: .dark, model: model)
        }
    }

    // MARK: Greta

    /// Greta's face used to sit with the themes, "where the owner looks for how things look", when
    /// she had no page of her own. She has one now, so it is here.
    @ViewBuilder
    private var gretaPane: some View {
        SettingsGroup {
            SettingToggle(store: store, key: SettingsKeys.gretaEnabled, title: "Turn on Greta")
            SettingsNote(verbatim: model.greta.unavailableReason.map { "Not available here: \($0)" }
                 ?? "Uses Apple's on-device model. Nothing leaves this Mac. She reads and drafts; she never runs or changes anything.")
        }
        SettingsGroup("Look") {
            SettingRow(store: store, key: SettingsKeys.gretaAvatar, title: "Greta's look") { binding in
                HStack(spacing: 6) {
                    ForEach(GretaAvatar.allCases, id: \.self) { style in
                        Button { binding.wrappedValue = style } label: {
                            GretaAvatarView(style: style, size: 30)
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(binding.wrappedValue == style ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(style.title)
                        .accessibilityLabel(style.title)
                        .accessibilityAddTraits(binding.wrappedValue == style ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: Notifications

    @ViewBuilder
    private var notificationsPane: some View {
        SettingsGroup {
            ForEach(NotificationCategory.allCases) { category in
                if category.isMandatory {
                    SettingCheck(title: category.title,
                                 help: "Always on — " + category.summary,
                                 lockNote: "Always on",
                                 disabled: true,
                                 isOn: .constant(true))
                } else {
                    SettingToggle(store: store, key: SettingsKeys.notification(category), title: category.title)
                }
            }
        }
    }

    // MARK: Advanced
    //
    // The settings you reach for when something is wrong, or when you know exactly what you
    // are changing: the CLI itself, log volumes, diagnostics and the resets.

    @ViewBuilder
    private var advancedPane: some View {
        SettingsGroup("The container CLI") {
            SettingRow(store: store, key: SettingsKeys.containerBinaryPath, title: "Binary path") { binding in
                // `prompt:`, not the title argument. `TextField("Detect automatically", …)`
                // reads like a placeholder and is not one: the first argument is the field's
                // **title**, which a form draws as a visible label. `prompt:` is the one that puts
                // the words where they belong.
                TextField("", text: binding, prompt: Text("Detect automatically"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(minWidth: 220)
            }
            // Says which path is actually in force. An override that silently fell back to
            // detection would look accepted, which is the failure mode this whole wave is about.
            SettingsNote(verbatim: model.containerExecutableExplanation)
            SettingRow(store: store, key: SettingsKeys.autoStartContainerService, title: "Start container by itself") { binding in
                Picker("", selection: binding) {
                    ForEach(Array(ServiceAutostartPolicy.allCases), id: \.rawValue) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }

        HelperSettingsSection()
        logsSection
        diagnosticsSection
        settingsFileSection
        resetSection
    }

    // MARK: Settings file (DECISIONS.md Q34)

    /// Export and import of Flotilla's own settings — a file of its own, not part of a `.flotilla`
    /// configuration (Q29 keeps those to what the runtime builds). Only what was changed from the
    /// defaults is written, and never a sensitive key; an import applies what this version knows
    /// and says what it did not.
    private var settingsFileSection: some View {
        SettingsGroup("Settings file") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Copy these settings to another Mac")
                SettingsNote("Writes only what you have changed from the defaults. Nothing secret and no "
                             + "host trust is ever included.")
                HStack {
                    Button("Export Settings\u{2026}", action: exportSettings)
                    Button("Import Settings\u{2026}", action: importSettings)
                }
            }
        }
        .alert("Settings imported", isPresented: Binding(get: { importReport != nil },
                                                          set: { if !$0 { importReport = nil } })) {
            Button("OK") { importReport = nil }
        } message: {
            Text(importReport ?? "")
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "flotilla-settings-\(stamp).json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportJSON(.userValues).write(to: url, options: .atomic)
        } catch {
            // Said, not swallowed: a save that silently did nothing looks like one that worked.
            importReport = "Couldn\u{2019}t save the settings: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a settings file exported from Flotilla"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importReport = Self.describe(try store.importJSON(Data(contentsOf: url)))
        } catch {
            importReport = "That file isn\u{2019}t a Flotilla settings export: \(error.localizedDescription)"
        }
    }

    /// The import report in sentences: what changed, then each reason something did not.
    static func describe(_ report: SettingsImportReport) -> String {
        var lines = [report.applied.isEmpty
            ? "Nothing was changed."
            : "Applied \(report.applied.count) setting\(report.applied.count == 1 ? "" : "s")."]
        if !report.skippedLocked.isEmpty {
            lines.append("Kept because your organisation sets them: " + report.skippedLocked.joined(separator: ", ") + ".")
        }
        if !report.unknown.isEmpty {
            lines.append("Not known to this version of Flotilla: " + report.unknown.joined(separator: ", ") + ".")
        }
        if !(report.typeMismatched + report.rejectedValues).isEmpty {
            lines.append("Values this version can\u{2019}t use: "
                         + (report.typeMismatched + report.rejectedValues).joined(separator: ", ") + ".")
        }
        if !report.skippedSensitive.isEmpty {
            lines.append("Refused because they are never imported from a file: "
                         + report.skippedSensitive.joined(separator: ", ") + ".")
        }
        if let version = report.schemaVersionMismatch {
            lines.append("The file is from settings version \(version); this Flotilla uses \(SettingsSchema.version).")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Resources

    @ViewBuilder
    private var resourcesPane: some View {
        SettingsGroup("Defaults for new containers") {
            SettingRow(store: store, key: SettingsKeys.defaultContainerCPUs, title: "CPUs") { binding in
                Stepper(value: binding, in: 1...32) { Text("\(binding.wrappedValue)") }
            }
            SettingRow(store: store, key: SettingsKeys.defaultContainerMemoryMB, title: "Memory") { binding in
                Stepper(value: binding, in: 128...131_072, step: 128) { Text("\(binding.wrappedValue) MB") }
            }
            // "Default registry" used to live here as a free-text field, then on a Settings ▸
            // Registries pane. It is set from the Registries section's table now (Set as
            // Default), beside the list of registries it can name.
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        SettingsGroup("Logs") {
            SettingRow(store: store, key: SettingsKeys.logTailLines, title: "Lines requested when opening logs") { binding in
                Stepper(value: binding, in: 0...5_000, step: 50) { Text("\(binding.wrappedValue)") }
            }
            SettingRow(store: store, key: SettingsKeys.logBufferLineCap, title: "Log buffer cap per container") { binding in
                Stepper(value: binding, in: 100...50_000, step: 100) { Text("\(binding.wrappedValue)") }
            }
            SettingToggle(store: store, key: SettingsKeys.logShowTimestamps, title: "Show timestamps")
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesPane: some View {
        SettingsGroup {
            SettingToggle(store: store, key: SettingsKeys.automaticUpdateChecks, title: "Automatically check for updates")
            SettingToggle(store: store, key: SettingsKeys.automaticallyDownloadUpdates, title: "Automatically download updates")
            SettingRow(store: store, key: SettingsKeys.updateCheckIntervalSeconds, title: "Check every", colon: false) { binding in
                Stepper(value: binding, in: 3_600...604_800, step: 3_600) { Text("\(binding.wrappedValue / 3_600) h") }
            }
            SettingRow(store: store, key: SettingsKeys.updateChannel, title: "Update channel") { binding in
                Picker("", selection: binding) {
                    ForEach(Array(UpdateChannel.allCases), id: \.rawValue) { channel in
                        Text(Self.title(for: channel)).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsGroup("Suggestions library") {
            SettingToggle(store: store, key: SettingsKeys.suggestionLibraryUpdates, title: "Check for new suggestions daily")
            HStack(alignment: .firstTextBaseline) {
                SettingsNote(verbatim: "Library \(model.suggestionLibrary.version), \(model.suggestionLibrary.entries.count) suggestions. \(model.libraryUpdater.status)")
                Spacer()
                Button("Check Now") { Task { await model.checkSuggestionLibrary() } }
                    .disabled(model.libraryUpdater.checking)
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        SettingsGroup("Diagnostics") {
            SettingToggle(store: store, key: SettingsKeys.diagnosticsEnabled, title: "Keep a local error log")
            SettingRow(store: store, key: SettingsKeys.diagnosticsErrorLogCap, title: "Error log cap") { binding in
                Stepper(value: binding, in: 10...5_000, step: 10) { Text("\(binding.wrappedValue)") }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Support bundle")
                SettingsNote("Assemble a redacted diagnostic bundle. You see every file before "
                             + "it is saved, and nothing is uploaded.")
                // The Help menu and this button share model-owned presentation state, so
                // both routes open the same audited preview-and-save flow.
                Button("Create…") { model.requestSupportBundle() }
            }
            // "About Flotilla ▸ Show" lived here; About is its own section now.
        }
    }

    /// Preferences, host trust and window layout reset independently.
    ///
    /// Someone whose window is stranded on a display they no longer have should be able to
    /// recover it without losing every preference, and vice versa — and neither of those should
    /// cost a day of re-pairing a fleet. One "Reset everything" button is the version of this that
    /// nobody dares press.
    ///
    /// Each confirmation names what it will do **and what it will not touch**, because the
    /// fear that stops people using a reset is not knowing where it stops. The scope note
    /// below states the thing that matters most: none of these can delete a container, an
    /// image or a volume. `FEATURES.md` is explicit that a settings reset must never offer to.
    private var resetSection: some View {
        SettingsGroup("Reset") {
            ForEach(ResetAction.allCases) { action in
                VStack(alignment: .leading, spacing: 8) {
                    Text(action.title)
                    SettingsNote(action.summary)
                    Button("Reset") { pendingReset = action }
                        .disabled(!action.isAvailable(model))
                }
            }

            Label(
                LocalizedStringKey("None of these touch your containers, images or volumes — "
                    + "those belong to the `container` runtime, not to Flotilla."),
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    enum ResetAction: String, CaseIterable, Identifiable {
        case preferences, hostsAndTrust, windowLayout
        var id: Self { self }

        var title: String {
            switch self {
            case .preferences: "Reset preferences"
            case .hostsAndTrust: "Forget all hosts and trust"
            case .windowLayout: "Reset window layout"
            }
        }

        var summary: String {
            switch self {
            case .preferences:
                "Every setting back to its default. Your window position is left alone."
            case .hostsAndTrust:
                "Every Mac you have paired with is forgotten, and this Mac is given a new identity."
            case .windowLayout:
                "Forgets window size, position and the sidebar width. Takes effect at next launch."
            }
        }

        var confirmLabel: String {
            switch self {
            case .preferences: "Reset Preferences"
            case .hostsAndTrust: "Forget Hosts and Trust"
            case .windowLayout: "Reset Layout"
            }
        }

        /// Says what survives, not just what goes. The unstated half is what makes people
        /// hesitate.
        var message: String {
            switch self {
            case .preferences:
                "Every setting returns to its default, including your appearance choice, so "
                    + "Flotilla will ask about it again next launch.\n\nYour window layout, "
                    + "your containers, images and volumes are all untouched."
            case .hostsAndTrust:
                "Every Mac you have paired with is forgotten, along with this Mac's own identity "
                    + "and your fleet enrolment key. Each has to pair again from scratch, and its "
                    + "owner has to let this Mac back in. Macs you turned away or removed stay "
                    + "blocked.\n\nYour containers, images, volumes, settings and window layout "
                    + "are all untouched."
            case .windowLayout:
                "Forgets the window's size and position and the sidebar width. Useful if the "
                    + "window has ended up off-screen.\n\nTakes effect at next launch, because "
                    + "an open window saves its position again when it closes. No preferences "
                    + "or data change."
            }
        }

        /// Only trust can fail: it deletes from the Keychain, which may refuse.
        @MainActor func perform(_ model: AppModel) async throws {
            switch self {
            case .preferences: model.resetPreferences()
            case .hostsAndTrust: try await model.forgetAllHostsAndTrust()
            case .windowLayout: model.resetWindowLayout()
            }
        }

        /// Whether there is anything to do. Preferences and a window layout always have defaults to
        /// return to; trust is the one that can be empty already, and its button is then disabled
        /// rather than missing, so it is somewhere you have seen before you need it.
        @MainActor func isAvailable(_ model: AppModel) -> Bool {
            switch self {
            case .preferences, .windowLayout: true
            case .hostsAndTrust: model.hasHostTrustToForget
            }
        }
    }


    private static func title(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable: "Stable"
        case .prerelease: "Prerelease"
        }
    }
}

/// Settings ▸ About: what version this is, where it lives, and whose work it carries.
///
/// The long page — every network destination, what is stored locally — stays the `ModalCard` About
/// (CLAUDE.md: it is a dialog you acknowledge, not a form you fill in), and is one button away. What
/// is here is what the page can state without growing a second copy of it.
private struct SettingsAboutPane: View {
    let model: AppModel

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 6) {
                Wordmark(size: 28)
                Text(AboutView.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        SettingsGroup("Links") {
            Link("Flotilla on GitHub", destination: ExternalLinks.flotilla)
            Link("Flotilla releases", destination: ExternalLinks.flotillaReleases)
            Link("Apple\u{2019}s container", destination: ExternalLinks.appleContainer)
            Link("melonfleet.dev", destination: ExternalLinks.melonfleet)
        }

        SettingsGroup("Privacy") {
            SettingsNote("No analytics, no account, no licence check. Every place Flotilla can reach "
                         + "on the network is listed on the privacy page.")
            Button("Network Destinations and Storage\u{2026}") { model.showingAbout = true }
        }

        SettingsGroup("Licences") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AboutView.licenceLines, id: \.self) { SettingsNote(verbatim: $0) }
            }
        }
    }
}
