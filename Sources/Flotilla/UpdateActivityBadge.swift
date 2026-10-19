import SwiftUI
import FlotillaCore

/// What the status bar's update slot says and how it looks.
struct UpdateBadgeContent: Equatable {
    enum Kind: Equatable { case working, done, failed }
    var text: String
    var kind: Kind
    /// Steps within one long run (logo 3 of 32) change too often to read out.
    var announces = true

    var symbol: String {
        switch kind {
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    init(text: String, kind: Kind, announces: Bool = true) {
        self.text = text
        self.kind = kind
        self.announces = announces
    }

    init(_ entry: UpdateActivity.Entry) {
        var isLogo = false
        if case .logos = entry.stage { isLogo = true }
        self.init(text: entry.text,
                  kind: entry.stage.isInProgress ? .working : entry.stage.isFailure ? .failed : .done,
                  announces: !isLogo)
    }

    /// Checks come first; a fleet push shows only when nothing else is going on.
    @MainActor
    static func current(_ model: AppModel) -> UpdateBadgeContent? {
        if let entry = model.updateActivity.activity.headline { return UpdateBadgeContent(entry) }
        let updating = model.hostMode.updating
        if !updating.isEmpty {
            let text = updating.count == 1
                ? "Updating \(model.hostMode.book[updating.first!]?.displayName ?? "a Mac")…"
                : "Updating \(updating.count) Macs…"
            return UpdateBadgeContent(text: text, kind: .working)
        }
        // `container` upgrades too, now that Overview's card no longer shows them.
        let upgrading = model.hostMode.settingUpRuntime
        guard !upgrading.isEmpty else { return nil }
        let text = upgrading.count == 1
            ? "Upgrading container on \(model.hostMode.book[upgrading.first!]?.displayName ?? "a Mac")…"
            : "Upgrading container on \(upgrading.count) Macs…"
        return UpdateBadgeContent(text: text, kind: .working)
    }
}

/// The spinning two-arrow symbol and a stage in words, left of the version menu.
struct UpdateActivityBadge: View {
    let content: UpdateBadgeContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: content.symbol)
                .symbolEffect(.rotate, options: .repeating, isActive: content.kind == .working && !reduceMotion)
                .foregroundStyle(content.kind == .failed ? Color.orange : Color.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            Text(content.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 23)
        .help(content.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.text)
    }
}

/// A small spinner for beside an update button; still, with Reduce Motion on, but present.
struct UpdateSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            ProgressView().controlSize(.small)
                .accessibilityHidden(true)
        }
    }
}

enum UpdateText {
    static func lastChecked(_ date: Date?) -> String {
        guard let date else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked: \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}
