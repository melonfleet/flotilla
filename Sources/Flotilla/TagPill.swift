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
    /// Applied to these on creation — one subject when the sheet was opened from a row, the
    /// whole selection when it came from the bulk bar.
    var applyTo: [TagSubject] = []
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
        if applyTo.isEmpty {
            store.createTag(name: name, color: color)
        } else {
            store.createTag(name: name, color: color, andApplyTo: applyTo)
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

/// The subjects a "New Tag…" sheet will tag, wrapped for `.sheet(item:)`.
///
/// `TagSubject` is deliberately **not** `Identifiable`: its `id` is the subject's own name,
/// which is unique within a kind and not across them — a volume and a container may both be
/// called `web`, which is the whole reason a subject carries its kind. `.sheet(item:)` needs an
/// identity that is the *whole* subject, so that is what this supplies.
///
/// A list rather than one subject, because the same sheet is opened from a row's Tags menu and
/// from the bulk bar with six rows selected, and a second near-identical sheet for the second
/// case is how two sheets drift apart.
struct TagSheetTarget: Identifiable, Hashable {
    let subjects: [TagSubject]
    /// Every subject, so opening the sheet for a different selection re-presents it rather than
    /// reusing the one already on screen.
    var id: String { subjects.map(\.storageKey).joined(separator: "\u{1}") }

    init(_ subjects: [TagSubject]) { self.subjects = subjects }
    init(kind: ActivityKind, id: String) { subjects = [TagSubject(kind: kind, id: id)] }
}

/// The **Tags** menu for a multi-row selection, in each section's bulk action bar.
///
/// Shares `TagMenu`'s shape and not its code, because the question is genuinely different. With
/// one row a tag is on or off; with six it is on all, on some, or on none, and the swatch says
/// which (tick, dash, plain — the three marks a checkbox uses, for the same reason).
///
/// **Picking a tag applies it to everything selected unless it is already on everything, in which
/// case it comes off.** Toggling each row independently is the obvious implementation and the
/// wrong behaviour: on a mixed selection it would tag half and untag half, which is nobody's
/// reading of choosing a tag with six rows selected.
struct BulkTagMenu: View {
    let store: TagStore
    let subjects: [TagSubject]
    let onNewTag: () -> Void

    private func coverage(of tagID: String) -> Theme.TagCoverage {
        let on = subjects.count { store.isTagged($0, with: tagID) }
        if on == 0 { return .none }
        return on == subjects.count ? .all : .some
    }

    var body: some View {
        Menu {
            ForEach(store.allTags) { tag in
                let state = coverage(of: tag.id)
                Button {
                    store.apply(tag.id, to: subjects, applied: state != .all)
                } label: {
                    Label {
                        // Names what the click will do when it is not obvious from the mark.
                        // "Staging" on a mixed selection could mean either direction, and the
                        // menu is the only place to say which.
                        Text(state == .some ? "\(tag.name) — add to all" : tag.name)
                    } icon: {
                        Image(nsImage: Theme.swatchImage(for: tag.color, coverage: state))
                    }
                }
            }
            if !store.allTags.isEmpty { Divider() }
            Button("New Tag…", action: onNewTag)
            Button("Clear Tags") {
                for subject in subjects { store.clearTags(on: subject) }
            }
            .disabled(!subjects.contains { !store.tags(on: $0).isEmpty })
        } label: {
            Image(systemName: "tag")
                .frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Icon-only, so it has to be named — and the count belongs in the name, because this
        // button acts on rows that are not under the pointer.
        .accessibilityLabel("Tag \(subjects.count) selected")
        .help("Tag the \(subjects.count) selected item\(subjects.count == 1 ? "" : "s")")
        .disabled(subjects.isEmpty)
    }
}
