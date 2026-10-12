import Foundation

// The suggestions library (the owner, 12 October; DECISIONS Q54): many ready-made containers and
// stacks, browsed by category in Suggestions. Flotilla ships a built-in copy and, later, fetches a
// signed newer one from GitHub once a day.
//
// **A library file is untrusted input.** Whatever its signature says, every entry is checked here
// before it is shown — the same rules the Allowlist applies to anything typed, plus the library's
// own: no folders from the Mac, a pinned tag, no password written into the file, and only the
// placeholders the stack planner fills. An entry that fails is dropped and named, never repaired.
// Nothing here runs anything: an entry fills in the Run form or a stack's form, which validate again.

public struct SuggestionLibrary: Sendable, Codable, Equatable {
    /// The format; a newer one this build can't read is refused, and the built-in copy is used.
    public static let currentSchema = 1
    /// The categories an entry may name, in browsing order (the Gemini research brief).
    public static let categories = [
        "Education", "Business & Office", "Finance & Accounting", "E-commerce", "Software Development",
        "Databases", "Data & Analytics", "AI & Machine Learning", "Monitoring & Operations",
        "Security & Identity", "Networking & Web Servers", "Content & Publishing",
        "Communication & Collaboration", "Storage & Files", "Media & Photos", "Home & Personal",
        "Science & Research", "Messaging & Queues",
    ]
    public static let maxEntries = 1000

    public var schema: Int
    /// Newer replaces older: `2026.10.12.1`, compared number by number.
    public var version: String
    public var entries: [LibraryEntry]

    public init(schema: Int = Self.currentSchema, version: String, entries: [LibraryEntry]) {
        self.schema = schema
        self.version = version
        self.entries = entries
    }

    /// Only the entries that pass every check, with why each other one was dropped.
    public func checked() -> (library: SuggestionLibrary, dropped: [(id: String, problem: String)]) {
        var kept: [LibraryEntry] = []
        var dropped: [(String, String)] = []
        var seen = Set<String>()
        for entry in entries.prefix(Self.maxEntries) {
            if let problem = entry.problem() { dropped.append((entry.id, problem)); continue }
            guard seen.insert(entry.id).inserted else { dropped.append((entry.id, "Its id is used twice.")); continue }
            kept.append(entry)
        }
        if entries.count > Self.maxEntries { dropped.append(("…", "More than \(Self.maxEntries) entries; the rest were ignored.")) }
        return (SuggestionLibrary(schema: schema, version: version, entries: kept), dropped)
    }

    /// Whether `other` is a newer version than this one.
    public func isOlder(than other: SuggestionLibrary) -> Bool {
        let mine = version.split(separator: ".").map { Int($0) ?? 0 }
        let theirs = other.version.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < theirs.count ? theirs[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}

public struct LibraryEntry: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case container, stack }

    public var id: String
    public var title: String
    public var summary: String
    /// One to three of `SuggestionLibrary.categories`, the main one first.
    public var categories: [String]
    public var kind: Kind
    /// Said plainly where a licence is not a permissive open-source one.
    public var licenceNote: String?
    /// When and on how many Macs it was last run and passed. `nil`: not live-tested.
    public var tested: Tested?
    public var container: LibraryContainer?
    public var stack: LibraryStack?

    public struct Tested: Sendable, Codable, Equatable {
        public var date: String
        public var macs: Int
        public init(date: String, macs: Int) { self.date = date; self.macs = macs }
    }

    public init(id: String, title: String, summary: String, categories: [String], kind: Kind,
                licenceNote: String? = nil, tested: Tested? = nil,
                container: LibraryContainer? = nil, stack: LibraryStack? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.categories = categories
        self.kind = kind; self.licenceNote = licenceNote; self.tested = tested
        self.container = container; self.stack = stack
    }

    /// The images it pulls.
    public var images: [String] {
        switch kind {
        case .container: container.map { [$0.image] } ?? []
        case .stack: stack?.services.map(\.image) ?? []
        }
    }

    /// Why it can't be offered, or `nil`.
    public func problem() -> String? {
        guard Allowlist.accepts(id, as: .identifier), id.count <= 64 else { return "Its id isn't a plain name." }
        guard (1...80).contains(title.count), summary.count <= 240 else { return "Its title or summary is too long." }
        guard (1...3).contains(categories.count),
              categories.allSatisfy(SuggestionLibrary.categories.contains) else {
            return "Its categories aren't from the library's list."
        }
        if let note = licenceNote, note.count > 400 { return "Its licence note is too long." }
        switch kind {
        case .container:
            guard let container, stack == nil else { return "A container entry must describe one container." }
            return container.problem()
        case .stack:
            guard let stack, container == nil else { return "A stack entry must describe its services." }
            return stack.problem()
        }
    }

