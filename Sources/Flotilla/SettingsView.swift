import SwiftUI
import FlotillaCore

/// One labelled row bound to a single `SettingsKey`. Handles the two-tier model uniformly:
/// a locked key shows a padlock, a "Managed by your organization" note, and a disabled
/// control; everything else — including a `defaults`-seeded value the user may still
/// change — stays editable. `key.summary` is the registry's own description, so this
/// never invents wording that could drift from the declared key.
private struct SettingRow<V: SettingRepresentable, Control: View>: View {
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(locked ? "Managed by your organization." : key.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if key.requiresRestart && !locked {
                    Text("Requires a restart to take effect.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
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
            .disabled(locked)
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

    var body: some View {
        Form {
            SwiftUI.Section("Startup & Appearance") {
                SettingRow(store: store, key: SettingsKeys.launchAtLogin, title: "Launch at login") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.presentation, title: "Show Flotilla in") { binding in
                    Picker("", selection: binding) {
                        ForEach(Array(AppPresentation.allCases), id: \.rawValue) { presentation in
                            Text(Self.title(for: presentation)).tag(presentation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                AppearanceRow(store: store)
                SettingRow(store: store, key: SettingsKeys.confirmDestructiveActions, title: "Confirm destructive actions") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.confirmBulkActions, title: "Confirm bulk actions") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
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
                                Text("Always on — \(category.summary)")
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

            SwiftUI.Section("The container CLI") {
                SettingRow(store: store, key: SettingsKeys.containerBinaryPath, title: "Binary path") { binding in
                    TextField("", text: binding).textFieldStyle(.roundedBorder).frame(minWidth: 220)
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

            SwiftUI.Section("Defaults for new containers") {
                SettingRow(store: store, key: SettingsKeys.defaultContainerCPUs, title: "CPUs") { binding in
                    Stepper(value: binding, in: 1...32) { Text("\(binding.wrappedValue)") }
                }
                SettingRow(store: store, key: SettingsKeys.defaultContainerMemoryMB, title: "Memory") { binding in
                    Stepper(value: binding, in: 128...131_072, step: 128) { Text("\(binding.wrappedValue) MB") }
                }
                SettingRow(store: store, key: SettingsKeys.defaultRegistryDomain, title: "Default registry") { binding in
                    TextField("", text: binding).textFieldStyle(.roundedBorder).frame(minWidth: 180)
                }
            }

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

            SwiftUI.Section("Host mode") {
                SettingRow(store: store, key: SettingsKeys.mode, title: "Mode") { binding in
                    Picker("", selection: binding) {
                        ForEach(Array(RunMode.allCases), id: \.rawValue) { mode in
                            Text(Self.title(for: mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(store: store, key: SettingsKeys.hostListenPort, title: "Listen port") { binding in
                    Stepper(value: binding, in: 1...65_535) { Text("\(binding.wrappedValue)") }
                }
                SettingRow(store: store, key: SettingsKeys.bonjourEnabled, title: "Advertise via Bonjour") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.identityKeychainLabel, title: "Identity Keychain label") { binding in
                    TextField("", text: binding).textFieldStyle(.roundedBorder).frame(minWidth: 200)
                }
            }

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

            SwiftUI.Section("Diagnostics") {
                SettingRow(store: store, key: SettingsKeys.diagnosticsEnabled, title: "Keep a local error log") { binding in
                    Toggle("", isOn: binding).labelsHidden()
                }
                SettingRow(store: store, key: SettingsKeys.diagnosticsErrorLogCap, title: "Error log cap") { binding in
                    Stepper(value: binding, in: 10...5_000, step: 10) { Text("\(binding.wrappedValue)") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private static func title(for presentation: AppPresentation) -> String {
        switch presentation {
        case .menuBar: "Menu Bar"
        case .dock: "Dock"
        case .both: "Both"
        }
    }

    private static func title(for policy: ServiceAutostartPolicy) -> String {
        switch policy {
        case .ask: "Ask"
        case .always: "Always"
        case .never: "Never"
        }
    }

    private static func title(for mode: RunMode) -> String {
        switch mode {
        case .client: "Client"
        case .host: "Host"
        case .both: "Both"
        }
    }

    private static func title(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable: "Stable"
        case .prerelease: "Prerelease"
        }
    }
}
