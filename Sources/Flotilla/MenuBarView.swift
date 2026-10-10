import SwiftUI
import AppKit
import FlotillaCore

/// The menu-bar menu: **a status line and a way in, not a second app** (the owner, 8 October).
///
/// It was a 380-point popover with a rollup, per-container rows with inline start and stop, hover
/// boxes and meters — which grew with every container and every host until it no longer fitted
/// the job. The owner pointed at Docker Desktop's menu instead: one status line, the dashboard,
/// a few submenus, settings, troubleshooting, updates, quit. So this is a native menu now
/// (`.menuBarExtraStyle(.menu)`), and every item is a door into the window rather than a copy of
/// part of it:
///
/// - **The status line** says what the icon's badge says, in words, from the same
///   `AppModel.menuBarStatus` — and the fleet in one clause.
/// - **Needs Attention** is Overview's list (`AppModel.attentionItems`), shown only when there is
///   something on it; each item opens the section that deals with it.
/// - **Hosts** is a submenu, like Docker's Kubernetes contexts, so thirty Macs are thirty short
///   rows one level down rather than thirty tall rows in the menu itself.
/// - **Troubleshoot** holds what you reach for when something is wrong: the container system's
///   start, stop and restart (asking first, as everywhere else), and the support bundle.
/// - **Quit says what it does to your containers** — Docker Desktop's most-cited gap, kept from
///   the popover.
///
/// Nothing here exists only here. Every item is a command the window or the app menu already has.
struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// "Golden-Gate isn't answering: Couldn't reach…" → "Golden-Gate isn't answering" over
    /// "Couldn't reach…", each kept to a menu's width.
    static func menuLines(_ text: String, limit: Int = 60) -> (String, String?) {
        func fit(_ s: String) -> String { s.count > limit ? String(s.prefix(limit - 1)) + "…" : s }
        guard let colon = text.range(of: ": ") else { return (fit(text), nil) }
        let title = String(text[..<colon.lowerBound])
        let detail = String(text[colon.upperBound...])
        return (fit(title), detail.isEmpty ? nil : fit(detail.prefix(1).uppercased() + detail.dropFirst()))
    }

    var body: some View {
        statusLine
        Button("Open Flotilla") { present { model.requestSection(.overview) } }
            .keyboardShortcut("o")

        let attention = model.attentionItems
        if !attention.isEmpty {
            Divider()
            Menu("Needs Attention (\(attention.count))") {
                ForEach(attention) { item in
                    // A title and a smaller line under it, as Quit's "Containers keep running": a menu
                    // cannot wrap, and the whole message on one line ran nearly across the screen
                    // (the owner, 10 October). Overview shows it in full.
                    let (title, detail) = Self.menuLines(item.text)
                    Button { present { model.requestSection(item.section) } } label: {
                        Text(title)
                        if let detail { Text(detail) }
                    }
                }
            }
        }
        hostsMenu

        Divider()
        Button("Run Container…") { present(model.requestRunSheet) }
            .disabled(!model.runtimeUsable)
        Button("Pull Image…") { present(model.requestPullForm) }
            .disabled(!model.runtimeUsable)

        Divider()
        Button("Settings…") { present { model.requestSection(.settings) } }
            .keyboardShortcut(",")
        troubleshootMenu
        Button("About Flotilla") { present(model.requestAbout) }

        Divider()
        Button(model.hostMode.isAdmin || !AppUpdater.isConfigured ? "Check for Updates…"
                                                                : "Updated by Your Admin Mac") {
            model.updater.checkForUpdates()
        }
        .disabled(!model.updater.isRunning)
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text("Quit Flotilla")
            Text("Containers keep running")
        }
        .keyboardShortcut("q")
    }

    // MARK: Status

    /// One line, in the words the runtime band uses (`RuntimeStatus.describe`), with the fleet
    /// beneath it when there is one. Disabled, as Docker's is: it is a statement, not a command.
    private var statusLine: some View {
        let runtime = RuntimeStatus.describe(model.preflight)
        let hosts = model.hostMode.trustedHosts
        let connected = hosts.filter {
            if case .connected? = model.hostMode.live[$0.fingerprint]?.state { return true }
            return false
        }.count
        return Button {} label: {
            Image(nsImage: Self.dot(for: model.menuBarStatus))
            Text(runtime.title)
            if !model.power.reasons.isEmpty {
                // Whenever Flotilla is keeping this Mac awake, the menu says so, and why (Q44).
                Text("Keeping this Mac awake: " + model.power.reasons.joined(separator: ", "))
            } else if !hosts.isEmpty {
                Text("\(connected) of \(hosts.count) host\(hosts.count == 1 ? "" : "s") connected")
            } else if let detail = runtime.detail {
                Text(detail)
            }
        }
        .disabled(true)
    }

    /// The badge's colour as a menu image. Not a template, so the menu keeps the colour.
    private static func dot(for status: MenuBarStatus) -> NSImage {
        let color: NSColor = switch status {
        case .checking: .secondaryLabelColor
        case .running: .systemGreen
        case .attention, .off: .systemRed
        }
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Hosts

    /// This Mac and every paired host; each opens its page under Hosts. A host that is not
    /// answering says so in the row, so the submenu is a roll-call as well as a list.
    private var hostsMenu: some View {
        Menu("Hosts") {
            Button {
                present { model.requestDetail(kind: .host, subject: HostRow.thisMacID) }
            } label: {
                Text(HostModeController.computerName)
                Text("This Mac")
            }
            ForEach(model.hostMode.trustedHosts, id: \.fingerprint) { peer in
                Button {
                    present { model.requestDetail(kind: .host, subject: peer.fingerprint.hex) }
                } label: {
                    Text(peer.displayName)
                    switch model.hostMode.live[peer.fingerprint]?.state {
                    case .failed?: Text("Not answering")
                    case .checking?, nil: Text("Checking…")
                    case .connected?: EmptyView()
                    }
                }
            }
            Divider()
            Button("Show All Hosts") { present { model.requestSection(.hosts) } }
        }
    }

    // MARK: Troubleshoot

    private var troubleshootMenu: some View {
        let enablement = RuntimeStatus.enablement(model.preflight)
        return Menu("Troubleshoot") {
            Button("Start Container System") { Task { await model.startRuntime() } }
                .disabled(!enablement.start || model.startingRuntime)
            Button("Restart Container System…") { confirm(.restart) }
                .disabled(!enablement.stopRestart || model.startingRuntime)
            Button("Stop Container System…") { confirm(.stop) }
                .disabled(!enablement.stopRestart || model.startingRuntime)
            Divider()
            Button("Show Logs") { present { model.requestSection(.logs) } }
            Button("Show Activity") { present { model.requestSection(.activity) } }
            Button("Create Support Bundle…") { present(model.requestSupportBundle) }
        }
    }

    /// Stop and Restart ask first, in the same words as the Hosts menu and the runtime band
    /// (`RuntimeLifecycleAction`). A menu has no sheet to show, so it is an alert.
    private func confirm(_ action: RuntimeLifecycleAction) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = action.question
        alert.informativeText = action.consequence
        alert.alertStyle = .warning
        alert.addButton(withTitle: action.verb)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch action {
        case .stop: Task { await model.stopRuntime() }
        case .restart: Task { await model.restartRuntime() }
        }
    }

    // MARK: Plumbing

    /// As the app menu's commands do: set the one-shot request, bring Flotilla forward, open the
    /// window — which consumes the request on appearing, even if it had been closed.
    private func present(_ request: () -> Void) {
        request()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
