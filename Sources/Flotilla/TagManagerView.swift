import SwiftUI
import FlotillaCore

/// Where the user manages every tag they have: rename, recolour, see what each one is on, and
/// delete.
///
/// **A Settings pane rather than a sidebar section**, and that is a judgement worth stating. A
/// sidebar section in this app is a *resource*: containers, images, volumes, networks, machines
/// — things the runtime owns, that you create and destroy and inspect. Tags are an attribute you
/// put on those things, and the place you go to tidy them up is maintenance, not a sixth
/// inventory. Putting it beside Containers would also put a screen you visit twice a year at the
/// same weight as the one you live in.
///
/// Everything it offers is reachable from a row menu too — creating, applying — so this is the
/// one place that adds *only* what a row cannot do: renaming a tag everywhere at once, seeing
/// what it is on, and getting rid of it.
///
/// Written as `Form` sections because `SettingsView.pane(for:)` wraps every pane in a grouped
/// `Form`; this is content for that, not a screen of its own.
struct TagManagerPane: View {
    let model: AppModel
    let store: TagStore

    @State private var showingNewTag = false
    @State private var pendingDelete: Tag?
    @State private var cleanUpResult: String?

    var body: some View {
        SwiftUI.Section {
            if store.allTags.isEmpty {
                // Reachable: the starter set is ordinary tags, so all seven can be deleted.
                // It says how to get back rather than just noting the absence.
                Text("You have no tags. Create one here, or from any container, machine, "
                     + "volume or network’s Tags menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.allTags) { tag in
                    row(for: tag)
                }
            }
        } header: {
            Text("Your tags")
        } footer: {
            Text("Tags are yours alone: they are stored on this Mac in Flotilla’s own "
                 + "preferences and are never sent to the container runtime, so tagging "
                 + "something changes nothing about how it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SwiftUI.Section {
            HStack {
                Button("New Tag…") { showingNewTag = true }
                Spacer()
                Button("Clean Up") { cleanUp() }
                    .disabled(orphanCount == 0)
                    .help(orphanCount == 0
                          ? "Every tag is on something that still exists"
                          : "Forget tags on \(orphanCount) thing"
                            + (orphanCount == 1 ? "" : "s") + " that no longer exist")
            }
            if let cleanUpResult {
                Text(cleanUpResult).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            // Says out loud why the app does not do this by itself.
            Text("Deleting a container does not delete its tags: the runtime list comes from a "
                 + "poll that can fail, and a sweep on every refresh would throw your tags away "
                 + "the first time it did. Clean Up is how you ask for it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingNewTag) {
            NewTagSheet(store: store) { showingNewTag = false }
        }
        .confirmationDialog(
            "Delete the tag “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let tag = pendingDelete {
                Button("Delete Tag", role: .destructive) {
                    store.deleteTag(tag.id)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            // The count is the decision. "Delete" and "delete, taking it off twelve containers"
            // are different actions and the dialog has to say which one this is.
            let count = pendingDelete.map { store.book.usageCount(of: $0.id) } ?? 0
            Text(count == 0
                 ? "It isn’t on anything. Nothing else changes."
                 : "It will be removed from \(count) thing\(count == 1 ? "" : "s"). "
                   + "Nothing is deleted except the tag itself.")
        }
    }

    private func row(for tag: Tag) -> some View {
        HStack(spacing: 10) {
            // The colour control *is* the swatch: a menu of seven names would make you read what
            // you can see. Same argument as `TagColorPicker`, in the shape a row has space for.
            Menu {
                ForEach(TagColor.allCases, id: \.self) { color in
                    Button {
                        store.recolour(tag.id, to: color)
                    } label: {
                        // Drawn, for the reason `Theme.swatchImage` records: a menu tints an
                        // SF Symbol itself, so a colour picker built from symbols shows seven
                        // identical swatches.
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(nsImage: Theme.swatchImage(for: color,
                                                             applied: color == tag.color))
                        }
                    }
                }
            } label: {
                // The same drawn swatch the menus use, so the row and its own menu cannot
                // disagree about what colour this tag is.
                Image(nsImage: Theme.swatchImage(for: tag.color, diameter: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Colour of \(tag.name): \(tag.color.title)")
            .help("Change the colour of \u{2018}\(tag.name)\u{2019}")

            // Renames in place, on commit rather than per keystroke: a name is validated as a
            // whole, and validating each character would refuse "Prod" on the way to "Production"
            // if a tag called "Pro" existed.
            TextField("Tag name", text: Binding(
                get: { tag.name },
                set: { store.rename(tag.id, to: $0) }
            ))
            .textFieldStyle(.plain)
            .frame(maxWidth: 220, alignment: .leading)

            Spacer(minLength: 8)

            let count = store.book.usageCount(of: tag.id)
            Text(count == 0 ? "Not used" : "On \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(usageDescription(of: tag))

            IconActionButton(systemImage: "trash", label: "Delete \(tag.name)",
                             help: "Delete \u{2018}\(tag.name)\u{2019}", destructive: true) {
                pendingDelete = tag
            }
        }
        // **Load-bearing.** A grouped `Form` reads a labelled control as a `LabeledContent` and
        // renders its label in the row's own leading column — so `TextField("Name", …)` put the
        // word "Name" at the start of all seven rows and pushed the swatch out of view entirely.
        // Measured, not guessed: the pane rendered "Name  Production  On 1" with no colour
        // anywhere, on the one screen whose subject is colour.
        .labelsHidden()
    }

    /// What a tag is on, named rather than counted — the count answers "does this matter", this
    /// answers "matters to what".
    private func usageDescription(of tag: Tag) -> String {
        let subjects = store.book.subjects(taggedWith: tag.id)
        guard !subjects.isEmpty else { return "‘\(tag.name)’ is not on anything" }
        let names = subjects.prefix(12).map { "\($0.kind.rawValue) \($0.id)" }
        return names.joined(separator: "\n")
            + (subjects.count > 12 ? "\n…and \(subjects.count - 12) more" : "")
    }

    /// The live inventory, by kind. Read once per use rather than held, because it is exactly
    /// the poll result — see `TagBook.removeAssignments(ofKind:notIn:)`.
    private var liveInventory: [ActivityKind: Set<String>] {
        [.container: Set(model.containers.map(\.id)),
         .machine: Set(model.machines.map(\.id)),
         .image: Set(model.images.map(\.reference)),
         .volume: Set(model.volumes.map(\.name)),
         .network: Set(model.networks.map(\.id))]
    }

    /// How many tagged subjects no longer exist.
    ///
    /// Counted against a **loaded** inventory only. A kind whose list is empty because it has not
    /// been fetched yet is indistinguishable from one that genuinely has nothing in it, and
    /// offering to clean up 40 containers because the poll has not returned is how a maintenance
    /// button becomes a data-loss button. So an empty inventory for a kind is skipped entirely.
    private var orphanCount: Int {
        let live = liveInventory
        return live.reduce(0) { total, entry in
            guard !entry.value.isEmpty else { return total }
            return total + store.book.subjects(ofKind: entry.key)
                .count { !entry.value.contains($0.id) }
        }
    }

    private func cleanUp() {
        let live = liveInventory.filter { !$0.value.isEmpty }
        let removed = store.cleanUp(live: live)
        cleanUpResult = removed == 0
            ? "Nothing to clean up."
            : "Forgot tags on \(removed) thing\(removed == 1 ? "" : "s") that no longer exist."
    }
}
