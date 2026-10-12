import Foundation

// How Greta decides what a message wants (the owner, 12 October: one box, and she decides). The
// on-device model was asked first and got it wrong too often to keep — "What can Flotilla do?" went
// to "ask what to run", "Draft Postgres 17" went to "explain" — so the decision is made here, in
// plain rules with tests, and the model writes the answer once it is made.
//
// Drafts start from Flotilla's own Suggestions catalogue, whose images and paths were run before
// they shipped ("offer what you have actually run"), rather than from what a small model recalls.

/// One container Greta can draft without guessing: taken from a tested stack service.
public struct GretaRecipe: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Lowercase words or phrases that name it.
    public let words: [String]
    public let image: String
    public let name: String
    public let ports: [String]
    public let env: [String]
    public let volumes: [String]
    /// Said with the draft: something to know before running it.
    public let note: String?
    /// Versions before `before` keep their data at `path` (PostgreSQL moved it in 18).
    public var olderData: (before: Int, path: String)? = nil

    public static func == (a: GretaRecipe, b: GretaRecipe) -> Bool { a.id == b.id }
}

/// A container draft for the Run form, and what was changed from its recipe to make it.
public struct GretaDraft: Sendable, Equatable {
    public var image: String
    public var name: String
    public var ports: [String]
    public var env: [String]
    public var volumes: [String]
    /// What the message changed, in words: "version 17", "port 9000 on this Mac".
    public var changes: [String] = []
    /// They mentioned a password: it stays change-me here, to be typed into the Run form.
    public var passwordLeftForTheForm = false
    /// The message had characters outside ASCII, so no change was read from it.
    public var changesNotRead = false
}

public enum GretaRoute: Equatable, Sendable {
    /// A question: the model answers it, with the guide and the fleet to hand.
    case answer
    /// Something Flotilla has a tested recipe for.
    case draft(GretaRecipe)
    /// Something to run that Flotilla has no recipe for: she says so rather than guess, because
    /// the on-device model invents images and settings (measured 12 October: "gitea" became
    /// `docker.io/library/gitea:1.0`, "uptime kuma" became nginx).
    case noRecipe
    /// They want to run something but haven't said what.
    case askWhich
    /// Something that needs other containers beside it: Suggestions builds it as a stack.
    case stack(String)
}

public enum GretaRouter {
    public static func route(_ message: String, lastReply: String?) -> GretaRoute {
        let text = normalised(message)
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .answer }

        // "yes" on its own agrees to whatever her last message offered — if it offered one thing.
        if GretaText.isBareAgreement(message) {
            let said = normalised(lastReply ?? "")
            let recipes = mentioned(in: said)
            if recipes.count == 1 { return .draft(recipes[0]) }
            let stacks = stacksMentioned(in: said)
            if recipes.isEmpty, stacks.count == 1 { return .stack(stacks[0]) }
            return .askWhich
        }

        // A message that opens by asking to run something is a request, whatever follows ("draft
        // postgres, don't use a volume"); unless it asks for something to learn from. Otherwise a
        // negation, a change to something that exists, a question about state or asking to learn
        // means it isn't (Kyle's examples, 12 October, both rounds).
        if opensWithRun(text) {
            if asksToMakeSomethingToRead(text) || text.hasPrefix("run down") { return .answer }
        } else if notARequest.contains(where: { contains(text, $0) }) {
            return .answer
        }

        let asksYou = ["can", "could", "would", "will"].contains(words[0]) && words.dropFirst().first == "you"
        let wantsToRun = runPhrases.contains { contains(text, $0) }
        if questionWords.contains(words[0]), !(asksYou && wantsToRun) { return .answer }

        let recipes = mentioned(in: text)
        let stacks = stacksMentioned(in: text)
        let short = words.count <= 4
        guard wantsToRun || ((!recipes.isEmpty || !stacks.isEmpty) && short) else { return .answer }

