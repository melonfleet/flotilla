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
    /// 2 added `volumeOwner` (18 October): builds that read only 1 would ignore it and install
    /// recipes that can't write their volumes, so a library using it says 2.
    public static let currentSchema = 2
    /// Every format this build reads. The built-in copy and caches from before 2 are still 1.
    public static let readableSchemas = 1...currentSchema
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

    /// Only the entries that pass every check, with reasons for dropped entries or icons. A library whose
    /// version isn't valid is refused whole: it comes back empty, with `"library"` in `dropped`.
    public func checked() -> (library: SuggestionLibrary, dropped: [(id: String, problem: String)]) {
        guard Self.isValidVersion(version) else {
            return (SuggestionLibrary(schema: schema, version: version, entries: []),
                    [("library", "Its version isn't four numbers from 0 to 9999, such as 2026.10.12.0.")])
        }
        var kept: [LibraryEntry] = []
        var dropped: [(String, String)] = []
        var seen = Set<String>()
        for var entry in entries.prefix(Self.maxEntries) {
            if let problem = entry.problem() { dropped.append((entry.id, problem)); continue }
            guard seen.insert(entry.id).inserted else { dropped.append((entry.id, "Its id is used twice.")); continue }
            if let problem = entry.icon?.problem() {
                dropped.append((entry.id, "Icon ignored: " + problem))
                entry.icon = nil
            }
            kept.append(entry)
        }
        if entries.count > Self.maxEntries { dropped.append(("…", "More than \(Self.maxEntries) entries; the rest were ignored.")) }
        return (SuggestionLibrary(schema: schema, version: version, entries: kept), dropped)
    }

    /// Exactly four unsigned decimal numbers, each 0 to 9999 with no leading zero: `2026.10.12.0`.
    /// Anything else is refused rather than read as zeros — a malformed version must not count as
    /// newer, and an enormous one must not freeze every later update.
    public static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            (1...4).contains(part.utf8.count) && part.utf8.allSatisfy { (0x30...0x39).contains($0) }
                && (part == "0" || part.first != "0")
        }
    }

    /// Whether `other` is a newer version than this one. `false` unless both versions are valid.
    public func isOlder(than other: SuggestionLibrary) -> Bool {
        guard Self.isValidVersion(version), Self.isValidVersion(other.version) else { return false }
        let mine = version.split(separator: ".").compactMap { Int($0) }
        let theirs = other.version.split(separator: ".").compactMap { Int($0) }
        for (a, b) in zip(mine, theirs) where a != b { return a < b }
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
    /// When and on how many Macs it was last run and passed. Required: an entry nobody has run is
    /// dropped (Q54, "tested entries only"); optional in the type only so the reason can be named.
    public var tested: Tested?
    public var container: LibraryContainer?
    public var stack: LibraryStack?
    public var icon: LibraryIcon?

    public struct Tested: Sendable, Codable, Equatable {
        public var date: String
        public var macs: Int
        public init(date: String, macs: Int) { self.date = date; self.macs = macs }

        /// A real calendar date written `YYYY-MM-DD`, on one to twenty Macs.
        func problem() -> String? {
            guard (1...20).contains(macs) else { return "It says it was tested on \(macs) Macs." }
            let bytes = Array(date.utf8)
            let digits = [0, 1, 2, 3, 5, 6, 8, 9]
            guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D,
                  digits.allSatisfy({ (0x30...0x39).contains(bytes[$0]) }),
                  let year = Int(date.prefix(4)), let month = Int(date.dropFirst(5).prefix(2)),
                  let day = Int(date.suffix(2)), (1...12).contains(month) else {
                return "Its test date isn't a date written YYYY-MM-DD."
            }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard (1...days).contains(day) else { return "Its test date isn't a date written YYYY-MM-DD." }
            return nil
        }
    }

    public init(id: String, title: String, summary: String, categories: [String], kind: Kind,
                licenceNote: String? = nil, tested: Tested? = nil,
                container: LibraryContainer? = nil, stack: LibraryStack? = nil, icon: LibraryIcon? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.categories = categories
        self.kind = kind; self.licenceNote = licenceNote; self.tested = tested
        self.container = container; self.stack = stack; self.icon = icon
    }

    /// The images it pulls.
    /// Everything a search looks through (Kamal, 18 October: typing "database" must find the
    /// Databases category, and the licence must be searchable too). Plain words for the licence
    /// side, in both spellings, so "licence", "license", "open source" and "copyleft" all work.
    public var searchText: [String] {
        var words = [title, summary, kind.rawValue] + categories + images
        if let note = licenceNote {
            words += [note, "licence", "license"]
        } else {
            words += ["open source", "permissive"]
        }
        return words
    }

    /// True when every word of `query` appears somewhere in `searchText`, ignoring case and accents.
    public func matches(_ query: String) -> Bool {
        let haystack = searchText
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public var images: [String] {
        switch kind {
        case .container: container.map { [$0.image] } ?? []
        case .stack: stack?.services.map(\.image) ?? []
        }
    }

    /// Why it can't be offered, or `nil`.
    public func problem() -> String? {
        guard id.utf8.count <= 64, Allowlist.accepts(id, as: .identifier) else { return "Its id isn't a plain name." }
        guard Library.isPlainText(title, upTo: 80, required: true), Library.isPlainText(summary, upTo: 240) else {
            return "Its title or summary is too long, or has characters that aren't plain text."
        }
        guard (1...3).contains(categories.count),
              categories.allSatisfy(SuggestionLibrary.categories.contains) else {
            return "Its categories aren't from the library's list."
        }
        if let note = licenceNote, !Library.isPlainText(note, upTo: 400) {
            return "Its licence note is too long, or has characters that aren't plain text."
        }
        guard let tested else { return "It hasn't been tested." }
        if let problem = tested.problem() { return problem }
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
                             volumes: service.volumes.map { StackVolume(suffix: $0.suffix, path: $0.path, volumeOwner: $0.volumeOwner) },
                             webPort: service.webPort, wiredPort: service.wiredPort,
                             readyPort: service.readyPort, command: service.command)
            },
            notes: stack.notes, opens: stack.opens)
    }
}

