import SwiftUI
import FlotillaCore

/// A group header in the Hosts table: one value of the category Hosts is grouped by, and the
/// hosts under it (the owner, 9 October). A row of its own, because `Table` has one row type —
/// the same arrangement as a container group's row.
struct HostGroupHeader: Hashable {
    /// The value, or nil for the hosts with none.
    let value: String?
    /// "Rack R1", "No rack", "10.20.4.0/24", "No subnet".
    let title: String
    let hostIDs: [String]
    let connected: Int
}

/// What a header row's dot says about its hosts: all connected, some, or none.
struct HostGroupDot: View {
    let header: HostGroupHeader

    var body: some View {
        Group {
            if header.connected == header.hostIDs.count {
                Circle().fill(Theme.online)
            } else if header.connected > 0 {
                ZStack {
                    Circle().strokeBorder(Theme.online, lineWidth: 1.2)
                    Circle().fill(Theme.online).mask(HStack(spacing: 0) { Rectangle(); Color.clear })
                }
            } else {
                Circle().fill(Color.secondary)
            }
        }
        .frame(width: 8, height: 8)
        .help("\(header.connected) of \(header.hostIDs.count) connected")
        .accessibilityLabel("\(header.connected) of \(header.hostIDs.count) connected")
    }
}

/// **Group By**, in the Hosts toolbar: none, the subnet Flotilla works out, or one of the owner's
/// categories — and the way to edit them.
struct HostGroupByMenu: View {
    let store: HostCategoryStore
    @Binding var grouping: HostGrouping
    let editCategories: () -> Void