    /// As one of the stack suggestions the stack form already builds from.
    public var stackSuggestion: StackSuggestion? {
        guard kind == .stack, let stack else { return nil }
        return StackSuggestion(
            id: id, title: title, summary: summary, licenceNote: licenceNote,
            options: stack.options.map { StackOption(id: $0.id, label: $0.label, defaultValue: $0.defaultValue,
                                                     help: $0.help, kind: $0.email ? .email : .identifier) },
            services: stack.services.map { service in
                StackService(role: service.role, title: service.title, image: service.image, env: service.env,
                             secretEnv: service.secretEnv.map { SecretEnv(name: $0.name, secret: $0.secret) },
                             volumes: service.volumes.map { StackVolume(suffix: $0.suffix, path: $0.path) },
                             webPort: service.webPort, wiredPort: service.wiredPort,
                             readyPort: service.readyPort, command: service.command)
            },
            notes: stack.notes, opens: stack.opens)
    }
}

/// A named volume a library entry mounts. Never a folder on the Mac.
public struct LibraryVolume: Sendable, Codable, Equatable {
    public var suffix: String
    public var path: String
    public init(suffix: String = "data", path: String) { self.suffix = suffix; self.path = path }

    func problem() -> String? {
        guard Allowlist.accepts(suffix, as: .identifier) else { return "A volume's name isn't a plain name." }
        guard path.hasPrefix("/"), path.count <= 200, !path.split(separator: "/").contains(".."),
              path.allSatisfy({ !$0.isWhitespace && $0 != ":" }) else {
            return "A volume path isn't an absolute path inside the container."
        }
        return nil
    }
}

/// A Keychain-held variable in a stack, or a generated one for a container.
public struct LibrarySecret: Sendable, Codable, Equatable {
    public var name: String
    public var secret: String
    public init(name: String, secret: String) { self.name = name; self.secret = secret }
}

public struct LibraryContainer: Sendable, Codable, Equatable {
    public var image: String
    /// The container's name, before Flotilla moves it past any already taken.
    public var name: String
    /// `HOST:CONTAINER`, published on 127.0.0.1 by the Run form.
    public var ports: [String]
    /// `NAME=value`. Never a password: those are `secretEnv`, generated when used.
    public var env: [String]
    /// Variables given a generated password when the entry is used.
    public var secretEnv: [String]
    public var volumes: [LibraryVolume]
    public var command: [String]
    /// Something to know before running it.
    public var note: String?

    public init(image: String, name: String, ports: [String] = [], env: [String] = [],
                secretEnv: [String] = [], volumes: [LibraryVolume] = [], command: [String] = [],
                note: String? = nil) {
        self.image = image; self.name = name; self.ports = ports; self.env = env
        self.secretEnv = secretEnv; self.volumes = volumes; self.command = command; self.note = note
    }

    func problem() -> String? {
        if let problem = Library.imageProblem(image) { return problem }
        guard Allowlist.accepts(name, as: .identifier) else { return "Its container name isn't a plain name." }
        for port in ports where Library.portProblem(port) != nil { return Library.portProblem(port) }
        for value in env where Library.envProblem(value, templates: false) != nil {
            return Library.envProblem(value, templates: false)
        }
        guard secretEnv.allSatisfy(Library.isEnvironmentName) else { return "A password variable's name isn't a variable name." }
        if let problem = volumes.lazy.compactMap({ $0.problem() }).first { return problem }
        if let problem = Library.commandProblem(command) { return problem }
        if let note, note.count > 400 { return "Its note is too long." }
        return nil
    }
}

public struct LibraryStack: Sendable, Codable, Equatable {
    public struct Option: Sendable, Codable, Equatable {
        public var id: String
        public var label: String
        public var defaultValue: String
        public var help: String
        public var email: Bool
        public init(id: String, label: String, defaultValue: String, help: String, email: Bool = false) {
            self.id = id; self.label = label; self.defaultValue = defaultValue; self.help = help; self.email = email
        }
    }

