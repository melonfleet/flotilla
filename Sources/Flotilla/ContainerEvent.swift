import Foundation
import FlotillaCore

/// How a kind is drawn. The kind itself is `FlotillaCore.ActivityKind` — moved there so
/// `BusySet` could key on it and still be testable; see its docstring. These three members
/// stayed behind because they are presentation: `section` names an app-only type, and SF Symbol
/// names have no place in a Foundation-only core.
extension ActivityKind {
    var title: String {
        switch self {
        case .container: "Containers"
        case .group: "Groups"
        case .cluster: "Kubernetes"
        case .machine: "Machines"
        case .image: "Images"
        case .volume: "Volumes"
        case .network: "Networks"
        case .runtime: "Runtime"
        case .registry: "Registries"
        case .dns: "DNS"
        case .host: "Hosts"
        }
    }

    /// The same glyph the sidebar uses for that section, so the feed reads as a view *onto* the
    /// sections rather than as a separate inventory.
    var systemImage: String {
        switch self {
        case .container: "shippingbox"
        case .group: "rectangle.3.group"
        // Verified present, per the `ellipsis.vertical` incident.
        case .cluster: "circle.hexagongrid"
        case .machine: "server.rack"
        case .image: "square.stack.3d.up"
        case .volume: "cylinder.split.1x2"
        case .network: "network"
        case .runtime: "gearshape.2"
        case .registry: Section.registries.systemImage
        case .dns: Section.dns.systemImage
        case .host: Section.hosts.systemImage
        }
    }

    /// Where a feed row should take you when clicked.
    var section: Section {
        switch self {
        case .container: .containers
        // Groups are rows in Containers now, so a group's activity opens there.
        case .group: .containers
        case .cluster: .clusters
        case .machine: .machines
        case .image: .images
        case .volume: .volumes
        case .network: .networks
        // The runtime banner lives on the dashboard, so that is where a runtime row leads.
        case .runtime: .hosts
        case .registry: .registries
        case .dns: .dns
        case .host: .hosts
        }
    }
}

/// Something that happened to a container or machine — either a transition Flotilla observed,
/// or an action it performed.
///
/// It used to be observations only, and that had a hole: **a restart never appeared in the
/// Activity feed.** The poll loop compares one refresh with the next, and a restart of a
/// running thing ends where it began, so there is no change to see. Start and stop each leave a
/// lasting state, which is why those two did show up. Waiting for a faster poll would not fix
/// it either — the stop and the start can both land between two polls.
///
/// So an action that has no net state change has to be recorded by whoever performs it. `action`
/// is set in that case and left nil for an observed transition, which keeps the two
/// distinguishable rather than dressing one up as the other.
///
/// Observations still matter and are still recorded: they are the only way a change made outside
/// Flotilla — someone running `container stop` in a terminal — reaches the feed at all.
struct ContainerEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let from: String
    let to: String

    /// Which kind of thing this happened to, and which one.
    ///
    /// Added so a single feed can carry every resource kind. There used to be two separate
    /// dictionaries — containers and machines — and images, volumes and networks recorded
    /// nothing at all, so there was no place to ask "what has changed on this Mac?". Three more
    /// dictionaries would have made that worse; one flat log answers it directly and the
    /// per-subject lists the detail views want are a filter over it.
    var kind: ActivityKind = .container
    var subject: String = ""

    /// Set when this records an action Flotilla performed; nil for an observed transition.
    var action: String?

    /// Plain language, because "running → stopped" makes the reader do the translation.
    var summary: String {
        if let action { return action }
        switch to.lowercased() {
        case "running": return from.lowercased() == "stopped" ? "Started" : "Running"
        case "stopped": return "Stopped"
        default: return to.capitalized
        }
    }

    var detail: String { "from \(from.lowercased())" }

    // MARK: As a row

    /// Kinds whose subject is a name that can carry " on <Mac>" — a paired host's event is recorded
    /// as "web on mac-mini" (`AppModel.events(for:kind:host:)`), and so is a remote DNS zone's. A
    /// host's or registry's subject is its own name, and is left whole.
    private var namesAMac: Bool {
        switch kind {
        case .container, .machine, .image, .volume, .network, .group, .cluster, .dns: true
        case .runtime, .registry, .host: false
        }
    }

    /// Splits " on <Mac>" off the subject, but only when what follows is the display name of a Mac
    /// Flotilla knows. A subject is free text — "db on call" is a plausible container name — so
    /// the text after an " on " is not evidence of a host by itself; anything unrecognised is
    /// This Mac with the subject whole. Matching the known name as a suffix, longest first, also
    /// keeps a host whose own name contains " on " from being cut in the middle.
    ///
    /// The host is not stored on the event: subjects are the key the per-page feeds filter on
    /// (`AppModel.events(for:kind:host:)`), so a separate field would have to be kept in step with
    /// every one of those sites. `hosts` is the paired Macs' display names.
    private func hostSplit(_ hosts: Set<String>) -> (name: String, host: String)? {
        guard namesAMac else { return nil }
        for host in hosts.sorted(by: { $0.count > $1.count }) where !host.isEmpty {
            let suffix = " on " + host
            if subject.hasSuffix(suffix), subject.count > suffix.count {
                return (String(subject.dropLast(suffix.count)), host)
            }
        }
        return nil
    }

    /// The subject without its " on <Mac>".
    func subjectName(hosts: Set<String>) -> String { hostSplit(hosts)?.name ?? subject }

    /// Which other Mac this happened on, or nil for This Mac.
    func hostName(hosts: Set<String>) -> String? { hostSplit(hosts)?.host }

    /// What a row says first: "Started web". An observed appearance or disappearance reads as
    /// "Added" or "Removed" — `summary` says "Present", which is a state, not a thing that happened.
    func headline(hosts: Set<String>) -> String { "\(verb) \(subjectName(hosts: hosts))" }

    /// What happened, as a verb.
    var verb: String {
        switch (action, to.lowercased()) {
        case (let action?, _): action
        case (nil, "present"): "Added"
        case (nil, "absent"): "Removed"
        default: summary
        }
    }

    /// The raw transition, only when there is one. A performed action reads "running → running",
    /// which means nothing.
    var transition: String? {
        guard action == nil, !from.isEmpty, !["present", "absent"].contains(to.lowercased()) else { return nil }
        return "\(from) \u{2192} \(to)"
    }
}
