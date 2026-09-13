import SwiftUI
import FlotillaCore

/// One tag, drawn as a coloured pill.
///
/// **A pill, not a tinted row.** The owner's call, and it is the right one: colouring the whole card
/// would put an arbitrary hue behind a state dot, a name and four values, so a container tagged
/// "Production" would read as *alarming* rather than as tagged, and two tags on one card would
/// have nowhere to go at all. A pill is additive — it says one more thing about the row without
/// taking anything the row already said.
///
/// The dot carries the colour at full strength and the capsule at low alpha, so a pill stays
/// legible on white, on the raised card surface and on a selected row, and so the colour is
/// identifiable from across the window while the name is still readable up close. A solid
/// coloured capsule with white text is the obvious alternative and fails the third case: on a
/// selected row it competes with the selection fill, and the yellow one fails contrast outright.
struct TagPill: View {
    let tag: Tag
    /// Smaller inside a table row than on a card — a table row is 24pt and a card has space.
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Theme.color(for: tag.color))
                .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(tag.name)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(Theme.color(for: tag.color).opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.color(for: tag.color).opacity(0.35)))
        .foregroundStyle(.primary)
        .help("Tagged ‘\(tag.name)’")
        .fixedSize()
    }
}

/// The pills on one subject, laid out for a table cell or a card.
///
/// Truncates to `limit` and says how many are hidden rather than wrapping: a table row has one
/// line of height, and a cell that silently drops the third tag is a cell that lies about what a
/// row is tagged with. The overflow count is `help`-labelled with the full list, so nothing is
/// unreachable.
struct TagPillRow: View {
    let tags: [Tag]
    var compact = false
    var limit = 2

    var body: some View {
        if tags.isEmpty {
            // Deliberately empty rather than an em dash. Every other column in these tables
            // shows "—" for a missing value because the value is expected; a tag is not, and a
            // column of forty dashes is noise.
            Color.clear.frame(height: 0)
        } else {
            HStack(spacing: 4) {
                ForEach(tags.prefix(limit)) { TagPill(tag: $0, compact: compact) }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(tags.map(\.name).joined(separator: ", "))
                }
            }
        }
    }
}

/// The **Tags** submenu, identical on every row menu in the app.
///
/// One definition, five sections. The alternative — each section writing its own list of toggles
/// — is the exact shape `check-menu-parity.sh` exists to catch: five copies of one menu, one of
/// which quietly loses an item. It takes a `TagSubject`, so the only thing a section supplies is
/// which thing is being tagged.
///
/// Every defined tag is listed with a checkmark, **including the ones not applied** — the same
/// rule the lifecycle menus follow after the runtime-band pass: present and unticked, not
/// absent. A menu whose contents depend on current state is a menu whose item positions move
/// under the pointer.
struct TagMenu: View {
    let store: TagStore
    let subject: TagSubject
    /// Opens the create sheet. The sheet has to be presented by the view that owns the row, not
    /// by a menu item — a `.sheet` attached inside a menu never appears, because the menu is
    /// gone by the time the state changes.
    let onNewTag: () -> Void

    var body: some View {
        Menu("Tags") {
            ForEach(store.allTags) { tag in
                Button {
                    store.toggle(tag.id, on: subject)
                } label: {
                    // A **drawn** swatch, not `Image(systemName:).foregroundStyle(…)`. That was
                    // the first version and it rendered all seven tags in one colour: AppKit
                    // tints a menu item's icon itself and the SwiftUI style does not survive.
                    // `Theme.swatchImage` records the measurement; the tick is drawn into the
                    // same image because a menu item has only one icon slot.
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(nsImage: Theme.swatchImage(
                            for: tag.color,
                            applied: store.isTagged(subject, with: tag.id)))
                    }
                }
            }
            if !store.allTags.isEmpty { Divider() }
            Button("New Tag…", action: onNewTag)
            Button("Clear Tags") { store.clearTags(on: subject) }
                .disabled(store.tags(on: subject).isEmpty)
        }
    }
}

/// Creating a tag, from a row menu or from the manager.
///
/// A sheet rather than an inline field because it is reached from a menu, and because it asks
/// two questions — name and colour — that belong together. It says why it is refusing while you
/// type, per the standing rule this app keeps re-learning: a greyed button with no message is a
/// bug report waiting to happen.
struct NewTagSheet: View {
    let store: TagStore
    /// Applied to this subject on creation, when the sheet was opened from a row.
    var applyTo: TagSubject?
    let dismiss: () -> Void

    @State private var name = ""
    @State private var color: TagColor = .blue

    private var problem: String? {
        // Nothing typed yet is not a problem to report — it is the starting state. The button is
        // disabled either way.
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : store.book.problem(withName: name)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem == nil
    }

    var body: some View {
        ModalCard(title: "New Tag", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Production", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canCreate { create() } }
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Colour").font(.system(size: 12)).foregroundStyle(.secondary)
                    TagColorPicker(selection: $color)
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canCreate)
                }
            }
            .frame(width: 320)
            .padding(16)
        }
    }

    private func create() {
        if let applyTo {
            store.createTag(name: name, color: color, andApplyTo: applyTo)
        } else {
            store.createTag(name: name, color: color)
        }
        dismiss()
    }
}

/// The seven swatches, as a row of buttons.
///
/// Not a `Picker`: a menu of colour names is a menu you have to read, and the whole argument for
/// a fixed palette is that you recognise the swatch. The selected one carries a ring rather than
/// a tick, so the colour is never covered by the indicator that says it is chosen.
struct TagColorPicker: View {
    @Binding var selection: TagColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TagColor.allCases, id: \.self) { color in
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(Theme.color(for: color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.color(for: color),
                                              lineWidth: selection == color ? 2 : 0)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(selection == color ? [.isSelected] : [])
                .help(color.title)
            }
        }
    }
}

/// One subject, wrapped for `.sheet(item:)`.
///
/// `TagSubject` is deliberately **not** `Identifiable`: its `id` is the subject's own name,
/// which is unique within a kind and not across them — a volume and a container may both be
/// called `web`, which is the whole reason a subject carries its kind. `.sheet(item:)` needs an
/// identity that is the *whole* subject, so that is what this supplies.
struct TagSheetTarget: Identifiable, Hashable {
    let subject: TagSubject
    var id: String { subject.storageKey }

    init(_ subject: TagSubject) { self.subject = subject }
    init(kind: ActivityKind, id: String) { subject = TagSubject(kind: kind, id: id) }
}
