import SwiftUI
import AppKit

/// Settings ▸ Advanced ▸ Flotilla Helper (Q41): install it, see whether it is approved, remove it.
///
/// Approval happens in System Settings, which tells the app nothing, so the status is read again
/// whenever Flotilla comes back to the front — the moment the owner returns from Login Items.
struct HelperSettingsSection: View {
    @State private var status = PrivilegedHelper.status
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        SwiftUI.Section("Flotilla Helper") {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .foregroundStyle(tint)
                Spacer()
                actions
            }
            Text(explanation)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(4)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
            }
        }
        .onAppear { status = PrivilegedHelper.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = PrivilegedHelper.status
            if status == .enabled { problem = nil }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .unavailable:
            EmptyView()
        case .notInstalled:
            Button("Install…") { install() }.disabled(working)
        case .awaitingApproval:
            Button("Open Login Items…") { PrivilegedHelper.openLoginItems() }
            Button("Remove") { remove() }.disabled(working)
        case .enabled:
            Button("Remove") { remove() }.disabled(working)
        }
    }

    private var title: String {
        switch status {
        case .unavailable: "Not available in this build"
        case .notInstalled: "Not installed"
        case .awaitingApproval: "Waiting for your approval"
        case .enabled: "On"
        }
    }

    private var symbol: String {
        switch status {
        case .unavailable, .notInstalled: "circle"
        case .awaitingApproval: "exclamationmark.circle"
        case .enabled: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .enabled: Theme.online
        case .awaitingApproval: Theme.warning
        case .unavailable, .notInstalled: .secondary
        }
    }

    private var explanation: String {
        switch status {
        case .unavailable:
            "Only a signed copy of Flotilla can use the helper. Creating or deleting a DNS domain "
                + "asks for an administrator password instead."
        case .notInstalled:
            "Flotilla's one helper for the jobs that need an administrator: DNS domains, names "
                + "across Macs, and installing Apple's container. Approve it once; Flotilla still "
                + "asks you to confirm every change, and a host can't do these jobs without it."
        case .awaitingApproval:
            "Switch on Flotilla in System Settings ▸ General ▸ Login Items & Extensions. Until "
                + "then, DNS changes ask for an administrator password."
        case .enabled:
            "DNS changes no longer ask for a password; Flotilla asks you to confirm each change "
                + "instead. Remove the helper to go back to the password."
        }
    }

    private func install() {
        problem = nil
        do {
            try PrivilegedHelper.install()
        } catch {
            // Registration that is waiting for the owner's approval throws "Operation not
            // permitted" and still registers (measured 7 October): the status says what happened,
            // so only a status that did not move is a failure.
            if PrivilegedHelper.status == .notInstalled {
                problem = "Couldn't install the helper: \(error.localizedDescription)"
            }
        }
        status = PrivilegedHelper.status
        if status == .awaitingApproval { PrivilegedHelper.openLoginItems() }
    }

    private func remove() {
        problem = nil
        working = true
        Task {
            do { try await PrivilegedHelper.remove() } catch {
                problem = "Couldn't remove the helper: \(error.localizedDescription)"
            }
            working = false
            status = PrivilegedHelper.status
        }
    }
}