/// A PNG shipped beside the signed library. Invalid metadata removes only this decoration.
public struct LibraryIcon: Sendable, Codable, Equatable {
    public static let maxBytes = 64 * 1024
    public var file: String
    public var sha256: String
    public var bytes: Int

    public init(file: String, sha256: String, bytes: Int) {
        self.file = file; self.sha256 = sha256; self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey { case file, sha256, bytes }

    // Malformed icon fields must not stop the surrounding entry (or library) decoding.
    public init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        file = (try? values?.decode(String.self, forKey: .file)) ?? ""
        sha256 = (try? values?.decode(String.self, forKey: .sha256)) ?? ""
        bytes = (try? values?.decode(Int.self, forKey: .bytes)) ?? 0
    }

    public func problem() -> String? {
        guard file.utf8.count <= 74, !file.contains(".."),
              file.range(of: #"\Aicons/[a-z0-9][a-z0-9.-]{0,63}\.png\z"#, options: .regularExpression) != nil else {
            return "Its file isn't a PNG name inside icons/."
        }
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return "Its SHA-256 isn't 64 lowercase hexadecimal digits."
        }
        guard (1...Self.maxBytes).contains(bytes) else { return "Its size isn't between 1 and 65536 bytes." }
        return nil
    }
}

/// A named volume a library entry mounts. Never a folder on the Mac.
public struct LibraryVolume: Sendable, Codable, Equatable {
    public var suffix: String
    public var path: String
    /// Root-directory ownership setup, only for a volume created by this Suggestions run.
    public var volumeOwner: VolumeOwner?
    public init(suffix: String = "data", path: String, volumeOwner: VolumeOwner? = nil) {
        self.suffix = suffix; self.path = path; self.volumeOwner = volumeOwner
    }

