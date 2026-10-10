import SwiftUI
import FlotillaCore

/// ⌘K (Phase 1 leftover, research/FEATURES.md): one field that goes anywhere — a section, an action
/// such as Run Container…, or a container, group, image, volume, network, machine or host by name.
///
/// It opens things the way a click elsewhere would: a section through `requestSection`, an action
/// through the same `request…` call its menu command makes, a named thing through `requestDetail`.
/// So the palette adds no second route to any screen, and nothing it does skips a confirmation.
struct PaletteItem: Identifiable {
    enum Kind: String { case action = "Actions", section = "Sections", item = "Go to" }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    let systemImage: String
    let run: () -> Void
}

extension AppModel {
    /// Everything the palette can reach, built fresh each time it opens so it lists what is there now.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func action(_ title: String, _ image: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            guard enabled else { return }
            items.append(PaletteItem(id: "action:\(title)", kind: .action, title: title, systemImage: image, run: run))
        }
        let ready = runtimeUsable
        action("Run Container…", "play.fill", enabled: ready) { self.requestRunSheet() }
        action("New Group…", "square.stack.3d.up") { self.requestGroupForm() }
        action("Pull Image…", "arrow.down.circle", enabled: ready) { self.requestPullForm() }
        action("Build Image from Dockerfile…", "hammer", enabled: ready) { self.requestBuildForm() }
        action("New Volume…", "externaldrive.badge.plus", enabled: ready) { self.requestVolumeForm() }
        action("New Network…", "network", enabled: ready) { self.requestNetworkForm() }
        action("New Machine…", "desktopcomputer", enabled: ready) { self.requestMachineForm() }
        action("New Cluster…", "circle.hexagongrid", enabled: ready) { self.requestClusterForm() }
        action("Add Registry…", "shippingbox") { self.requestRegistryForm() }
        action("New DNS Domain…", "globe") { self.requestDNSForm() }
        action("Add Host…", "plus.rectangle.on.rectangle", enabled: hostMode.isAdmin) { self.requestAddHost() }
        action("Export Configuration…", "square.and.arrow.up") { self.requestExport() }
        action("Import Configuration…", "square.and.arrow.down") { self.requestImport() }

        for section in Section.allCases where section != .settings {
            items.append(PaletteItem(id: "section:\(section.rawValue)", kind: .section, title: section.title,
                                     systemImage: section.systemImage) { self.requestSection(section) })
        }
        items.append(PaletteItem(id: "section:settings", kind: .section, title: "Settings",
                                 systemImage: "gearshape") { self.requestSection(.settings) })

        func item(_ kind: ActivityKind, _ subject: String, _ title: String, _ subtitle: String?, _ image: String) {
            items.append(PaletteItem(id: "\(kind.rawValue):\(subject)", kind: .item, title: title,
                                     subtitle: subtitle, systemImage: image) {
                self.requestDetail(kind: kind, subject: subject)
            })
        }
        for container in containers {
            item(.container, container.id, container.id, "Container · \(container.status.state) · \(container.imageReference)", "shippingbox")
        }
        for (peer, snapshot) in hostMode.fleetContainers {
            for container in snapshot.items {
                item(.container, HostRef.peer(peer.fingerprint).rowID(container.id), container.id,
                     "Container on \(peer.displayName) · \(container.status.state)", "shippingbox")
            }
        }
        for group in groups.groups { item(.group, group.name, group.name, "Group · \(group.members.count) services", "square.stack.3d.up") }
        for image in images { item(.image, image.reference, image.reference, "Image", "square.stack") }
        for volume in volumes { item(.volume, volume.name, volume.name, "Volume", "externaldrive") }
        for network in networks where !network.isBuiltin { item(.network, network.id, network.id, "Network", "network") }
        for machine in machines { item(.machine, machine.id, machine.id, "Machine · \(machine.status)", "desktopcomputer") }
        for row in hostRows {
            items.append(PaletteItem(id: "host:\(row.id)", kind: .item, title: row.name,
                                     subtitle: row.isThisMac ? "This Mac" : "Host · \(row.status)",
                                     systemImage: "server.rack") {
                self.requestDetail(kind: .host, subject: row.id)
            })
        }
        return items
    }
}

struct CommandPalette: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    /// Every word must appear in the title or the subtitle. With nothing typed, the actions and the
    /// sections — what you can do and where you can go — rather than a list of everything.
    private var results: [PaletteItem] {
        let words = SearchQuery.tokens(query)
        guard !words.isEmpty else { return items.filter { $0.kind != .item } }
        return Array(items.filter { item in
            words.allSatisfy { SearchQuery.contains(item.title, $0) || SearchQuery.contains(item.subtitle ?? "", $0) }
        }
        .sorted { rank($0) < rank($1) }
        .prefix(60))
    }

    /// A title that starts with what was typed comes first, then the rest in the order built.
    private func rank(_ item: PaletteItem) -> Int {
        item.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil ? 0 : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a container, image, host… or an action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let shown = results
                        if shown.isEmpty {
                            Text("Nothing matches “\(query)”.")
                                .foregroundStyle(.secondary)
                                .padding(14)
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            row(item, isSelected: index == selected)
                                .id(index)
                                .onTapGesture { selected = index; openSelected() }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, now in proxy.scrollTo(now) }
            }
            .frame(maxHeight: 360)
            Divider()
            Text("↑↓ to move · Return to open · Esc to close")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 560)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            items = model.paletteItems()
            focused = true
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 8)
            Text(item.kind.rawValue).font(.caption2)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.8))
        }
        .foregroundStyle(isSelected ? Color.white : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func move(_ step: Int) {
        let count = results.count
        guard count > 0 else { return }
        selected = (selected + step + count) % count
    }

    private func openSelected() {
        let shown = results
        guard shown.indices.contains(selected) else { return }
        let item = shown[selected]
        dismiss()
        item.run()
    }
}
