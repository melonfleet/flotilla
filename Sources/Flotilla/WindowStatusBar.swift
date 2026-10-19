import SwiftUI
import FlotillaCore

/// Window chrome, outside the navigation split: forms and the sidebar rail cannot move it.
struct WindowStatusBar: View {
    let model: AppModel
    @ObservedObject private var updater: AppUpdater
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingContainerUpgrade = false
    @State private var upgradeFailures: [String] = []
    /// The bar's width, so the Helper item can drop its word first when the bar is narrow.
    @State private var barWidth: CGFloat = .infinity

    init(model: AppModel) {
        self.model = model
        self.updater = model.updater
    }

    /// Below this the Helper item is a dot alone. Well above where the runtime's words start to
    /// truncate, so the Helper's word is always the first thing the bar gives up.
    private static let helperWordMinimumWidth: CGFloat = 520

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        HStack(spacing: 12) {
            RuntimeStatusBand(model: model)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HelperStatusItem(model: model, showsWord: barWidth >= Self.helperWordMinimumWidth)
            if let content = UpdateBadgeContent.current(model) {
                UpdateActivityBadge(content: content)
                    .transition(.opacity)
            }
            versionMenu
                .layoutPriority(1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: UpdateBadgeContent.current(model))
        .onChange(of: UpdateBadgeContent.current(model)) { _, new in
            if let new, new.announces { AccessibilityNotification.Announcement(new.text).post() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(FleetUpdateText.containerUpgradeQuestion(model.hostsWithContainerUpgrades),
                            isPresented: $confirmingContainerUpgrade, titleVisibility: .visible) {
            let hosts = model.hostsWithContainerUpgrades
            Button(model.runningContainers(on: hosts) > 0 ? "Stop Containers and Upgrade" : "Upgrade") {
                Task {
                    let failures = await model.upgradeContainer(on: hosts)
                    if !failures.isEmpty { upgradeFailures = failures }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(FleetUpdateText.containerUpgradeMessage(model.hostsWithContainerUpgrades, model: model))
        }
        .alert("container wasn't upgraded everywhere",
               isPresented: Binding(get: { !upgradeFailures.isEmpty }, set: { if !$0 { upgradeFailures = [] } })) {
            Button("OK") { upgradeFailures = [] }
        } message: {
            Text(upgradeFailures.joined(separator: "\n"))
        }
    }

    private var versionMenu: some View {
        Menu {
            SwiftUI.Section("Flotilla") {
                let appBusy = model.updateActivity.activity.isBusy(.app)
                Button(appBusy ? "Checking…" : "Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck || appBusy)
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
            FleetUpdateMenuSection(model: model, confirmingContainerUpgrade: $confirmingContainerUpgrade)
            SwiftUI.Section("Suggestions library") {
                Text("Version \(model.suggestionLibrary.version)").disabled(true)
                Text(lastChecked(model.libraryUpdater.lastChecked)).disabled(true)
                Button(model.libraryUpdater.checking ? "Checking…" : "Check Now") {
                    Task { await model.checkSuggestionLibrary(explicit: true) }
                }
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

    private func lastChecked(_ date: Date?) -> String { UpdateText.lastChecked(date) }
}

/// The Flotilla Helper in the status bar (Q41, amended 19 October): a dot and the word "Helper",
/// opening its status and the few things to do about it. Shown on a host-only Mac too — hosts need the
/// helper most — and hidden on a build that cannot use it.
private struct HelperStatusItem: View {
    let model: AppModel
    let showsWord: Bool

    var body: some View {
        let monitor = model.helperMonitor
        let health = monitor.health
        if health != .unavailable {
            Menu {
                Text(health.title).disabled(true)
                Divider()
                ForEach(health.actions.filter { $0 != .openLoginItems }, id: \.self) { action in
                    Button(action.title) { monitor.perform(action) }
                        .disabled(monitor.busy)
                        .help(action.help ?? "")
                }
                Button(HelperHealth.Action.openLoginItems.title) { monitor.openLoginItems() }
                Divider()
                Button("Helper Settings…") { model.requestHelperSettings() }
            } label: {
                // Room for the dot, which is drawn over the menu: a borderless macOS `Menu` draws its
                // label's text and drops the shapes around it (see `RuntimeStatusBand`).
                HStack(spacing: 0) {
                    Color.clear.frame(width: 18, height: 23)
                    if showsWord { Text("Helper").font(.system(size: 11)).lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .overlay(alignment: .leading) {
                Group {
                    if monitor.busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(health.tint).frame(width: 7, height: 7)
                    }
                }
                .frame(width: 18, height: 23)
                .allowsHitTesting(false)
            }
            .help("Flotilla Helper — \(health.title)")
            .accessibilityLabel("Flotilla Helper: \(health.title)")
            .accessibilityHint("Opens the helper menu")
            .onAppear { monitor.refresh() }
            // `onAppear` belongs to the persistent Menu control and fires once, so a popup opened after
            // the cache expired showed stale health. AppKit posts this each time a menu opens.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                monitor.refresh()
            }
        }
    }
}