    func problem() -> String? {
        if let volumeOwner, !volumeOwner.isValid { return "A volume owner must use UID and GID from 0 to 2147483647." }
        guard suffix.utf8.count <= 32, Allowlist.accepts(suffix, as: .identifier) else {
            return "A volume's name isn't a plain name."
        }
        guard path.hasPrefix("/"), path.utf8.count <= 200, !path.split(separator: "/").contains(".."),
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
        guard name.utf8.count <= 64, Allowlist.accepts(name, as: .identifier) else {
            return "Its container name isn't a plain name."
        }
        guard ports.count <= Library.maxItems, env.count <= Library.maxItems,
              secretEnv.count <= Library.maxItems, volumes.count <= Library.maxItems else {
            return "It has more than \(Library.maxItems) ports, variables, passwords or volumes."
        }
        for port in ports where Library.portProblem(port) != nil { return Library.portProblem(port) }
        for value in env where Library.envProblem(value, templates: false) != nil {
            return Library.envProblem(value, templates: false)
        }
        if let problem = Library.secretProblem(secretEnv, env: env) { return problem }
        if let problem = Library.volumesProblem(volumes) { return problem }
        if let problem = Library.commandProblem(command) { return problem }
        if let note {
            // Not templated: nothing would fill a placeholder, so braces are refused outright.
            guard Library.isPlainText(note, upTo: 400), !note.contains("{{"), !note.contains("}}") else {
                return "Its note is too long, or has characters that aren't plain text."
            }
        }
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

    /// Everything `GroupBook` and the planner would refuse later is refused here, because by then
    /// the network, the volumes and the Keychain entries already exist.
    func problem() -> String? {
        guard (1...6).contains(services.count) else { return "A stack has one to six services." }
        let roles = services.map(\.role)
        // Case-insensitively, as container names are: `db` and `DB` would be the same member.
        guard Set(roles.map { $0.lowercased() }).count == roles.count,
              roles.allSatisfy({ $0.utf8.count <= 24 && Allowlist.accepts($0, as: .identifier) })
        else { return "Its service roles aren't distinct plain names." }
        guard options.count <= Library.maxOptions else { return "It has more than \(Library.maxOptions) settings." }
        guard Set(options.map(\.id)).count == options.count else { return "Two of its settings share an id." }
        for option in options {
            guard option.id.utf8.count <= 32, Allowlist.accepts(option.id, as: .identifier),
                  Library.isPlainText(option.label, upTo: 60, required: true),
                  Library.isPlainText(option.help, upTo: 240),
                  option.defaultValue.utf8.count <= 254 else { return "One of its settings is malformed." }
            let probe = StackOption(id: option.id, label: option.label, defaultValue: option.defaultValue,
                                    help: option.help, kind: option.email ? .email : .identifier)
            if let problem = probe.problem(with: option.defaultValue) { return "\(option.label): \(problem)" }
        }
        let optionIDs = Set(options.map(\.id))
        let reachable = Set(services.filter { $0.wiredPort != nil }.map(\.role))
        for service in services {
            if let problem = Library.imageProblem(service.image) { return problem }
            guard Library.isPlainText(service.title, upTo: 60, required: true) else {
                return "A service's title is missing, too long, or has characters that aren't plain text."
            }
            for port in [service.webPort, service.wiredPort, service.readyPort].compactMap({ $0 })
            where !(1...65535).contains(port) { return "\(port) isn't a port." }
            // Without a domain the planner publishes a wired port at 30000 above itself on the gateway.
            if let wired = service.wiredPort, wired + Library.gatewayOffset > 65535 {
                return "\(wired) is too high to be reached through the gateway."
            }
            guard service.env.count <= Library.maxItems, service.secretEnv.count <= Library.maxItems,
                  service.volumes.count <= Library.maxItems else {
                return "A service has more than \(Library.maxItems) variables, passwords or volumes."
            }
            for value in service.env {
                if let problem = Library.envProblem(value, templates: true) { return problem }
                if let problem = Library.templateProblem(value, options: optionIDs, reachable: reachable) { return problem }
            }
            guard service.secretEnv.allSatisfy({ $0.secret.utf8.count <= 64 && Allowlist.accepts($0.secret, as: .identifier) })
            else { return "A password variable is malformed." }
            if let problem = Library.secretProblem(service.secretEnv.map(\.name), env: service.env) { return problem }
            if let problem = Library.volumesProblem(service.volumes) { return problem }
            if let problem = Library.commandProblem(service.command) { return problem }
        }
        if let opens {
            guard let target = services.first(where: { $0.role == opens }) else { return "It opens a service it doesn't have." }
            guard target.webPort != nil else { return "It opens a service that has no web page." }
        }
        guard notes.count <= 8, notes.allSatisfy({ Library.isPlainText($0, upTo: 400, required: true) }) else {
            return "Its notes are too many, too long, or have characters that aren't plain text."
        }
        for note in notes {
            if let problem = Library.templateProblem(note, options: optionIDs, reachable: reachable) { return problem }
        }
        return nil
    }
}

/// The rules shared by containers and stacks.
enum Library {
    /// Ports, variables, passwords and volumes, each; a command's arguments.
    static let maxItems = 16
    static let maxOptions = 8
    /// How far above its own port the planner publishes a wired service on the gateway.
    static let gatewayOffset = 30000

    static func imageProblem(_ image: String) -> String? {
        guard image.utf8.count <= 255, Allowlist.accepts(image, as: .imageReference) else {
            return "“\(image.prefix(80))” isn't an image reference."
        }
        guard let tag = image.split(separator: "/").last?.split(separator: ":").dropFirst().first, !tag.isEmpty,
              tag != "latest" else { return "“\(image)” isn't pinned to a version." }
        return nil
    }

    /// `HOST:CONTAINER`, the host side 1024 or above.
    static func portProblem(_ spec: String) -> String? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard spec.utf8.count <= 11, parts.count == 2, let host = Int(parts[0]), let inside = Int(parts[1]),
              (1024...65535).contains(host), (1...65535).contains(inside) else {
            return "“\(spec.prefix(40))” isn't a port pair with a port from 1024 on this Mac."
        }
        return nil
    }

