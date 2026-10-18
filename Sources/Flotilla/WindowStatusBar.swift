import SwiftUI
import FlotillaCore

/// Window chrome, outside the navigation split: forms and the sidebar rail cannot move it.
struct WindowStatusBar: View {
    let model: AppModel
    @ObservedObject private var updater: AppUpdater
    @Environment(\.openURL) private var openURL

    init(model: AppModel) {
        self.model = model
        self.updater = model.updater
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        HStack(spacing: 12) {
            RuntimeStatusBand(model: model, railed: false, compact: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            versionMenu
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var versionMenu: some View {
        Menu {
            SwiftUI.Section("Flotilla") {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Text(lastChecked(updater.lastChecked)).disabled(true)
                updateChannelMenu
                Toggle("Automatically check", isOn: Binding(
                    get: { updater.checksAutomatically },
                    set: { try? model.settingsStore.set($0, for: SettingsKeys.automaticUpdateChecks) }
                ))
                .disabled(!updater.isRunning || model.settingsStore.isLocked(SettingsKeys.automaticUpdateChecks))
                Button("Release Notes") { openURL(ExternalLinks.flotillaReleases) }
                if !updater.isRunning {
                    Text(AppUpdater.isConfigured ? "Updated by your admin Mac" : "A development build")
                        .disabled(true)
                }
            }
            SwiftUI.Section("Suggestions library") {
                Text("Version \(model.suggestionLibrary.version)").disabled(true)
                Text(lastChecked(model.libraryUpdater.lastChecked)).disabled(true)
                Button("Check Now") { Task { await model.checkSuggestionLibrary() } }
                    .disabled(model.libraryUpdater.checking)
            }
        } label: {
            Text("v\(version)")
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(height: 23)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Flotilla version \(version)")
        .accessibilityHint("Opens the software update menu")
        .help("Version and software updates")
    }

    @ViewBuilder
    private var updateChannelMenu: some View {
        let channel = model.settingsStore[SettingsKeys.updateChannel]
        let title = channel == .stable ? "Stable" : "Pre-release"
        Text("Channel: \(title)")
            .accessibilityLabel("Update channel, \(title)")
        if model.settingsStore.isLocked(SettingsKeys.updateChannel) {
            Text("Set by your organisation")
        } else {
            Menu("Switch Channel") {
                Picker("Update channel", selection: Binding(
                    get: { model.settingsStore[SettingsKeys.updateChannel] },
                    set: { try? model.settingsStore.set($0, for: SettingsKeys.updateChannel) }
                )) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Pre-release").tag(UpdateChannel.prerelease)
                }
                .pickerStyle(.inline)
            }
        }
    }

    private func lastChecked(_ date: Date?) -> String {
        guard let date else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked: \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}
