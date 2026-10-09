import SwiftUI
import FlotillaCore

/// One labelled row bound to a single `SettingsKey`. Handles the two-tier model uniformly:
/// a locked key shows a padlock, a "Managed by your organization" note, and a disabled
/// control; everything else — including a `defaults`-seeded value the user may still
/// change — stays editable. `key.summary` is the registry's own description, so this
/// never invents wording that could drift from the declared key.
struct SettingRow<V: SettingRepresentable, Control: View>: View {
    let store: SettingsStore
    let key: SettingsKey<V>
    let title: String
    let control: (Binding<V>) -> Control

    @State private var value: V

    init(store: SettingsStore, key: SettingsKey<V>, title: String,
         @ViewBuilder control: @escaping (Binding<V>) -> Control) {
        self.store = store
        self.key = key
        self.title = title
        self.control = control
        _value = State(initialValue: store[key])
    }

    private var locked: Bool { store.isLocked(key) }

    /// Why this control does nothing yet, or nil when it works. See `SettingAvailability` — the
    /// audit's largest finding was a whole class of settings that persisted and changed nothing, and
    /// the fix is that the row itself has to say so.
    private var unbuiltReason: String? { key.availability.unbuiltReason }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .foregroundStyle(unbuiltReason == nil ? .primary : .secondary)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if unbuiltReason != nil {
                        Text("Not yet available")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                // Markdown, so a summary's `container ls` renders as code rather than as
                // backticks: a `String` reaches `Text` verbatim.
                Text(LocalizedStringKey(locked ? "Managed by your organization." : key.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let unbuiltReason {
                    Text(unbuiltReason)
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
                // Only meaningful for a setting that takes effect at all.
                if key.requiresRestart && !locked && unbuiltReason == nil {
                    Text("Requires a restart to take effect.")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            control(Binding(
                get: { value },
                set: { newValue in
                    value = newValue
                    try? store.set(newValue, for: key)
                }
            ))
            // Disabled when it is managed **or** when nothing reads it. A live control over an
            // unbuilt feature is the exact shape the audit objected to.
            .disabled(locked || unbuiltReason != nil)
        }
        .padding(.vertical, 4)
    }
}

/// Launch at login, showing what macOS actually did rather than only what was asked.
///
/// Its own view rather than a `SettingRow` for the same reason `AppearanceRow` is: the caption has
/// to be live. `SettingRow` prints `key.summary`, a fixed sentence from the registry — fine for a
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

    private var captionStyle: HierarchicalShapeStyle { .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Launch at login")
                    if locked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(model.loginItemFailure == nil ? AnyShapeStyle(captionStyle)
                                                                  : AnyShapeStyle(Theme.warning))
                if model.loginItemStatus == .awaitingApproval {
                    Text("Open System Settings ▸ General ▸ Login Items to approve it.")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { enabled },
                                     set: { newValue in
                                         enabled = newValue
                                         try? store.set(newValue, for: SettingsKeys.launchAtLogin)
                                     }))
                .labelsHidden()
                .disabled(locked || model.loginItemStatus == .unavailable)
        }
        .padding(.vertical, 4)
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Appearance")
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(locked
                     ? "Managed by your organization."
                     : "Chosen during first run. Auto follows the system appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            .disabled(locked)
        }
        .padding(.vertical, 4)
    }
}

/// The settings section root view. Renders the whole `SettingsRegistry` grouped by topic,
/// honouring the two-tier managed model end to end via `SettingRow`/`AppearanceRow`.
///
/// `peerAllowlist` and `trustAnchorFingerprints` are declared in the registry but not
/// rendered here: they are SHA-256 fingerprint lists with no meaningful editor until the
/// Phase 2 pairing flow exists to populate them, and a raw string-array field would be a
/// control that does nothing useful yet.
struct SettingsView: View {
    let model: AppModel

    private var store: SettingsStore { model.settingsStore }
    @State private var pendingReset: ResetAction?
    /// What the last settings import did, for its report — `nil` when none is showing.
    @State private var importReport: String?