        if let stack = stacks.first { return .stack(stack) }
        if recipes.count > 1 { return .stack("") }
        if let recipe = recipes.first { return .draft(recipe) }
        // Run what? Everything left once the asking is taken out.
        let left = words.filter { !filler.contains($0) && !runPhrases.contains($0) }
        return left.isEmpty ? .askWhich : .noRecipe
    }

    /// The recipe, with what the message asks for applied: a version, a port on this Mac, a name,
    /// a user or database name, or no volume. Anything else stays as the recipe has it, for the
    /// Run form.
    public static func draft(_ recipe: GretaRecipe, for message: String) -> GretaDraft {
        var draft = GretaDraft(image: recipe.image, name: recipe.name, ports: recipe.ports,
                               env: recipe.env, volumes: recipe.volumes)
        // A message that mentions a password changes nothing: the recipe stands, and the password
        // and any other change are typed in the Run form.
        if GretaText.mentionsSecret(message) {
            draft.passwordLeftForTheForm = true
            return draft
        }
        // Changes are read only from plain ASCII, which is all a name, user, database, port or
        // version can be: text in other scripts can't smuggle anything past the checks above.
        guard message.unicodeScalars.allSatisfy(\.isASCII) else {
            draft.changesNotRead = true
            return draft
        }
        let tokens = message.lowercased()
            .split { $0.isWhitespace || ",;:!?()\"'".contains($0) }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        let singleWords = Set(recipe.words.filter { !$0.contains(" ") })
        func next(_ i: Int) -> String? { i + 1 < tokens.count ? tokens[i + 1] : nil }
        func identifier(_ value: String?) -> String? {
            guard let value, !filler.contains(value), !connectives.contains(value), value.count <= 40,
                  value.first.map({ $0.isLetter || $0.isNumber }) == true,
                  value.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.".contains($0) })
            else { return nil }
            return value
        }

        for (i, token) in tokens.enumerated() {
            switch token {
            case _ where (singleWords.contains(token) || token == "version"):
                guard let version = next(i), version.first?.isNumber == true,
                      version.allSatisfy({ $0.isNumber || $0 == "." }) else { continue }
                let repository = draft.image.split(separator: ":").first.map(String.init) ?? draft.image
                let tag = recipe.image.split(separator: ":").last?.hasPrefix("v") == true ? "v\(version)" : version
                draft.image = "\(repository):\(tag)"
                draft.changes.append("version \(version)")
                if let older = recipe.olderData, let major = Int(version.split(separator: ".")[0]), major < older.before {
                    draft.volumes = draft.volumes.map { "\($0.split(separator: ":")[0]):\(older.path)" }
                }
            case "port", "on":
                guard let value = next(i), let port = Int(value), (1...65535).contains(port),
                      let first = draft.ports.first, let inside = first.split(separator: ":").last else { continue }
                draft.ports[0] = "\(port):\(inside)"
                draft.changes.append("port \(port) on this Mac")
            case "called", "named", "name":
                guard let name = identifier(next(i) == "it" ? (i + 2 < tokens.count ? tokens[i + 2] : nil) : next(i)) else { continue }
                draft.name = name
                draft.volumes = draft.volumes.map { volume in
                    let parts = volume.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].hasPrefix(recipe.name) ? "\(name)-data:\(parts[1])" : volume
                }
                draft.changes.append("named \(name)")
            case "user", "username":
                guard let user = identifier(next(i)) else { continue }
                if replaceEnv(&draft, endingIn: ["_USER"], with: user) { draft.changes.append("user \(user)") }
            case "database", "db":
                guard let database = identifier(next(i)) else { continue }
                if replaceEnv(&draft, endingIn: ["_DB", "_DATABASE"], with: database) { draft.changes.append("database \(database)") }
            default:
                continue
            }
        }
        let text = normalised(message)
        if ["no volume", "no volumes", "without a volume", "without volume", "without its data", "no data",
            "don t use a volume", "dont use a volume", "do not use a volume"].contains(where: { contains(text, $0) }),
           !draft.volumes.isEmpty {
            draft.volumes = []
            draft.changes.append("no volume")
        }
        return draft
    }

    private static func replaceEnv(_ draft: inout GretaDraft, endingIn suffixes: [String], with value: String) -> Bool {
        guard let index = draft.env.firstIndex(where: { entry in
            let name = entry.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return suffixes.contains { name.hasSuffix($0) } && !name.contains("PASSWORD")
        }) else { return false }
        let name = draft.env[index].split(separator: "=", maxSplits: 1)[0]
        draft.env[index] = "\(name)=\(value)"
        return true
    }

    /// The reply when they want to run something and haven't said what.
    public static let whichToRun = """
        What would you like to run? Name it and I'll draft it for the Run form — for example \
        "Postgres with its data kept", "Redis", "nginx on port 8080" or "Grafana". For a database \
        with a page to manage it, or WordPress, Suggestions builds the whole stack in one click.
        """

    /// For something with no recipe.
    public static var noRecipeReply: String {
        "I only draft containers Flotilla has tested, so I don't guess at images or settings: "
            + recipes.map(\.title).joined(separator: ", ")
            + ". For anything else, open Run in Containers and enter the image the project publishes; "
            + "its documentation lists the ports, settings and where it keeps data."
    }

    /// The same question asked again, shorter.
    public static let whichToRunAgain = """
        Just name it — "redis", "postgres", "nginx on port 8080" — and I'll draft it. Or ask me \
        how something in Flotilla works.
        """

    public static let recipes: [GretaRecipe] = {
        var list: [GretaRecipe] = [
            recipe("postgres", "PostgreSQL", ["postgres", "postgresql", "psql", "pg"],
                   olderData: (18, "/var/lib/postgresql/data")),
            // On its own, not WordPress's: the stack's "wordpress" defaults would mislead.
            recipe("mariadb", "MariaDB", ["mariadb", "maria db"], options: ["database": "app", "user": "app"]),
            recipe("mysql", "MySQL", ["mysql", "my sql"]),
            recipe("redis", "Redis", ["redis"],
                   note: "Redis keeps its data inside its container: it survives Stop and Start, not Delete."),
            recipe("prometheus", "Prometheus", ["prometheus"]),
            recipe("grafana", "Grafana", ["grafana"]),
            recipe("pgadmin", "pgAdmin", ["pgadmin", "pg admin"], hostPort: 8080),
        ].compactMap { $0 }
        // Not in a stack, and run here more than anything else.
        list.append(GretaRecipe(id: "nginx", title: "nginx", words: ["nginx", "web server", "webserver", "static site"],
                                image: "docker.io/library/nginx:1.27", name: "web", ports: ["8080:80"],
                                env: [], volumes: [],
                                note: "It serves nginx's welcome page until you give it your own files."))
        return list
    }()

    // MARK: Matching

    /// Services that only make sense beside another, by the stack that has them.
    static let stackWords: [(words: [String], stack: String)] = [
        (["wordpress", "word press"], "WordPress + MariaDB"),
        (["phpmyadmin", "php my admin"], "MySQL + phpMyAdmin"),
        (["redisinsight", "redis insight"], "Redis + RedisInsight"),
    ]

    static let notARequest = [
        // negation
        "don t", "dont", "do not", "never", "not", "no need", "without running",
        // something that exists
        "delete", "remove", "stop", "kill", "restart", "uninstall", "upgrade", "update", "rename",
        "already", "is running", "isn t running", "isnt running", "crashed", "crashing", "crash",
        "broken", "error", "failed", "failing", "logs", "status",
        // learning
        "help", "tutorial", "learn", "know", "explain", "understand", "teach", "docs",
        "documentation", "run down", "what", "how", "why", "difference",
    ]

    /// Asking for something to read, not something to run.
    static let learning = ["tutorial", "docs", "documentation", "guide", "explanation", "course", "lesson"]

    /// "Create a Redis tutorial" asks for something to read; "run Postgres from the docs" doesn't.
    /// Only a verb that makes something can make a tutorial, and "from the docs" names a source.
    static func asksToMakeSomethingToRead(_ text: String) -> Bool {
        let makes = ["create", "make", "write", "draft", "give me", "prepare"].contains { text.hasPrefix($0 + " ") }
        let source = ["from the", "in the", "per the", "using the", "following the", "like the", "as in the"]
        return makes && learning.contains { word in
            contains(text, word) && !source.contains { contains(text, "\($0) \(word)") }
        }
    }

    /// Opens with a verb that asks for a container, after any "please" or "can you".
    static func opensWithRun(_ text: String) -> Bool {
        var rest = text
        for opener in ["please ", "can you ", "could you ", "would you ", "will you ", "can u ", "pls "] where rest.hasPrefix(opener) {
            rest = String(rest.dropFirst(opener.count))
        }
        if rest.hasPrefix("please ") { rest = String(rest.dropFirst(7)) }
        return ["run", "draft", "set up", "setup", "create", "spin up", "launch", "deploy", "install",
                "start a", "start an", "start up", "make me", "make a", "give me", "host a", "host my"]
            .contains { rest == $0 || rest.hasPrefix($0 + " ") }
    }

    static let questionWords: Set<String> = [
        "how", "what", "whats", "why", "where", "when", "which", "who", "does", "do", "is", "are",
        "should", "can", "could", "would", "will", "did", "explain", "tell", "whats",
    ]

    static let runPhrases = [
        "run", "draft", "set up", "setup", "create", "spin up", "launch", "deploy", "install",
        "start a", "start an", "start up", "give me", "i want", "i need", "i d like", "id like",
        "make me", "make a", "new container", "host a", "host my",
    ]

    /// Words that ask without naming anything to run.
    static let filler: Set<String> = [
        "a", "an", "the", "me", "for", "please", "some", "something", "thing", "one", "container",
        "containers", "can", "could", "would", "will", "you", "i", "id", "d", "want", "need", "like",
        "to", "up", "set", "setup", "run", "draft", "create", "make", "give", "new", "start", "launch",
        "deploy", "install", "spin", "on", "my", "mac", "this", "it", "that", "service", "app", "with",
        "database", "db", "server", "host", "now", "just", "quick", "quickly", "simple", "test",
    ]

    /// Never a value: "a database called shop" names the database shop, not "called".
    static let connectives: Set<String> = [
        "called", "named", "name", "port", "on", "user", "username", "database", "db", "version",
        "with", "and", "for", "in", "at", "as", "it", "its", "of", "using", "kept",
    ]

    static func mentioned(in text: String) -> [GretaRecipe] {
        recipes
            .compactMap { recipe -> (GretaRecipe, String.Index)? in
                let hits = recipe.words.compactMap { firstMatch(of: $0, in: text) }
                return hits.min().map { (recipe, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            // "pgadmin" isn't also a mention of "pg".
            .filter { recipe in !(recipe.id == "postgres" && contains(text, "pgadmin") && !contains(text, "postgres")) }
    }

    static func stacksMentioned(in text: String) -> [String] {
        stackWords.filter { $0.words.contains { contains(text, $0) } }.map(\.stack)
    }

    /// Lowercase letters and digits, one space between words.
    static func normalised(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// `phrase` as whole words in `text`.
    static func contains(_ text: String, _ phrase: String) -> Bool { firstMatch(of: phrase, in: text) != nil }

    static func firstMatch(of phrase: String, in text: String) -> String.Index? {
        let padded = " \(text) "
        guard let range = padded.range(of: " \(phrase) ") else { return nil }
        return range.lowerBound
    }

    // MARK: From the catalogue

    private static func recipe(_ id: String, _ title: String, _ words: [String], hostPort: Int? = nil,
                               note: String? = nil, olderData: (Int, String)? = nil,
                               options overrides: [String: String] = [:]) -> GretaRecipe? {
        for stack in StackSuggestion.catalogue {
            guard let service = stack.services.first(where: { $0.title == title }) else { continue }
            let options = Dictionary(stack.options.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
                .merging(overrides) { _, override in override }
            var env = service.env.map { value in
                options.reduce(value) { $0.replacingOccurrences(of: "{{option:\($1.key)}}", with: $1.value) }
            }
            // Wiring to another member of the stack has nothing to point at on its own.
            env.removeAll { $0.contains("{{") }
            env += service.secretEnv.map { "\($0.name)=change-me" }
            var ports: [String] = []
            if let web = service.webPort { ports.append("\(hostPort ?? web):\(web)") }
            if let wired = service.wiredPort, wired != service.webPort { ports.append("\(wired):\(wired)") }
            return GretaRecipe(id: id, title: title, words: words, image: service.image, name: id,
                               ports: ports, env: env,
                               volumes: service.volumes.map { "\(id)-\($0.suffix):\($0.path)" }, note: note,
                               olderData: olderData.map { (before: $0.0, path: $0.1) })
        }
        return nil
    }
}