    /// A name that reads as a password, key or token. Such a variable is only ever a generated
    /// `secretEnv` — never a value in the file, and never a placeholder an option fills, because an
    /// option's default is a value in the file too (Kyle: `hunter2` through `{{option:pw}}`).
    static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["PASS", "PWD", "SECRET", "TOKEN", "KEY", "CREDENTIAL"].contains(where: upper.contains)
    }

    static func envProblem(_ value: String, templates: Bool) -> String? {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isEnvironmentName(String(parts[0])) else { return "“\(value.prefix(40))” isn't NAME=value." }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
        else { return "A variable's value is too long or has control characters." }
        if !templates, value.contains("{{") || value.contains("}}") { return "A container entry can't use placeholders." }
        if looksSecret(String(parts[0])) {
            return "\(parts[0]) looks like a password: it must be generated, not written in the library."
        }
        return nil
    }

    /// Generated variables: real names, each once, and none also given a plain value — the rule
    /// `GroupSecrets.problem(with:)` applies when the group is saved.
    static func secretProblem(_ names: [String], env: [String]) -> String? {
        guard names.allSatisfy({ isEnvironmentName($0) && Allowlist.accepts($0 + "=x", as: .envAssignment) }) else {
            return "A password variable's name isn't a variable name."
        }
        guard Set(names).count == names.count else { return "A password variable is named twice." }
        let plain = Set(env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        if let both = names.first(where: plain.contains) {
            return "\(both) is both a password and a plain variable."
        }
        return nil
    }

    /// Each volume valid, and no two with the same name, which would mount one volume twice.
    static func volumesProblem(_ volumes: [LibraryVolume]) -> String? {
        if let problem = volumes.lazy.compactMap({ $0.problem() }).first { return problem }
        guard Set(volumes.map { $0.suffix.lowercased() }).count == volumes.count else {
            return "Two of its volumes have the same name."
        }
        return nil
    }

    static func commandProblem(_ command: [String]) -> String? {
        guard command.count <= maxItems,
              command.allSatisfy({ $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: {
                  [.control, .format].contains($0.properties.generalCategory) }) }) else {
            return "Its command is too long."
        }
        guard !command.contains(where: { $0.contains("$(") || $0.contains("${") || $0.contains("`") }) else {
            return "Its command expects a shell, and none runs it."
        }
        return nil
    }

    static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)),
              name.utf8.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    /// Text shown as part of the app: a title, summary, label, help or note. NFC, on one line,
    /// at most `limit` characters and four bytes a character, with no control, format (bidi,
    /// zero-width), private-use, unassigned or surrogate scalars — so a title can't hide text or
    /// reorder itself to read as something else.
    static func isPlainText(_ text: String, upTo limit: Int, required: Bool = false) -> Bool {
        // By scalar: `==` on `String` is canonical equivalence, so `"Cafe\u{301}" == "Café"` and an
        // NFC check written with it can never fail.
        guard !required || !text.isEmpty, text.count <= limit, text.utf8.count <= limit * 4,
              text.unicodeScalars.elementsEqual(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        else { return false }
        return !text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator: true
            default: false
            }
        }
    }

    /// Why a templated string is refused, or `nil`. Every `{{` and `}}` must belong to one of the
    /// placeholders the planner fills, naming something that exists; a stray one is refused rather
    /// than left in the text.
    static func templateProblem(_ text: String, options: Set<String>, reachable: Set<String>) -> String? {
        guard let tokens = placeholders(in: text) else { return "“\(text.prefix(40))” has a stray {{ or }}." }
        for token in tokens {
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return "“{{\(token.prefix(40))}}” isn't a placeholder Flotilla fills." }
            switch parts[0] {
            case "option" where options.contains(parts[1]): continue
            case "host", "port":
                guard reachable.contains(parts[1]) else {
                    return "“{{\(token.prefix(40))}}” names a service other services can't reach."
                }
            default: return "“{{\(token.prefix(40))}}” isn't a placeholder Flotilla fills."
            }
        }
        return nil
    }

    /// The inside of every `{{…}}`, or `nil` if any `{{` or `}}` isn't part of one. The inside may
    /// hold no brace at all, so `{{{x}}}` is malformed rather than read generously.
    static func placeholders(in value: String) -> [String]? {
        var found: [String] = []
        var rest = Substring(value)
        while let open = rest.range(of: "{{") {
            guard !rest[..<open.lowerBound].contains("}}"),
                  let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else { return nil }
            let inside = rest[open.upperBound..<close.lowerBound]
            guard !inside.contains("{"), !inside.contains("}") else { return nil }
            found.append(String(inside))
            rest = rest[close.upperBound...]
        }
        return rest.contains("}}") ? nil : found
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
                              volumes: service.volumes.map { .init(suffix: $0.suffix, path: $0.path, volumeOwner: $0.volumeOwner) },
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
                    volumes: StackSuggestion.catalogue.flatMap(\.services).first(where: { $0.image == recipe.image })?
                        .volumes.map { LibraryVolume(suffix: $0.suffix, path: $0.path, volumeOwner: $0.volumeOwner) }
                        ?? recipe.volumes.compactMap { mount in
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