    /// Which pane is showing.
    @State private var tab: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable, Hashable {
        // Tags sits between Resources and Updates: it is about the things the app manages,
        // like Resources, rather than about the app itself.
        // No `registries`: it is a sidebar section under Images since 5 October.
        case general, resources, tags, hostMode, updates, advanced
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .resources: "Resources"
            case .tags: "Tags"
            case .hostMode: "Host Mode"
            case .updates: "Updates"
            case .advanced: "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .resources: "cpu"
            case .tags: "tag"
            case .hostMode: "antenna.radiowaves.left.and.right"
            case .updates: "arrow.down.circle"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    /// Separate panes rather than one scroll, per `research/review/mockups/settings.html`.
    ///
    /// The content was already all here; it was stacked into a single `Form` eleven sections
    /// long, so finding anything meant scrolling past everything. Panes are how macOS's own
    /// Settings works and how the mockup draws it, and the grouping is the mockup's — the
    /// value is not the tab bar, it is that "where would I look for this" now has an answer.
    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            pane(for: tab)
        }
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
                    reset.perform(model)
                    pendingReset = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: {
            Text(pendingReset?.message ?? "")
        }
    }

    /// The mockup's tab strip, to its own numbers.
    ///
    /// Hand-built rather than a `TabView`, and that is not preference. macOS renders a
    /// `TabView`'s top bar as titles ONLY — it drops the icon whether you pass `systemImage:`
    /// or supply a `Label` yourself, both of which were tried. So the way to get the mockup's
    /// strip is to draw it.
    ///
    /// Transcribed from `.settings-tabs` in `assets/mac.css` rather than eyeballed, because
    /// eyeballing the wordmark is how it came out wrong: the icon sits **above** the label
    /// (`flex-direction: column`), each chip is a fixed 74pt wide so the strip does not
    /// re-space itself as titles change length, and the whole strip is centred
    /// (`margin: 0 auto`) rather than left-aligned.
    ///
    /// Keyboard access is kept: these are real `Button`s, so Tab and VoiceOver reach every
    /// pane. The tab bar is the only thing custom here — each pane is still a stock grouped
    /// `Form`.
    private var tabBar: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            ForEach(Tab.allCases) { candidate in
                let selected = candidate == tab
                Button {
                    tab = candidate
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: candidate.systemImage)
                            .font(.system(size: 16))
                            .frame(height: 19)
                        Text(candidate.title)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    }
                    .frame(width: 74)
                    .padding(.top, 4)
                    .padding(.bottom, 3)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .background(selected ? Theme.accentTint : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    @ViewBuilder
    private func pane(for tab: Tab) -> some View {
        Form {
            switch tab {
            case .general: generalPane
            case .resources: resourcesPane
            case .tags: TagManagerPane(model: model, store: model.tags)
            case .hostMode: HostModePane(model: model)
            case .updates: updatesPane
            case .advanced: advancedPane
            }
        }
        .formStyle(.grouped)
        // Lets the app's own content wash through. A grouped `Form` paints an opaque background
        // of its own, so Settings was the one screen in the app that did not sit on the honeydew
        // every other section sits on — white page, grey cards, against honeydew page and white
        // cards everywhere else.
        //
        // The cards themselves stay SwiftUI's: `.listRowBackground(Theme.raisedSurface)` was
        // tried and **measured to do nothing** on a macOS grouped `Form` — the sampled card
        // colour was identical with and without it — so it is not left in as a modifier that
        // looks like it is doing something. The rows read very slightly recessed against the
        // page rather than raised, which is SwiftUI's relationship and not one this can change
        // from here.
        .scrollContentBackground(.hidden)
    }

    // MARK: General

    @ViewBuilder
    private var generalPane: some View {
            SwiftUI.Section("Startup & Behaviour") {
                LaunchAtLoginRow(store: store, model: model)
                SettingRow(store: store, key: SettingsKeys.showDockIcon, title: "Show Dock icon") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.confirmDestructiveActions, title: "Confirm destructive actions") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.keepAwakeWhileContainersRun,
                           title: "Keep this Mac awake while containers run") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
            }

            // Everything about how the app looks, together: the mode, then the pair of themes the
            // mode switches between. `design/THEMES.md`.
            SwiftUI.Section("Appearance") {
                AppearanceRow(store: store)
                ThemePickerRow(appearance: .light, model: model)
                ThemePickerRow(appearance: .dark, model: model)
            }

            SwiftUI.Section("Refreshing") {
                SettingRow(store: store, key: SettingsKeys.pollIntervalSeconds, title: "Refresh containers every") { binding in
                    Stepper(value: binding, in: 0...300) { Text("\(binding.wrappedValue) s") }
                }
                SettingRow(store: store, key: SettingsKeys.statsPollIntervalSeconds, title: "Refresh stats every") { binding in
                    Stepper(value: binding, in: 0...300) { Text("\(binding.wrappedValue) s") }
                }
            }

            SwiftUI.Section("Notifications") {
                ForEach(NotificationCategory.allCases) { category in
                    if category.isMandatory {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(category.title)
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(LocalizedStringKey("Always on — " + category.summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: .constant(true)).labelsHidden().disabled(true)
                        }
                        .padding(.vertical, 4)
                    } else {
                        SettingRow(store: store, key: SettingsKeys.notification(category), title: category.title) { binding in
                            Toggle("", isOn: binding).labelsHidden()
                        }
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
            SwiftUI.Section("The container CLI") {
                SettingRow(store: store, key: SettingsKeys.containerBinaryPath, title: "Binary path") { binding in
                    // `prompt:`, not the title argument. `TextField("Detect automatically", …)`
                    // reads like a placeholder and is not one: the first argument is the field's
                    // **title**, which a grouped `Form` draws as a visible label. So the row said
                    // "Binary path … Detect automatically [empty box]" — a stray label that looked
                    // like a second setting, beside a field with no hint in it at all. The
                    // neighbouring registry field sidesteps this with an empty title and loses the
                    // hint instead; `prompt:` is the one that puts the words where they belong.
                    TextField("", text: binding, prompt: Text("Detect automatically"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(minWidth: 220)
                }
                // Says which path is actually in force. An override that silently fell back to
                // detection would look accepted, which is the failure mode this whole wave is about.
                HStack {
                    Text(model.containerExecutableExplanation)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                SettingRow(store: store, key: SettingsKeys.autoStartContainerService, title: "If the API service isn't running") { binding in
                    Picker("", selection: binding) {
                        ForEach(Array(ServiceAutostartPolicy.allCases), id: \.rawValue) { policy in
                            Text(Self.title(for: policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
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
        SwiftUI.Section("Settings file") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy these settings to another Mac")
                    Text("Writes only what you have changed from the defaults. Nothing secret and no "
                         + "host trust is ever included.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Export Settings\u{2026}", action: exportSettings)
                Button("Import Settings\u{2026}", action: importSettings)
            }
            .padding(.vertical, 2)
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
            SwiftUI.Section("Defaults for new containers") {
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
            SwiftUI.Section("Logs") {
                SettingRow(store: store, key: SettingsKeys.logTailLines, title: "Lines requested when opening logs") { binding in
                    Stepper(value: binding, in: 0...5_000, step: 50) { Text("\(binding.wrappedValue)") }
                }
                SettingRow(store: store, key: SettingsKeys.logBufferLineCap, title: "Log buffer cap per container") { binding in
                    Stepper(value: binding, in: 100...50_000, step: 100) { Text("\(binding.wrappedValue)") }
                }
                SettingRow(store: store, key: SettingsKeys.logShowTimestamps, title: "Show timestamps") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
            }

    }

    // MARK: Updates

    @ViewBuilder
    private var updatesPane: some View {
            SwiftUI.Section("Updates") {
                SettingRow(store: store, key: SettingsKeys.automaticUpdateChecks, title: "Automatically check for updates") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.automaticallyDownloadUpdates, title: "Automatically download updates") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.updateCheckIntervalSeconds, title: "Check every") { binding in
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

    }

    @ViewBuilder
    private var diagnosticsSection: some View {
            SwiftUI.Section("Diagnostics") {
                SettingRow(store: store, key: SettingsKeys.diagnosticsEnabled, title: "Keep a local error log") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.diagnosticsErrorLogCap, title: "Error log cap") { binding in
                    Stepper(value: binding, in: 10...5_000, step: 10) { Text("\(binding.wrappedValue)") }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Support bundle")
                        Text("Assemble a redacted diagnostic bundle. You see every file before "
                             + "it is saved, and nothing is uploaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    // The Help menu and this button share model-owned presentation state, so
                    // both routes open the same audited preview-and-save flow.
                    Button("Create…") { model.requestSupportBundle() }
                }
                .padding(.vertical, 2)

                HStack {
                    Text("About Flotilla")
                    Spacer()
                    Button("Show") { model.showingAbout = true }
                }
            }

    }

    /// Preferences and window layout reset independently.
    ///
    /// Someone whose window is stranded on a display they no longer have should be able to
    /// recover it without losing every preference, and vice versa. One "Reset everything"
    /// button is the version of this that nobody dares press.
    ///
    /// Each confirmation names what it will do **and what it will not touch**, because the
    /// fear that stops people using a reset is not knowing where it stops. The scope note
    /// below states the thing that matters most: none of these can delete a container, an
    /// image or a volume. `FEATURES.md` is explicit that a settings reset must never offer to.
    private var resetSection: some View {
        SwiftUI.Section("Reset") {
            ForEach(ResetAction.allCases) { action in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        Text(action.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Reset") { pendingReset = action }
                }
                .padding(.vertical, 2)
            }

            Label(
                LocalizedStringKey("None of these touch your containers, images or volumes — "
                    + "those belong to the `container` runtime, not to Flotilla."),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    enum ResetAction: String, CaseIterable, Identifiable {
        case preferences, windowLayout
        var id: Self { self }

        var title: String {
            switch self {
            case .preferences: "Reset preferences"
            case .windowLayout: "Reset window layout"
            }
        }

        var summary: String {
            switch self {
            case .preferences:
                "Every setting back to its default. Your window position is left alone."
            case .windowLayout:
                "Forgets window size, position and the sidebar width. Takes effect at next launch."
            }
        }

        var confirmLabel: String {
            switch self {
            case .preferences: "Reset Preferences"
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
            case .windowLayout:
                "Forgets the window's size and position and the sidebar width. Useful if the "
                    + "window has ended up off-screen.\n\nTakes effect at next launch, because "
                    + "an open window saves its position again when it closes. No preferences "
                    + "or data change."
            }
        }

        @MainActor func perform(_ model: AppModel) {
            switch self {
            case .preferences: model.resetPreferences()
            case .windowLayout: model.resetWindowLayout()
            }
        }
    }


    private static func title(for policy: ServiceAutostartPolicy) -> String {
        switch policy {
        case .ask: "Ask"
        case .always: "Always"
        case .never: "Never"
        }
    }

    private static func title(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable: "Stable"
        case .prerelease: "Prerelease"
        }
    }
}
