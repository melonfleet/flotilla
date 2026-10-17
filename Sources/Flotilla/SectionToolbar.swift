import SwiftUI
import AppKit

/// The control band every list screen wears, so Containers, Images, Volumes and Networks stop
/// being four slightly different screens.
///
/// **Every band directly beneath the window's title bar uses horizontal 12, vertical 8** — this
/// toolbar, the containers and machines toolbars, the detail headers, and `FormHeader`. They had
/// drifted to three different values (8, 9 and 12) which is invisible on any one screen and
/// obvious the moment you switch between them. If you change the number, change all of them.
///
/// They had drifted in three ways, all small and all visible side by side: the three secondary
/// screens printed a large title the Containers screen does not (the sidebar already says where
/// you are, so the title was a second answer to a question nobody asked, costing a band of
/// vertical space on every screen but the main one); none of them had a search field; and their
/// action buttons sat as bare glyphs rather than in the glass cluster Containers uses.
///
/// **No search field of its own since Q55.** The window bar's box filters the page instead: this
/// band lends it `search`, the same binding the field here used to edit, so every section's filter
/// state and matching are unchanged. The band registers it only while it is on screen, which is
/// exactly while the list is, so a detail or a form in the same section has nothing to filter.
///
/// Shared rather than copied, for the reason the Copy menu had to be shared: parity that lives
/// in four files is parity someone has to remember, and this project has already lost that bet
/// once — switching to Cards silently cost you the Copy menu because its definition was private
/// to one view.
struct SectionToolbar<Leading: View, Trailing: View>: View {
    /// This section's filter text, lent to the window bar's search box.
    var search: Binding<String>
    /// The box's placeholder while this section is showing. Names the noun, so the box says what it filters.
    let searchPrompt: String
    /// How many rows the filter leaves, for the box's "12 on this page".
    var matches: Int?
    /// When this screen last refreshed, or nil to omit. Rendered exactly as the Containers
    /// screen renders it.
    var updated: Date?
    /// An arbitrary status string, shown in the same slot as `updated`. Activity counts rows
    /// rather than timing a refresh; before this it printed that count in a hand-rolled band of
    /// its own, which is how the search field there ended up 20pt narrower than everywhere else.
    var status: String?

    /// What the box understands beyond plain words, on hover — Containers' `SearchQuery` grammar.
    var searchHelp: String?

    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading

            Spacer()

            if let updated {
                // Only where there is room for it (Kamal, 17 October): a list beside its page is
                // 340pt by default, and this was what pushed select-all, Sort, Filter, + and ⟳ into
                // each other. The time is always on ⟳'s tooltip (`ToolbarRefreshButton`).
                ViewThatFits(in: .horizontal) {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
            } else if let status {
                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // **Only when there is something to put in it.** `ActionCluster` draws a glass
            // capsule unconditionally, so a section with no trailing action — Activity, whose
            // feed is appended to as things happen and therefore has nothing to refresh — showed
            // an empty pill floating at the end of the band. Checked on the type rather than with
            // a flag the caller has to remember to pass, so it cannot be got wrong at a call
            // site: `EmptyView` is exactly what "no trailing content" is spelled as.
            if Trailing.self != EmptyView.self {
                ActionCluster { trailing }
                    .environment(\.sectionUpdated, updated)
            }
        }
        // Horizontal 12 so the band lines up with the content edge; vertical **8**, which is
        // tighter than the 12 this used and gives back a strip of height on every section.
        // The owner compared the two side by side — Machines was accidentally on 8 for a while —
        // and preferred the tighter one. Every toolbar in the app uses this pair; changing one
        // is how they drifted apart in the first place.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .searchesFromToolbar(prompt: searchPrompt.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")),
                             help: searchHelp, text: search, matches: matches)
    }
}

extension SectionToolbar where Leading == EmptyView {
    init(
        search: Binding<String>,
        searchPrompt: String,
        matches: Int? = nil,
        updated: Date? = nil,
        status: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(search: search, searchPrompt: searchPrompt, matches: matches, updated: updated, status: status,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

/// An icon-only toolbar button, with the word kept as tooltip and accessibility label.
///
/// The owner's rule, and the reason it is a rule: *"we don't want to use a lot of words instead of
/// icons just so that it makes it more universal and more easier to read for everyone,
/// especially the people that can't read words or English."* The word is not deleted — it moves
/// to `help` and `accessibilityLabel`, where it still reaches anyone who needs it.
struct ToolbarIconButton: View {
    let systemImage: String
    let label: String
    /// The tooltip, when it has more to say than the label. Defaults to the label, which is what
    /// every existing caller wants — but a button whose meaning changes with state (Live, which
    /// is "start streaming N sources" or "stop streaming" or "too many sources to stream") has a
    /// tooltip that cannot be its name.
    var help: String?
    var isDestructive = false
    /// Engaged — see `IconActionButton.active`.
    var active = false
    /// Not offered, as distinct from busy — see `IconActionButton`, which has carried the
    /// distinction since a built-in network's delete button span forever instead of refusing.
    var disabled = false
    let action: () -> Void

    var body: some View {
        // Same feedback as the row actions — `IconActionButton` owns the hover and pressed
        // states, so a toolbar button and a row button react identically. They did not before:
        // these were a bare `Button` with only a tooltip, so nothing happened on hover and
        // nothing happened on click either.
        IconActionButton(systemImage: systemImage, label: label, help: help ?? label,
                         disabled: disabled, destructive: isDestructive,
                         active: active, action: action)
    }
}

extension EnvironmentValues {
    /// When the section beside this button last refreshed, from its `SectionToolbar`.
    @Entry var sectionUpdated: Date?
}

/// A section's ⟳, whose tooltip says when the section last refreshed — the "Updated 10:04:02 PM"
/// the toolbar prints only where it fits.
struct ToolbarRefreshButton: View {
    /// "Refresh containers".
    let label: String
    let action: () -> Void
    @Environment(\.sectionUpdated) private var updated

    var body: some View {
        ToolbarIconButton(systemImage: "arrow.clockwise", label: label,
                          help: updated.map { "\(label) — updated \($0.formatted(date: .omitted, time: .standard))" } ?? label,
                          action: action)
    }
}

/// A toolbar control that opens a menu: one glyph, several related actions behind it.
///
/// Added for Containers' "+", which became a menu of **Run Container…** and **New Group…** when
/// groups joined that list (the owner's call, 5 October): two ways to add something to one list,
/// under the one glyph that means "add". It draws with `ToolbarMenuGlyph`, the window bar's
/// links-menu glyph, so it has the same hover wash and size as every `ToolbarIconButton` beside
/// it.
///
/// **`.tint`, not `.foregroundStyle`**, for the reason `AppLinksMenu` records: a borderless `Menu`
/// paints its label with the tint and ignores a foreground set on it.
struct ToolbarIconMenu<Content: View>: View {
    let systemImage: String
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            ToolbarMenuGlyph(systemImage: systemImage)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.primary)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The glass capsule a group of actions sits in.
///
/// The mockup's `GlassEffectContainer`, and the reason it is shared: it was written out four
/// times — this toolbar, the containers detail header, the machines detail header, and nearly a
/// fifth time for the log band — with the spacing and the corner radius retyped each time. The
/// log band is what made it worth extracting: its buttons were bare glyphs on the band, so the
/// same control looked like two different kinds of thing depending on which band you found it on.
///
/// Glass goes on chrome only and never on glass, so this wraps a row of buttons and nothing else.
struct ActionCluster<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) { content }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(in: .rect(cornerRadius: 8))
        }
        .fixedSize()
    }
}
