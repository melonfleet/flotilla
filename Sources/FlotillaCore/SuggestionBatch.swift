import Foundation

/// A guided walk through several ticked Suggestions (TODO item 15): queue of entry ids plus the
/// index, and the host ports already claimed by a step that was saved.
///
/// Single Use… is unchanged — this type exists only while "Use N Suggestions…" is in flight.
public struct SuggestionBatch: Equatable, Sendable {
    public var queue: [LibraryEntry.ID]
    public var index: Int
    /// Host ports taken by earlier steps that were **saved** (Create / Run), so a later form can
    /// steer clear. A Skip does not add anything.
    public var claimedPorts: Set<Int>

    public init(queue: [LibraryEntry.ID], index: Int = 0, claimedPorts: Set<Int> = []) {
        self.queue = queue
        self.index = index
        self.claimedPorts = claimedPorts
    }

    public var currentID: LibraryEntry.ID? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// "1 of 3" for the form header.
    public var progressLabel: String {
        "\(index + 1) of \(queue.count)"
    }

    public var isFinished: Bool { index >= queue.count }

    /// Move to the next entry. `ports` are recorded only when the user saved this step.
    public mutating func advance(claiming ports: Set<Int> = []) {
        claimedPorts.formUnion(ports)
        index += 1
    }
}

/// Host-port clashes among ticked suggestions, and free-port prefills for later forms.
public enum SuggestionPorts {
    /// The host ports an entry wants before anything is bumped for freedom — a container's
    /// `HOST:CONTAINER` left half, or a stack web page's preferred publish port (80 → 8080).
    public static func preferredHostPorts(for entry: LibraryEntry) -> [Int] {
        switch entry.kind {
        case .container:
            return (entry.container?.ports ?? []).compactMap(StackPlanner.hostPort(fromPublishSpec:))
        case .stack:
            return (entry.stackSuggestion?.services ?? []).compactMap { service in
                guard let web = service.webPort else { return nil }
                return preferredWebHostPort(web)
            }
        }
    }

    /// Same mapping `StackPlanner.defaultWebPorts` uses for a service's own web port.
    public static func preferredWebHostPort(_ web: Int) -> Int {
        web < 1024 ? 8000 + web : web
    }

    /// Short notes for the Suggestions list when two or more ticked entries want the same host
    /// port — e.g. "Grafana and Metabase both want port 3000; the second will suggest a free port".
    public static func clashNotes(for entries: [LibraryEntry]) -> [String] {
        var byPort: [Int: [String]] = [:]
        for entry in entries {
            for port in Set(preferredHostPorts(for: entry)) {
                byPort[port, default: []].append(entry.title)
            }
        }
        return byPort.keys.sorted().compactMap { port in
            let titles = byPort[port] ?? []
            guard titles.count >= 2 else { return nil }
            let who: String
            if titles.count == 2 {
                who = "\(titles[0]) and \(titles[1]) both want"
            } else {
                let head = titles.dropLast().joined(separator: ", ")
                who = "\(head) and \(titles.last!) all want"
            }
            let later = titles.count == 2 ? "the second" : "the later ones"
            return "\(who) port \(port); \(later) will suggest a free port"
        }
    }

    /// Rewrite a library container's `HOST:CONTAINER` ports so each host side is free given
    /// `avoiding`, published on 127.0.0.1 — the same shape single Use… builds today.
    public static func publishSpecs(for container: LibraryContainer, avoiding used: Set<Int>) -> [String] {
        var used = used
        return container.ports.compactMap { spec in
            guard let host = StackPlanner.hostPort(fromPublishSpec: spec),
                  let inside = StackPlanner.containerPort(fromPublishSpec: spec) else {
                return "127.0.0.1:\(spec)"
            }
            let free = StackPlanner.freePort(preferring: host, avoiding: used) ?? host
            used.insert(free)
            return "127.0.0.1:\(free):\(inside)"
        }
    }
}