    public struct Service: Sendable, Codable, Equatable {
        public var role: String
        public var title: String
        public var image: String
        public var env: [String]
        public var secretEnv: [LibrarySecret]
        public var volumes: [LibraryVolume]
        public var webPort: Int?
        public var wiredPort: Int?
        public var readyPort: Int?
        public var command: [String]
        public init(role: String, title: String, image: String, env: [String] = [], secretEnv: [LibrarySecret] = [],
                    volumes: [LibraryVolume] = [], webPort: Int? = nil, wiredPort: Int? = nil,
                    readyPort: Int? = nil, command: [String] = []) {
            self.role = role; self.title = title; self.image = image; self.env = env; self.secretEnv = secretEnv
            self.volumes = volumes; self.webPort = webPort; self.wiredPort = wiredPort
            self.readyPort = readyPort; self.command = command
        }
    }

    public var options: [Option]
    /// In start order: databases first.
    public var services: [Service]
    public var notes: [String]
    /// The role whose page "Open" opens.
    public var opens: String?

    public init(options: [Option] = [], services: [Service], notes: [String] = [], opens: String? = nil) {
        self.options = options; self.services = services; self.notes = notes; self.opens = opens
    }

    func problem() -> String? {
        guard (1...6).contains(services.count) else { return "A stack has one to six services." }
        let roles = services.map(\.role)
        guard Set(roles).count == roles.count, roles.allSatisfy({ Allowlist.accepts($0, as: .identifier) && $0.count <= 24 })
        else { return "Its service roles aren't distinct plain names." }
        for option in options {
            guard Allowlist.accepts(option.id, as: .identifier), !option.label.isEmpty, option.label.count <= 60,
                  option.help.count <= 240 else { return "One of its settings is malformed." }
            let probe = StackOption(id: option.id, label: option.label, defaultValue: option.defaultValue,
                                    help: option.help, kind: option.email ? .email : .identifier)
            if let problem = probe.problem(with: option.defaultValue) { return "\(option.label): \(problem)" }
        }
        let optionIDs = Set(options.map(\.id))
        for service in services {
            if let problem = Library.imageProblem(service.image) { return problem }
            guard !service.title.isEmpty, service.title.count <= 60 else { return "A service's title is missing or too long." }
            for port in [service.webPort, service.wiredPort, service.readyPort].compactMap({ $0 })
            where !(1...65535).contains(port) { return "\(port) isn't a port." }
            for value in service.env {
                if let problem = Library.envProblem(value, templates: true) { return problem }
                // Only the placeholders the planner fills, naming things that exist.
                for token in Library.placeholders(in: value) {
                    let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return "“{{\(token)}}” isn't a placeholder Flotilla fills." }
                    switch parts[0] {
                    case "option" where optionIDs.contains(parts[1]): continue
                    case "host", "port":
                        guard let target = services.first(where: { $0.role == parts[1] }), target.wiredPort != nil
                        else { return "“{{\(token)}}” names a service other services can't reach." }
                    default: return "“{{\(token)}}” isn't a placeholder Flotilla fills."
                    }
                }
            }
            guard service.secretEnv.allSatisfy({ Library.isEnvironmentName($0.name) && Allowlist.accepts($0.secret, as: .identifier) })
            else { return "A password variable is malformed." }
            if let problem = service.volumes.lazy.compactMap({ $0.problem() }).first { return problem }
            if let problem = Library.commandProblem(service.command) { return problem }
        }
        if let opens, !roles.contains(opens) { return "It opens a service it doesn't have." }
        guard notes.count <= 8, notes.allSatisfy({ $0.count <= 400 }) else { return "Its notes are too long." }
        return nil
    }
}

/// The rules shared by containers and stacks.
enum Library {
    static func imageProblem(_ image: String) -> String? {
        guard Allowlist.accepts(image, as: .imageReference) else { return "“\(image)” isn't an image reference." }
        guard let tag = image.split(separator: "/").last?.split(separator: ":").dropFirst().first, !tag.isEmpty,
              tag != "latest" else { return "“\(image)” isn't pinned to a version." }
        return nil
    }

