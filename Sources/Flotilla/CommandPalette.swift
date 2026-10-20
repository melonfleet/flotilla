import SwiftUI
import FlotillaCore

/// What the window bar's search box can reach (DECISIONS Q55): a section, an action such as Run
/// Container…, or a container, group, image, volume, network, machine or host by name. It was the
/// floating ⌘K palette's list; the palette is gone and the box's dropdown (`ToolbarSearch`) lists these.
///
/// It opens things the way a click elsewhere would: a section through `requestSection`, an action
/// through the same `request…` call its menu command makes, a named thing through `requestDetail`.
/// So the box adds no second route to any screen, and nothing it does skips a confirmation.
struct PaletteItem: Identifiable {
    enum Kind: String { case action = "Actions", section = "Sections", item = "Go to" }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    let systemImage: String
    var scope: SearchBox.Scope? = nil
    var completion: SearchBox.Scope? = nil
    var slugs: [String] = []
    var libraryEntry: LibraryEntry? = nil
    var suggestion: SuggestionItem? = nil
    let run: () -> Void
}

extension AppModel {
    /// Everything the box can reach, built fresh as it gains focus and as you type, so it lists what is there now.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        // Weakly: the model owns the box that holds these, so a strong capture is a cycle.
        func weakly(_ run: @escaping (AppModel) -> Void) -> () -> Void {
            { [weak self] in if let self { run(self) } }
        }
        func action(_ title: String, _ image: String, enabled: Bool = true, _ run: @escaping (AppModel) -> Void) {
            guard enabled else { return }
            items.append(PaletteItem(id: "action:\(title)", kind: .action, title: title, systemImage: image, slugs: SearchBox.commandSlugs(for: title), run: weakly(run)))
        }
        let ready = runtimeUsable
        action("Run Container…", "play.fill", enabled: ready) { $0.requestRunSheet() }
        action("New Group…", "square.stack.3d.up") { $0.requestGroupForm() }
        action("Pull Image…", "arrow.down.circle", enabled: ready) { $0.requestPullForm() }
        action("Build Image from Dockerfile…", "hammer", enabled: ready) { $0.requestBuildForm() }
        action("New Volume…", "externaldrive.badge.plus", enabled: ready) { $0.requestVolumeForm() }
        action("New Network…", "network", enabled: ready) { $0.requestNetworkForm() }
        action("New Machine…", "desktopcomputer", enabled: ready) { $0.requestMachineForm() }
        action("New Cluster…", "circle.hexagongrid", enabled: ready) { $0.requestClusterForm() }
        action("Add Registry…", "shippingbox") { $0.requestRegistryForm() }
        action("New DNS Domain…", "globe") { $0.requestDNSForm() }
        action("Add Host…", "plus.rectangle.on.rectangle", enabled: hostMode.isAdmin) { $0.requestAddHost() }
        action("Export Configuration…", "square.and.arrow.up") { $0.requestExport() }
        action("Import Configuration…", "square.and.arrow.down") { $0.requestImport() }

        for section in Section.allCases where section != .settings {
            items.append(PaletteItem(id: "section:\(section.rawValue)", kind: .section, title: section.title,
                                     systemImage: section.systemImage, slugs: SearchBox.commandSlugs(for: section.title), run: weakly { $0.requestSection(section) }))
        }
        items.append(PaletteItem(id: "section:settings", kind: .section, title: "Settings",
                                 systemImage: "gearshape", slugs: SearchBox.commandSlugs(for: "Settings"), run: weakly { $0.requestSection(.settings) }))

        func item(_ kind: ActivityKind, _ subject: String, _ title: String, _ subtitle: String?, _ image: String) {
            items.append(PaletteItem(id: "\(kind.rawValue):\(subject)", kind: .item, title: title,
                                     subtitle: subtitle, systemImage: image, scope: SearchBox.Scope(rawValue: kind.rawValue),
                                     run: weakly { $0.requestDetail(kind: kind, subject: subject) }))
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
        for group in groups.groups {
            item(.group, group.id, group.name,
                 "Group on \(hostMode.hostName(group.place, local: hostLabel)) · \(group.members.count) services", "square.stack.3d.up")
        }
        for image in images { item(.image, image.reference, image.reference, "Image", "square.stack") }
        for volume in volumes { item(.volume, volume.name, volume.name, "Volume", "externaldrive") }
        for network in networks { item(.network, network.id, network.id, "Network", "network") }
        for machine in machines { item(.machine, machine.id, machine.id, "Machine · \(machine.status)", "desktopcomputer") }
        for row in hostRows {
            items.append(PaletteItem(id: "host:\(row.id)", kind: .item, title: row.name,
                                     subtitle: row.isThisMac ? "This Mac" : "Host · \(row.status)",
                                     systemImage: "server.rack", scope: .host,
                                     run: weakly { $0.requestDetail(kind: .host, subject: row.id) }))
        }
        for (peer, snapshot) in hostMode.fleetImages {
            for image in snapshot.items {
                item(.image, HostRef.peer(peer.fingerprint).rowID(image.reference), image.reference,
                     "Image on \(peer.displayName)", "square.stack")
            }
        }
        for (peer, snapshot) in hostMode.fleetVolumes {
            for volume in snapshot.items {
                item(.volume, HostRef.peer(peer.fingerprint).rowID(volume.name), volume.name,
                     "Volume on \(peer.displayName)", "externaldrive")
            }
        }
        for (peer, snapshot) in hostMode.fleetNetworks {
            for network in snapshot.items {
                item(.network, HostRef.peer(peer.fingerprint).rowID(network.id), network.id,
                     "Network on \(peer.displayName)", "network")
            }
        }
        for cluster in clusters { item(.cluster, cluster.node, cluster.name, "Cluster", "circle.hexagongrid") }
        for (peer, snapshot) in hostMode.fleetClusters {
            for cluster in snapshot.items {
                item(.cluster, HostRef.peer(peer.fingerprint).rowID(cluster.node), cluster.name,
                     "Cluster on \(peer.displayName)", "circle.hexagongrid")
            }
        }
        for row in hostedDNS { item(.dns, row.id, row.name, "DNS on \(row.hostName)", "globe") }
        for row in registryRows { item(.registry, row.id, row.name, row.summary, "shippingbox") }
        for notice in notices.book.notices {
            items.append(PaletteItem(id: "notification:\(notice.id)", kind: .item, title: notice.title,
                                     subtitle: notice.text, systemImage: "bell", scope: .notification,
                                     run: weakly { $0.requestNotice(notice.id) }))
        }
        for item in SuggestionCatalogue(library: suggestionLibrary).items {
            items.append(PaletteItem(id: "suggestion:\(item.id)", kind: .item, title: item.title,
                                     subtitle: "\(item.tab.rawValue) · \(item.summary)",
                                     systemImage: item.tab.systemImage, scope: .suggestion,
                                     libraryEntry: item.libraryEntry, suggestion: item,
                                     run: weakly { $0.requestSuggestion(item.id) }))
        }
        for scope in SearchBox.Scope.allCases {
            items.append(PaletteItem(id: "scope:\(scope.rawValue)", kind: .item,
                                     title: scope.rawValue + ":", subtitle: "Search \(scope.plural) on all Macs",
                                     systemImage: "magnifyingglass", completion: scope, run: {}))
        }
        return items
    }
}
