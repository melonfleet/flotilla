import SwiftUI
import FlotillaCore

// The pieces Settings is drawn from: a sidebar of sections with tiles, a scrolling pane, bold group
// headings, and the three row shapes (checkbox, inline control, note).
//
// Nothing in this file names a `SettingsKeys` member. `Scripts/check-settings-consumers.sh` treats
// a mention of a key outside the registry and `SettingsView.swift` as a *consumer*, so a key spelt
// here would count as read by something that only displays it.

// MARK: - Sidebar

/// One section's row in the sidebar: a rounded-square tile and a name.
struct SettingsSidebarItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let symbol: String
    let tile: SettingsTileStyle
}

/// A tile's colours: a soft fill and a deeper glyph, both from `design/branding.md`.
///
/// Soft rather than solid, as in the reference, so the glyph stays legible on every fill —
/// white on `canary` or `honeydew` is 1.5:1. The fill is the brand colour at low alpha; the glyph is
/// the brand's own text-grade variant of it.
struct SettingsTileStyle {
    let fill: Color
    let glyph: Color

    static let green = SettingsTileStyle(fill: Theme.stripe, glyph: Theme.rind)
    static let deepGreen = SettingsTileStyle(fill: Theme.rind, glyph: Theme.rind)
    static let pale = SettingsTileStyle(fill: Theme.honeydew, glyph: Theme.rind)
    static let orange = SettingsTileStyle(fill: Theme.cantaloupe, glyph: Theme.melonText)
    static let yellow = SettingsTileStyle(fill: Theme.canary, glyph: Theme.warning)
    static let teal = SettingsTileStyle(fill: Theme.info, glyph: Theme.info)
    /// `flesh #FC4A6B` and `flesh-deep #E63956` from branding.md's palette table, which `Theme` has
    /// no token for outside dark mode's `melon`.
    static let pink = SettingsTileStyle(fill: Color(hex: 0xFC4A6B), glyph: Color(hex: 0xE63956))
    /// The tag palette's `Grey`, `#77777C`: the one neutral in the brand.
    static let grey = SettingsTileStyle(fill: Color(hex: 0x77777C), glyph: Color(hex: 0x55555A))
}

struct SettingsTile: View {
    let symbol: String
    let style: SettingsTileStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(style.fill.opacity(0.28))
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.glyph)
            }
            // Decorative: the row's name is its label.
            .accessibilityHidden(true)
    }
}

/// The section list. A real `List(selection:)`, so ↑ ↓ move through it and Tab leaves it for the
/// pane, and the selected row is the system's accent fill with white text — as macOS draws it.
struct SettingsSidebar<ID: Hashable>: View {
    /// Groups are separated by a divider.
    let groups: [[SettingsSidebarItem<ID>]]
    @Binding var selection: ID

    var body: some View {
        List(selection: Binding<ID?>(get: { selection }, set: { if let new = $0 { selection = new } })) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, items in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                        .accessibilityHidden(true)
                }
                ForEach(items) { item in
                    Label {
                        Text(item.title).font(.system(size: 14))
                    } icon: {
                        SettingsTile(symbol: item.symbol, style: item.tile)
                    }
                    .labelStyle(SettingsSidebarLabelStyle())
                    .tag(item.id)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Settings sections")
    }
}

private struct SettingsSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
            configuration.title
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pane

/// A section's page: left-aligned, generously spaced, scrolling when it is long.
///
/// `maxHeight: .infinity` on the scroll view and `maxWidth` on the stack — a pane is a bounded
/// child of the window, never one that sizes the window (CLAUDE.md, "one unbounded child").
struct SettingsPane<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A bold heading and the settings under it. `title` is optional: the first group of a pane has
/// none, as in the reference.
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// Grey explanatory text. Markdown, so a `container ls` renders as code.
struct SettingsNote: View {
    private let text: Text

    init(_ markdown: String) { text = Text(LocalizedStringKey(markdown)) }
    /// For text that is data — an error, a status — and must not be read as markdown.
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A title with the lock a managed value carries and the badge an unbuilt one carries.
struct SettingTitle: View {
    let title: String
    /// Shown as a padlock with this tooltip when non-nil.
    var lockNote: String?
    var unbuilt = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(unbuilt ? .secondary : .primary)
            if let lockNote {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(lockNote)
            }
            if unbuilt {
                Text("Not yet available")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }
}

/// What sits under a setting's title: the grey explanation, then the amber lines.
///
/// Shared by both row shapes so a managed, unbuilt or restart-needing setting reads the same
/// whichever shape it is.
struct SettingNotes: View {
    let help: String
    var helpStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    /// Why the control does nothing yet — see `SettingAvailability`.
    var unbuiltReason: String?
    var requiresRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Markdown, so a summary's `container ls` renders as code rather than as backticks: a
            // `String` reaches `Text` verbatim.
            if !help.isEmpty {
                Text(LocalizedStringKey(help))
                    .font(.callout)
                    .foregroundStyle(helpStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unbuiltReason {
                Text(unbuiltReason).font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if requiresRestart {
                Text("Requires a restart to take effect.").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

/// A checkbox, its title in regular weight, and the explanation in grey under it, indented to the
/// title. The label is the whole of the toggle's content, so clicking the words toggles it.
struct SettingCheck<Footer: View>: View {
    let title: String
    let help: String
    var helpStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    var lockNote: String?
    var unbuiltReason: String?
    var requiresRestart = false
    var disabled = false
    @Binding var isOn: Bool
    @ViewBuilder var footer: Footer

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                SettingTitle(title: title, lockNote: lockNote, unbuilt: unbuiltReason != nil)
                SettingNotes(help: help, helpStyle: helpStyle, unbuiltReason: unbuiltReason,
                             requiresRestart: requiresRestart)
                footer
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled || unbuiltReason != nil)
        // The words are the label; the explanation is the hint.
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}

extension SettingCheck where Footer == EmptyView {
    init(title: String, help: String, helpStyle: AnyShapeStyle = AnyShapeStyle(.secondary),
         lockNote: String? = nil, unbuiltReason: String? = nil, requiresRestart: Bool = false,
         disabled: Bool = false, isOn: Binding<Bool>) {
        self.init(title: title, help: help, helpStyle: helpStyle, lockNote: lockNote,
                  unbuiltReason: unbuiltReason, requiresRestart: requiresRestart, disabled: disabled,
                  isOn: isOn, footer: { EmptyView() })
    }
}

/// "Label: [control]", the reference's pop-up shape, with the explanation under it.
///
/// For rows with no registry key behind them (an identity, a status): `SettingRow` is this with the
/// store's lock and availability wired in.
struct SettingInline<Control: View>: View {
    let label: String
    var help: String?
    var helpStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    var lockNote: String?
    var unbuiltReason: String?
    var requiresRestart = false
    var disabled = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SettingTitle(title: label, lockNote: lockNote, unbuilt: unbuiltReason != nil)
                control
                    .disabled(disabled || unbuiltReason != nil)
            }
            if help != nil || unbuiltReason != nil || requiresRestart {
                SettingNotes(help: help ?? "", helpStyle: helpStyle, unbuiltReason: unbuiltReason,
                             requiresRestart: requiresRestart)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
