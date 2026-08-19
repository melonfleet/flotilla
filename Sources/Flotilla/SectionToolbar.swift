import SwiftUI

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
/// Shared rather than copied, for the reason the Copy menu had to be shared: parity that lives
/// in four files is parity someone has to remember, and this project has already lost that bet
/// once — switching to Cards silently cost you the Copy menu because its definition was private
/// to one view.
struct SectionToolbar<Leading: View, Trailing: View>: View {
    @Binding var search: String
    /// Shown in the empty search field. Names the noun, so the field says what it filters.
    let searchPrompt: String
    /// When this screen last refreshed, or nil to omit. Rendered exactly as the Containers
    /// screen renders it.
    var updated: Date?

    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading

            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)

            Spacer()

            if let updated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The mockup's one `GlassEffectContainer`, matching the Run/Refresh cluster on the
            // Containers screen. Kept to a single container per screen: the placement note puts
            // glass on chrome only, and glass on glass is explicitly ruled out.
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) { trailing }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(in: .rect(cornerRadius: 8))
            }
            .fixedSize()
        }
        // Horizontal 12 so the band lines up with the content edge; vertical **8**, which is
        // tighter than the 12 this used and gives back a strip of height on every section.
        // the owner compared the two side by side — Machines was accidentally on 8 for a while —
        // and preferred the tighter one. Every toolbar in the app uses this pair; changing one
        // is how they drifted apart in the first place.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension SectionToolbar where Leading == EmptyView {
    init(
        search: Binding<String>,
        searchPrompt: String,
        updated: Date? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(search: search, searchPrompt: searchPrompt, updated: updated,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

/// An icon-only toolbar button, with the word kept as tooltip and accessibility label.
///
/// the owner's rule, and the reason it is a rule: *"we don't want to use a lot of words instead of
/// icons just so that it makes it more universal and more easier to read for everyone,
/// especially the people that can't read words or English."* The word is not deleted — it moves
/// to `help` and `accessibilityLabel`, where it still reaches anyone who needs it.
struct ToolbarIconButton: View {
    let systemImage: String
    let label: String
    var isDestructive = false
    /// Engaged — see `IconActionButton.active`.
    var active = false
    let action: () -> Void

    var body: some View {
        // Same feedback as the row actions — `IconActionButton` owns the hover and pressed
        // states, so a toolbar button and a row button react identically. They did not before:
        // these were a bare `Button` with only a tooltip, so nothing happened on hover and
        // nothing happened on click either.
        IconActionButton(systemImage: systemImage, label: label, help: label,
                         destructive: isDestructive, active: active, action: action)
    }
}
