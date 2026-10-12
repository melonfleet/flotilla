import Foundation

// Greta's knowledge of Flotilla (DECISIONS Q52): short, factual sections she is handed a few at a
// time, so what she says about the app comes from here and not from the model's memory. The
// on-device model holds about 4,000 tokens on macOS 26, so a section is a paragraph, and a search
// returns the best two or three within a budget.
//
// Written from the app as built (beta 4 and after); keep it true when behaviour changes.

/// One topic Greta can cite.
public struct GretaSection: Sendable, Equatable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let text: String
}

public enum GretaGuide {
    public static let sections: [GretaSection] = [
        .init(id: "run", title: "Running a container",
              keywords: ["run", "container", "start", "new", "create", "image", "name"],
              text: "Containers ▸ + ▸ Run Container… opens the Run form: an image reference (for example docker.io/library/postgres:17), an optional name, ports, environment variables, volumes, a command, and CPU and memory limits. Run on chooses This Mac or a paired host. The command preview shows exactly what will run, checked by Flotilla's allowlist. Each container is its own small Linux VM, so it starts in a second or two."),
        .init(id: "ports", title: "Publishing ports",
              keywords: ["port", "publish", "expose", "8080", "web", "browser", "address", "reach"],
              text: "A port is written host:container, for example 8080:80, meaning port 8080 on the Mac reaches port 80 in the container. A host port already in use makes the container fail to start, so pick a free one. Containers on different Macs reach each other through published ports only."),
        .init(id: "volumes", title: "Volumes and folders",
              keywords: ["volume", "data", "persist", "storage", "mount", "folder", "keep"],
              text: "A named volume keeps data when a container is deleted: write it as name:/path/in/container, for example pgdata:/var/lib/postgresql/data. Volumes are listed under Volumes and belong to one Mac. On This Mac a folder can also be mounted. A host never mounts folders from the admin, and a shared .flotilla file may only use named volumes."),
        .init(id: "env", title: "Environment variables",
              keywords: ["environment", "env", "variable", "password", "setting", "config"],
              text: "Environment variables are written NAME=value, one per row. Databases usually need one to start, for example POSTGRES_PASSWORD for Postgres or MYSQL_ROOT_PASSWORD for MySQL. Flotilla never stores credentials of its own."),
        .init(id: "images", title: "Images and registries",
              keywords: ["image", "pull", "registry", "docker hub", "tag", "build", "dockerfile"],
              text: "Images ▸ Pull fetches an image, to This Mac or several Macs at once. Browse Docker Hub searches Docker Hub. Registries lists where you are signed in; signing in uses container's own login, and Flotilla keeps no password. Images can also be built from a Dockerfile, tagged, deleted, and sent from This Mac to hosts."),
        .init(id: "machines", title: "Machines",
              keywords: ["machine", "vm", "virtual", "linux", "shell", "home"],
              text: "A machine is a Linux VM you keep and log into, like a small server, listed under Machines. New Machine sets its image, CPUs, memory and whether your home folder is mounted (read-only by default). Machines and containers are siblings: a container doesn't run inside a machine. Machines are This Mac only."),
        .init(id: "networks", title: "Networks and DNS",
              keywords: ["network", "dns", "name", "domain", "resolve", "subnet"],
              text: "Networks lists container networks; containers on the same network reach each other. DNS gives containers names under a local domain, and with the Flotilla Helper on, names across Macs resolve too. Changing DNS needs the Flotilla Helper, approved once in Login Items."),
        .init(id: "restart", title: "Restart policies",
              keywords: ["restart", "crash", "stops", "keep running", "always", "policy", "recover"],
              text: "A container's page ▸ Restart and health, or the Run form, sets a policy: Never, or If it stops unexpectedly. Flotilla then restarts it after 0, 10, 30, 60, 120 and 300 seconds, and gives up after five restarts in ten minutes. A stop made in Flotilla is respected. container doesn't report exit codes, so a stop typed in Terminal looks like a crash and is restarted too. The Mac that runs the container runs its policy."),
        .init(id: "health", title: "Health checks",
              keywords: ["health", "check", "healthy", "unhealthy", "probe", "http", "port answers"],
              text: "A health check is a port that answers, an HTTP path on the container's own published port returning 2xx or 3xx, or a command in the container that exits 0. It has an interval, a timeout, a number of failures before unhealthy, and a grace period after start. Unhealthy raises a notice with Restart; restarting automatically is an opt-in."),
        .init(id: "hosts", title: "Hosts and the fleet",
              keywords: ["host", "fleet", "mac", "pair", "add", "admin", "remote", "mini", "studio"],
              text: "One Mac is the Admin; others are Hosts it manages. Hosts ▸ Add Host finds Macs nearby or takes an address (a .lan or Tailscale name works; .local names don't cross networks). Pairing uses the code a host shows, or a fleet enrolment key. The admin then runs and stops containers there, pushes Flotilla updates, and can start or stop a host's container service if the host allows it."),
        .init(id: "kubernetes", title: "Kubernetes",
              keywords: ["kubernetes", "k8s", "cluster", "kubectl", "kind"],
              text: "Kubernetes lists local clusters made by container k8s, which Apple marks experimental. New Cluster creates one on This Mac or a host. container 1.5 can't restart a stopped cluster, so Recreate deletes and creates it again. A cluster needs Rosetta on that Mac (softwareupdate --install-rosetta --agree-to-license). kubectl on the admin can't reach a host's cluster yet."),
        .init(id: "stacks", title: "Groups and suggested stacks",
              keywords: ["group", "stack", "suggest", "compose", "together", "wordpress", "database"],
              text: "A group starts several containers together, in order, and can wait for a member's port before starting the next. Suggestions offers ready-made stacks, for example a database with a web app, created as groups. There is no Compose import."),
        .init(id: "notifications", title: "Notifications",
              keywords: ["notification", "notice", "bell", "alert", "dismiss", "warning", "error"],
              text: "The bell in the window bar counts what needs attention; it opens Notifications, where a notice can be read, fixed or dismissed. Dismiss hides it until the situation changes; errors can't be dismissed. Important ones also arrive as macOS notifications with their fix."),
        .init(id: "stopped", title: "container is stopped or not answering",
              keywords: ["stopped", "not running", "not answering", "unreachable", "service", "start", "system"],
              text: "container is stopped means Apple's container service isn't running on that Mac: start it from Overview, the host's page, or with container system start. Isn't answering means the admin can't reach that Mac at all: it may be asleep, off, or on another network. Flotilla starts container by itself after a Mac starts up, never to undo a stop."),
        .init(id: "arch", title: "Architecture and Rosetta",
              keywords: ["amd64", "x86", "intel", "arm64", "rosetta", "architecture", "platform"],
              text: "Containers run arm64 images natively. The Run form's Architecture can choose amd64, and Rosetta can be turned on in the container to run x86 programs. Rosetta must be installed on the Mac."),
        .init(id: "settings", title: "Settings and resets",
              keywords: ["settings", "preferences", "reset", "theme", "appearance", "forget"],
              text: "Settings holds appearance and themes, notifications per kind, how often to refresh, the Flotilla Helper, and host-mode switches. Advanced has three resets: preferences, window layout, and Forget all hosts and trust, which never touches containers or images."),
    ]