    var body: some View {
        ToolbarIconMenu(systemImage: grouping == .none ? "rectangle.3.group" : "rectangle.3.group.fill",
                        label: grouping == .none ? "Group hosts" : "Grouped by \(title(grouping))") {
            Picker("Group By", selection: $grouping) {
                Text("None").tag(HostGrouping.none)
                Divider()
                Text(HostCategoryBook.subnetName).tag(HostGrouping.subnet)
                ForEach(store.categories) { Text($0.name).tag(HostGrouping.category($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Edit Categories…", action: editCategories)
        }
    }

    private func title(_ grouping: HostGrouping) -> String {
        switch grouping {
        case .none: "None"
        case .subnet: HostCategoryBook.subnetName
        case .category(let id): store.book.category(id: id)?.name ?? "a category"
        }
    }
}

/// The **Group** submenu on a host's row menu and in the bulk bar: for each category, the values
/// in use (ticked where it applies), a new one, or none. Applies to every host given.
struct HostCategoryMenu: View {
    let store: HostCategoryStore
    let hosts: [String]
    let newValue: (HostCategory) -> Void
    let editCategories: () -> Void

    var body: some View {
        Menu("Group") {
            ForEach(store.categories) { category in
                Menu(category.name) {
                    ForEach(store.book.values(in: category.id), id: \.self) { value in
                        let on = hosts.allSatisfy { store.value(category, for: $0) == value }
                        Button {
                            store.setValue(on ? nil : value, of: category, for: hosts)
                        } label: {
                            if on { Label(value, systemImage: "checkmark") } else { Text(value) }
                        }
                    }
                    if !store.book.values(in: category.id).isEmpty { Divider() }
                    Button("New \(category.name)…") { newValue(category) }
                    Button("None") { store.setValue(nil, of: category, for: hosts) }
                        .disabled(hosts.allSatisfy { store.value(category, for: $0) == nil })
                }
            }
            if !store.categories.isEmpty { Divider() }
            Button("Edit Categories…", action: editCategories)
        }
    }
}

/// Typing a new value for one category, for one host or several.
struct HostValueSheet: View {
    let store: HostCategoryStore
    let category: HostCategory
    let hosts: [String]
    let dismiss: () -> Void

    @State private var value = ""

    var body: some View {
        ModalCard(title: "New \(category.name)", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 12) {
                Text(hosts.count == 1 ? "For this host." : "For the \(hosts.count) selected hosts.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField(category.name, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Set", action: save).keyboardShortcut(.defaultAction)
                        .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(width: 300)
            .padding(16)
        }
    }

    private func save() {
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.setValue(value, of: category, for: hosts)
        dismiss()
    }
}

/// Adding, renaming, reordering and removing categories, with the suggestions one click away.
/// Subnet is listed but fixed: Flotilla fills it in.
struct HostCategoriesSheet: View {
    let store: HostCategoryStore
    let dismiss: () -> Void

    @State private var newName = ""
    @State private var removing: HostCategory?

    private var problem: String? {
        newName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : store.book.problem(withName: newName)
    }

    var body: some View {
        ModalCard(title: "Host Categories", onClose: dismiss) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Group hosts by any of these in Hosts ▸ Group By, and set a host's value from its menu or its page. Kept on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List {
                    HStack {
                        Image(systemName: "network").foregroundStyle(.secondary).frame(width: 16)
                        Text(HostCategoryBook.subnetName)
                        Spacer()
                        Text("Filled in by Flotilla").font(.caption).foregroundStyle(.tertiary)
                    }
                    .moveDisabled(true)
                    ForEach(store.categories) { category in
                        CategoryRow(store: store, category: category) { removing = category }
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: 220)
                .listStyle(.bordered)

                HStack {
                    TextField("New category", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || problem != nil)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Theme.danger)
                }
                if !store.book.unusedSuggestions.isEmpty {
                    HStack(spacing: 6) {
                        Text("Suggestions:").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.book.unusedSuggestions, id: \.self) { name in
                            Button(name) { store.addCategory(named: name) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 460)
            .padding(16)
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { category in
            Button("Remove", role: .destructive) { store.remove(category) }
            Button("Cancel", role: .cancel) {}
        } message: { category in
            let used = store.book.values.values.filter { $0[category.id] != nil }.count
            Text(used == 0 ? "No host has a value in it."
                           : "\(used) host\(used == 1 ? "" : "s") lose\(used == 1 ? "s" : "") \(used == 1 ? "its" : "their") \(category.name). Hosts themselves are not touched.")
        }
    }

    private func add() {
        guard problem == nil, store.addCategory(named: newName) != nil else { return }
        newName = ""
    }

    /// One category: its name, editable in place, and Remove.
    private struct CategoryRow: View {
        let store: HostCategoryStore
        let category: HostCategory
        let remove: () -> Void
        @State private var name = ""

        var body: some View {
            HStack {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).frame(width: 16)
                    .help("Drag to reorder")
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit { commit() }
                    .onChange(of: name) { _, _ in commit() }
                Spacer()
                let count = store.book.values(in: category.id).count
                Text(count == 0 ? "No values" : "\(count) value\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.tertiary)
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove \(category.name)")
            }
            .onAppear { name = category.name }
        }

        /// Saved as typed when the name is usable; an unusable one is left in the field unsaved.
        private func commit() {
            guard name != category.name, store.book.problem(withName: name, excluding: category.id) == nil else { return }
            store.rename(category, to: name)
        }
    }
}

extension AppModel {
    /// The network a Mac is reached on, as `10.20.4.0/24`: for a host, the interface holding the
    /// address this Mac connects to (else that address's /24); for This Mac, its first interface.
    func subnet(of host: HostRef) -> String? {
        guard case .peer(let fingerprint) = host else {
            return (systemFacts?.ipv4Interfaces?.first).flatMap(HostGrouping.subnet(ofCIDR:))
        }
        let interfaces = hostMode.facts[fingerprint]?.ipv4Interfaces ?? []
        if let address = HostConnect.address(self, fingerprint) {
            if let cidr = interfaces.first(where: { HostGrouping.contains(HostGrouping.subnet(ofCIDR: $0) ?? "", address) }) {
                return HostGrouping.subnet(ofCIDR: cidr)
            }
            return HostGrouping.subnet(of: address)
        }
        return interfaces.first.flatMap(HostGrouping.subnet(ofCIDR:))
    }
}

/// A host's value in one category, on its page: type a value, or pick one already in use.
struct HostCategoryValueField: View {
    let store: HostCategoryStore
    let category: HostCategory
    let host: String

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(category.name).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            TextField("None", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
                .frame(maxWidth: 160)
            let values = store.book.values(in: category.id)
            Menu {
                ForEach(values, id: \.self) { value in
                    Button(value) { text = value; commit() }
                }
                if !values.isEmpty { Divider() }
                Button("None") { text = ""; commit() }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick a \(category.name) already in use")
        }
        .onAppear { text = store.value(category, for: host) ?? "" }
        .onChange(of: store.value(category, for: host)) { _, now in if !focused { text = now ?? "" } }
    }

    private func commit() {
        guard text.trimmingCharacters(in: .whitespaces) != (store.value(category, for: host) ?? "") else { return }
        store.setValue(text, of: category, for: [host])
    }
}