    /// `HOST:CONTAINER`, the host side 1024 or above.
    static func portProblem(_ spec: String) -> String? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let host = Int(parts[0]), let inside = Int(parts[1]),
              (1024...65535).contains(host), (1...65535).contains(inside) else {
            return "“\(spec)” isn't a port pair with a port from 1024 on this Mac."
        }
        return nil
    }

    static func envProblem(_ value: String, templates: Bool) -> String? {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isEnvironmentName(String(parts[0])) else { return "“\(value.prefix(40))” isn't NAME=value." }
        guard value.count <= 512, !value.contains(where: { $0.isNewline }) else { return "A variable's value is too long." }
        if !templates, value.contains("{{") { return "A container entry can't use placeholders." }
        // A password belongs in `secretEnv`, generated when used, never in the file.
        let name = parts[0].uppercased()
        if ["PASSWORD", "SECRET", "TOKEN", "API_KEY", "PRIVATE_KEY"].contains(where: name.contains),
           !parts[1].hasPrefix("{{") {
            return "\(parts[0]) looks like a password: it must be generated, not written in the library."
        }
        return nil
    }

    static func commandProblem(_ command: [String]) -> String? {
        guard command.count <= 16, command.allSatisfy({ $0.count <= 256 && !$0.contains(where: \.isNewline) }) else {
            return "Its command is too long."
        }
        guard !command.contains(where: { $0.contains("$(") || $0.contains("${") || $0.contains("`") }) else {
            return "Its command expects a shell, and none runs it."
        }
        return nil
    }

    static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
              name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    static func placeholders(in value: String) -> [String] {
        var found: [String] = []
        var rest = Substring(value)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            found.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return found
    }
}

// MARK: The built-in copy

extension SuggestionLibrary {
    /// What Flotilla ships: the tested stacks and Greta's tested containers, so the library is
    /// never empty and works without a network.
    public static let builtIn: SuggestionLibrary = {
        let stackCategories: [String: [String]] = [
            "postgres": ["Databases", "Software Development"],
            "wordpress": ["Content & Publishing", "Business & Office"],
            "redis": ["Databases", "Messaging & Queues"],
            "mysql": ["Databases", "Software Development"],
            "monitoring": ["Monitoring & Operations", "Data & Analytics"],
        ]
        let containerCategories: [String: [String]] = [
            "postgres": ["Databases"], "mariadb": ["Databases"], "mysql": ["Databases"],
            "redis": ["Databases", "Messaging & Queues"], "prometheus": ["Monitoring & Operations"],
            "grafana": ["Monitoring & Operations", "Data & Analytics"], "pgadmin": ["Databases"],
            "nginx": ["Networking & Web Servers"],
        ]
        var entries: [LibraryEntry] = StackSuggestion.catalogue.map { stack in
            LibraryEntry(
                id: "\(stack.id)-stack", title: stack.title, summary: stack.summary,
                categories: stackCategories[stack.id] ?? ["Software Development"], kind: .stack,
                licenceNote: stack.licenceNote, tested: .init(date: "2026-10-06", macs: 1),
                stack: LibraryStack(
                    options: stack.options.map { .init(id: $0.id, label: $0.label, defaultValue: $0.defaultValue,
                                                       help: $0.help, email: $0.kind == .email) },
                    services: stack.services.map { service in
                        .init(role: service.role, title: service.title, image: service.image, env: service.env,
                              secretEnv: service.secretEnv.map { .init(name: $0.name, secret: $0.secret) },
                              volumes: service.volumes.map { .init(suffix: $0.suffix, path: $0.path) },
                              webPort: service.webPort, wiredPort: service.wiredPort,
                              readyPort: service.readyPort, command: service.command)
                    },
                    notes: stack.notes, opens: stack.opens))
        }
        for recipe in GretaRouter.recipes {
            // Passwords become generated variables; everything else as tested.
            let secrets = recipe.env.filter { $0.hasSuffix("=change-me") }.map { String($0.dropLast("=change-me".count)) }
            let plain = recipe.env.filter { !$0.hasSuffix("=change-me") }
            entries.append(LibraryEntry(
                id: recipe.id, title: recipe.title,
                summary: "\(recipe.title) on its own, as Flotilla has tested it.",
                categories: containerCategories[recipe.id] ?? ["Software Development"], kind: .container,
                tested: .init(date: "2026-10-12", macs: 1),
                container: LibraryContainer(
                    image: recipe.image, name: recipe.name, ports: recipe.ports, env: plain, secretEnv: secrets,
                    volumes: recipe.volumes.compactMap { mount in
                        let parts = mount.split(separator: ":", maxSplits: 1)
                        guard parts.count == 2 else { return nil }
                        let suffix = parts[0].hasPrefix("\(recipe.name)-") ? String(parts[0].dropFirst(recipe.name.count + 1)) : "data"
                        return LibraryVolume(suffix: suffix, path: String(parts[1]))
                    },
                    note: recipe.note)))
        }
        return SuggestionLibrary(version: "2026.10.12.0", entries: entries)
    }()
}