    /// The sections that best match `question`, best first, up to `limit` and within `budget`
    /// characters, so a search can't fill the model's small context on its own.
    public static func search(_ question: String, limit: Int = 3, budget: Int = 1800) -> [GretaSection] {
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        let lowered = question.lowercased()
        let scored = sections.map { section -> (GretaSection, Int) in
            var score = 0
            for keyword in section.keywords {
                if keyword.contains(" ") { if lowered.contains(keyword) { score += 3 } }
                else if words.contains(keyword) || words.contains(where: { $0.hasPrefix(keyword) && keyword.count > 3 }) { score += 2 }
            }
            for word in words where section.title.lowercased().contains(word) { score += 1 }
            return (section, score)
        }
        var picked: [GretaSection] = []
        var used = 0
        for (section, score) in scored.sorted(by: { $0.1 > $1.1 }) where score > 0 && picked.count < limit {
            guard used + section.text.count <= budget else { continue }
            picked.append(section)
            used += section.text.count
        }
        return picked
    }
}

/// Text from a container — a name, a label, an image reference — on its way to Greta (Q52): it is
/// data written by whoever made the container, so it is cleaned, shortened and never trusted as an
/// instruction. Control characters and anything that could pass as markup go; length is capped.
public enum GretaText {
    public static func untrusted(_ text: String, limit: Int = 80) -> String {
        // Counted in Unicode scalars, not characters: "a" and ten thousand combining marks is one
        // character and 20 KB (Kyle, 12 October). A mark may follow a letter once; a run of them
        // is dropped. Quotes go too, so a value can always be shown quoted as data.
        var scalars: [Unicode.Scalar] = []
        var marks = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format:
                scalars.append(" "); marks = 0
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks == 1 { scalars.append(scalar) }
            default:
                marks = 0
                scalars.append("<>{}[]`\"".unicodeScalars.contains(scalar) ? " " : scalar)
            }
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let collapsed = String(view).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return capped(collapsed, scalars: limit)
    }

    /// At most `limit` Unicode scalars, with "…" when cut.
    public static func capped(_ text: String, scalars limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(view) + "…"
    }

    /// As many whole lines as fit in `limit` UTF-8 bytes (newlines counted), then "(truncated)" if
    /// any were left out. The first line is always kept.
    public static func wholeLines(_ lines: [String], bytes limit: Int) -> [String] {
        var kept: [String] = []
        var used = 0
        for line in lines {
            let size = line.utf8.count + 1
            if !kept.isEmpty, used + size > limit { return kept + ["(truncated)"] }
            kept.append(line)
            used += size
        }
        return kept
    }

    /// At most `limit` UTF-8 bytes, cut on a scalar boundary — for a whole block bound for the
    /// model, whose context is measured in tokens, not characters.
    public static func capped(_ text: String, bytes limit: Int, marker: String = "\n(truncated)") -> String {
        guard text.utf8.count > limit else { return text }
        var view = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            used += String(scalar).utf8.count
            if used > limit { break }
            view.append(scalar)
        }
        return String(view) + marker
    }

    /// A bare "yes" (or "sure", "go ahead"…) with nothing else in it. The model can't tell what it
    /// agreed to from a small recap, so the app restates her last message with it (the owner,
    /// 12 October: "yes" twice got the same explanation twice).
    public static func isBareAgreement(_ text: String) -> Bool {
        let words = text.lowercased()
            .unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        let phrase = String(words).split(separator: " ").joined(separator: " ")
        return agreements.contains(phrase)
    }

    private static let agreements: Set<String> = [
        "yes", "yes please", "yeah", "yep", "yup", "sure", "sure thing", "ok", "okay", "ok please",
        "please", "please do", "do it", "go ahead", "go for it", "sounds good", "yes do it",
        "yes go ahead", "yes sure", "ok sure", "sure go ahead", "y", "absolutely", "definitely",
    ]

    /// Whether a message mentions a password or another secret. Such a message is used for nothing
    /// but choosing a recipe and is never kept: no parse can tell the secret from the rest
    /// ("postgres password called hunter2" put it in the container's name; Kyle, 12 October).
    public static func mentionsSecret(_ text: String) -> Bool {
        // Look-alikes read as letters ("p@ssw0rd"), then two views: the words, and every letter run
        // together ("pass word", "api-key"). It errs towards yes — a false alarm only means the
        // draft stays the plain recipe — because each miss Kyle found put a password in a draft.
        let plain = String(text.lowercased().map { lookAlikes[$0] ?? $0 })
        let words = plain.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let squashed = String(plain.filter(\.isLetter))
        return words.contains(where: secretWords.contains) || secretStems.contains(where: squashed.contains)
    }

    private static let lookAlikes: [Character: Character] = ["@": "a", "4": "a", "$": "s", "0": "o", "1": "i", "3": "e", "5": "s", "!": "i"]
    private static let secretWords: Set<String> = ["pass", "pwd", "pw", "secret", "secrets", "token", "tokens",
                                                    "key", "keys", "apikey", "passcode", "creds", "auth"]
    private static let secretStems = ["password", "passwd", "passphrase", "credential", "apikey", "accesskey",
                                      "secretkey", "privatekey", "loginkey", "authtoken"]

    /// What a chat keeps in place of a message that mentioned a secret.
    public static let hiddenMessage = "🔒 Hidden: this message mentioned a password, so Flotilla didn't keep it."

    /// How much of `reply` is the words of `earlier` (0…1, over distinct words of three letters or
    /// more). A small model asked twice tends to say the same thing again in other order.
    public static func overlap(_ reply: String, with earlier: String) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        }
        let new = words(reply), old = words(earlier)
        guard !new.isEmpty, !old.isEmpty else { return 0 }
        return Double(new.intersection(old).count) / Double(min(new.count, old.count))
    }
}
