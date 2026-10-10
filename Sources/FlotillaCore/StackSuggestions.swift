import Foundation

// Suggestions: ready-made stacks created as a group in one click (decided with the owner,
// 2026-10-06; DECISIONS Q28). The five are Iris's top five, pinned, and each is live-tested
// before it ships — "offer what you have actually run".
//
// A stack is a recipe, not a group: it names *roles* (`db`, `site`) and leaves the container
// names, the network, the ports on this Mac and the wiring to `StackPlanner`, which fills them in
// from what the user chose in the form and what this Mac already has.
//
// ## Templates
//
// Env values and notes may carry three kinds of token, resolved by the planner:
//
// - `{{option:ID}}` — a field the user can change in the form (database name, user…);
// - `{{host:ROLE}}` and `{{port:ROLE}}` — where another service is reached. With a DNS domain in
//   use for containers that is the service's **name** and its own port; without one it is the
//   stack network's **gateway** and a port published there (Q28: "names if set up, else gateway").

/// A field the user may change before the stack is built. Every one has a working default.
public struct StackOption: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Letters, numbers, dots, dashes, underscores — database and user names.
        case identifier
        case email
    }

    public let id: String
    public let label: String
    public let defaultValue: String
    public let help: String
    public let kind: Kind

    public init(id: String, label: String, defaultValue: String, help: String,
                kind: Kind = .identifier) {
        self.id = id
        self.label = label
        self.defaultValue = defaultValue
        self.help = help
        self.kind = kind
    }

    /// Why a value is refused, or `nil`.
    public func problem(with value: String) -> String? {
        switch kind {
        case .identifier:
            Allowlist.accepts(value, as: .identifier) ? nil : ValueShape.identifier.rule
        case .email:
            // Deliberately a real-looking domain: pgAdmin's validator refuses the special-use
            // ones (.test, .local, .example) — checked live before shipping.
            Self.isEmail(value) ? nil : "Expected an email address such as admin@example.com."
        }
    }

    static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return value.allSatisfy { $0.isASCII && !$0.isWhitespace && !"\"'<>(),;:\\[]".contains($0) }
    }
}

/// A named volume a service mounts, created with the stack.
public struct StackVolume: Sendable, Equatable {
    /// Appended to the container's name: `shop-db` + `data` → `shop-db-data`.
    public let suffix: String
    public let path: String

    public init(suffix: String = "data", path: String) {
        self.suffix = suffix
        self.path = path
    }
}

public struct StackService: Sendable, Equatable, Identifiable {
    /// Short and stable — the container is `<name>-<role>`.
    public let role: String
    public let title: String
    public let image: String
    public let env: [String]
    public let secretEnv: [SecretEnv]
    public let volumes: [StackVolume]
    /// The port a browser opens, published on `127.0.0.1` only. Its port on this Mac is a field.
    public let webPort: Int?
    /// The port the *other services* reach this one on. Published on the gateway — never the
    /// Mac's LAN address — when the stack is wired without a domain.
    public let wiredPort: Int?
    /// Start holds the next service until this answers (Q21 amended).
    public let readyPort: Int?
    public let command: [String]

    public var id: String { role }

    public init(role: String, title: String, image: String, env: [String] = [],
                secretEnv: [SecretEnv] = [], volumes: [StackVolume] = [], webPort: Int? = nil,
                wiredPort: Int? = nil, readyPort: Int? = nil, command: [String] = []) {
        self.role = role
        self.title = title
        self.image = image
        self.env = env
        self.secretEnv = secretEnv
        self.volumes = volumes
        self.webPort = webPort
        self.wiredPort = wiredPort
        self.readyPort = readyPort
        self.command = command
    }
}

public struct StackSuggestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    /// Said plainly where a licence is not a permissive one.
    public let licenceNote: String?
    public let options: [StackOption]
    /// In start order: databases first.
    public let services: [StackService]
    /// What to do once it is running — templated like env values.
    public let notes: [String]
    /// The service whose page "Open" opens.
    public let opens: String?

    public init(id: String, title: String, summary: String, licenceNote: String? = nil,
                options: [StackOption] = [], services: [StackService], notes: [String] = [],
                opens: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.licenceNote = licenceNote
        self.options = options
        self.services = services
        self.notes = notes
        self.opens = opens
    }

    public var images: [String] { services.map(\.image) }
}

// MARK: - The catalogue

extension StackSuggestion {
    /// Iris's top five (research 2026-10-05), in her ranking. None uses nginx. Every tag was pulled
    /// on 6 October before shipping; Prometheus publishes only full versions, so it is `v3.13.4`
    /// where the research said `v3.13`.
    ///
    /// Volumes only where the image fixes its own ownership: a fresh named volume mounts
    /// `root:root 755` with a `lost+found` in it (measured 14 September and 6 October), and
    /// pgAdmin, Grafana, Prometheus, RedisInsight — and Redis, whose entrypoint refuses to chown
    /// a directory holding `lost+found` — run as their own users and cannot write to one. Their state lives in the container, which
    /// survives Stop and Start but not Delete — the notes say so.
    public static let catalogue: [StackSuggestion] = [
        StackSuggestion(
            id: "postgres",
            title: "PostgreSQL + pgAdmin",
            summary: "A PostgreSQL 18 database and pgAdmin to browse it.",
            options: [
                StackOption(id: "database", label: "Database", defaultValue: "app",
                            help: "Created on first start."),
                StackOption(id: "user", label: "Database user", defaultValue: "app",
                            help: "Owns the database. Its password is generated."),
                StackOption(id: "email", label: "pgAdmin sign-in", defaultValue: "admin@example.com",
                            help: "pgAdmin signs you in with an email address. It isn't sent anywhere.",
                            kind: .email),
            ],
            services: [
                StackService(role: "db", title: "PostgreSQL", image: "docker.io/library/postgres:18.6",
                             env: ["POSTGRES_DB={{option:database}}", "POSTGRES_USER={{option:user}}"],
                             secretEnv: [SecretEnv(name: "POSTGRES_PASSWORD", secret: "db-password")],
                             // 18 moved the data directory up a level.
                             volumes: [StackVolume(path: "/var/lib/postgresql")],
                             wiredPort: 5432, readyPort: 5432),
                StackService(role: "admin", title: "pgAdmin", image: "docker.io/dpage/pgadmin4:9.18",
                             env: ["PGADMIN_DEFAULT_EMAIL={{option:email}}"],
                             secretEnv: [SecretEnv(name: "PGADMIN_DEFAULT_PASSWORD",
                                                   secret: "pgadmin-password")],
                             webPort: 80),
            ],
            notes: [
                "Sign in to pgAdmin as {{option:email}} with the pgadmin-password.",
                "Add a server: host {{host:db}}, port {{port:db}}, database {{option:database}}, "
                    + "user {{option:user}}, password db-password.",
            ],
            opens: "admin"),

        StackSuggestion(
            id: "wordpress",
            title: "WordPress + MariaDB",
            summary: "WordPress 7.1 on Apache with a MariaDB 12.3 database.",
            options: [
                StackOption(id: "database", label: "Database", defaultValue: "wordpress",
                            help: "Created on first start."),
                StackOption(id: "user", label: "Database user", defaultValue: "wordpress",
                            help: "WordPress signs in to MariaDB as this user."),
            ],
            services: [
                StackService(role: "db", title: "MariaDB", image: "docker.io/library/mariadb:12.3",
                             env: ["MARIADB_DATABASE={{option:database}}", "MARIADB_USER={{option:user}}"],
                             secretEnv: [SecretEnv(name: "MARIADB_PASSWORD", secret: "db-password"),
                                         SecretEnv(name: "MARIADB_ROOT_PASSWORD", secret: "root-password")],
                             volumes: [StackVolume(path: "/var/lib/mysql")],
                             wiredPort: 3306, readyPort: 3306),
                StackService(role: "site", title: "WordPress",
                             image: "docker.io/library/wordpress:7.1-php8.4-apache",
                             env: ["WORDPRESS_DB_HOST={{host:db}}:{{port:db}}",
                                   "WORDPRESS_DB_NAME={{option:database}}",
                                   "WORDPRESS_DB_USER={{option:user}}"],
                             secretEnv: [SecretEnv(name: "WORDPRESS_DB_PASSWORD", secret: "db-password")],
                             volumes: [StackVolume(path: "/var/www/html")],
                             webPort: 80),
            ],
            notes: ["Open the site to run WordPress's five-minute install."],
            opens: "site"),

        StackSuggestion(
            id: "redis",
            title: "Redis + RedisInsight",
            summary: "A persistent Redis 8 server, and RedisInsight to browse it.",
            licenceNote: "Redis 8 is offered under RSALv2, SSPLv1 or AGPLv3, and RedisInsight under "
                + "SSPL. Flotilla only names the images; check the terms suit how you use them.",
            services: [
                // No volume, measured 6 October: a fresh volume holds `lost+found`, so the image's
                // entrypoint declines to fix ownership ("Unknown file './lost+found'… Permissions
                // will not be modified") and Redis, running as `redis`, cannot write its AOF.
                StackService(role: "cache", title: "Redis", image: "docker.io/library/redis:8.10",
                             wiredPort: 6379, readyPort: 6379,
                             command: ["redis-server", "--appendonly", "yes"]),
                StackService(role: "insight", title: "RedisInsight",
                             image: "docker.io/redis/redisinsight:3.8",
                             env: ["RI_REDIS_HOST={{host:cache}}", "RI_REDIS_PORT={{port:cache}}"],
                             secretEnv: [SecretEnv(name: "RI_ENCRYPTION_KEY", secret: "encryption-key")],
                             webPort: 5540),
            ],
            notes: ["Open RedisInsight and accept its terms: Redis then appears, already connected "
                        + "(RedisInsight adds it only once its terms are accepted).",
                    "Redis has no password: it is reachable from this Mac and its containers only.",
                    "Redis keeps its data inside its container: it survives Stop and Start, not Delete."],
            opens: "insight"),

        StackSuggestion(
            id: "mysql",
            title: "MySQL + phpMyAdmin",
            summary: "A MySQL 9.7 database and phpMyAdmin to manage it.",
            options: [
                StackOption(id: "database", label: "Database", defaultValue: "app",
                            help: "Created on first start."),
                StackOption(id: "user", label: "Database user", defaultValue: "app",
                            help: "Owns the database. Its password is generated."),
            ],
            services: [
                StackService(role: "db", title: "MySQL", image: "docker.io/library/mysql:9.7",
                             env: ["MYSQL_DATABASE={{option:database}}", "MYSQL_USER={{option:user}}"],
                             secretEnv: [SecretEnv(name: "MYSQL_PASSWORD", secret: "db-password"),
                                         SecretEnv(name: "MYSQL_ROOT_PASSWORD", secret: "root-password")],
                             volumes: [StackVolume(path: "/var/lib/mysql")],
                             wiredPort: 3306, readyPort: 3306),
                StackService(role: "admin", title: "phpMyAdmin",
                             image: "docker.io/library/phpmyadmin:5.2-apache",
                             env: ["PMA_HOST={{host:db}}", "PMA_PORT={{port:db}}"],
                             webPort: 80),
            ],
            notes: ["Sign in to phpMyAdmin as {{option:user}} with the db-password."],
            opens: "admin"),

        StackSuggestion(
            id: "monitoring",
            title: "Prometheus + Grafana",
            summary: "Prometheus collecting metrics, and Grafana to chart them.",
            options: [
                StackOption(id: "user", label: "Grafana user", defaultValue: "admin",
                            help: "Grafana's administrator. Its password is generated."),
            ],
            services: [
                StackService(role: "prometheus", title: "Prometheus",
                             image: "docker.io/prom/prometheus:v3.13.4",
                             webPort: 9090, wiredPort: 9090),
                StackService(role: "grafana", title: "Grafana", image: "docker.io/grafana/grafana:13.2",
                             env: ["GF_SECURITY_ADMIN_USER={{option:user}}"],
                             secretEnv: [SecretEnv(name: "GF_SECURITY_ADMIN_PASSWORD",
                                                   secret: "admin-password")],
                             webPort: 3000),
            ],
            notes: [
                "Sign in to Grafana as {{option:user}} with the admin-password.",
                "Add a Prometheus data source at http://{{host:prometheus}}:{{port:prometheus}}.",
                "Prometheus and Grafana keep their data inside their containers: it survives Stop "
                    + "and Start, not Delete.",
            ],
            opens: "grafana"),
    ]
}

// MARK: - Planning

/// What the user chose in the form.
public struct StackChoices: Sendable, Equatable {
    public enum Network: Sendable, Equatable, Hashable {
        /// `<name>-net`, created with the stack.
        case new
        case existing(String)
    }

    /// The prefix for every container, volume and the network.
    public var name: String
    public var network: Network
    /// Role → this Mac's port for the service's web page.
    public var webPorts: [String: Int]
    /// Option id → value. Missing ids take the default.
    public var options: [String: String]

    public init(name: String, network: Network = .new, webPorts: [String: Int] = [:],
                options: [String: String] = [:]) {
        self.name = name
        self.network = network
        self.webPorts = webPorts
        self.options = options
    }
}

/// How the services reach each other (Q28).
public enum StackWiring: Sendable, Equatable {
    /// A DNS domain is in use for containers: by name. The domain is for display — bare names
    /// resolve inside the stack.
    case names(domain: String)
    /// No domain: through this gateway address, on ports published there.
    case gateway(String)
}

/// The concrete stack: everything `StackPlanner.plan` decided, ready to create.
public struct StackPlan: Sendable, Equatable {
    public let group: ContainerGroup
    public let network: String
    public let createsNetwork: Bool
    public let volumes: [String]
    public let images: [String]
    /// Secrets to generate, by name.
    public let secrets: [String]
    public let wiring: StackWiring
    public let openURL: String?
    public let notes: [String]
}

public enum StackPlanner {
    public static func containerName(_ name: String, _ role: String) -> String { "\(name)-\(role)" }
    public static func networkName(_ name: String) -> String { "\(name)-net" }
    public static func volumeName(_ name: String, _ role: String, _ volume: StackVolume) -> String {
        "\(name)-\(role)-\(volume.suffix)"
    }

    /// What this Mac already has, so the plan avoids every clash rather than failing half way.
    public struct Taken: Sendable, Equatable {
        public var containerNames: Set<String>
        public var volumes: Set<String>
        public var networks: Set<String>
        /// Ports already published on this Mac, or claimed by a group not yet running.
        public var hostPorts: Set<Int>

        public init(containerNames: Set<String> = [], volumes: Set<String> = [],
                    networks: Set<String> = [], hostPorts: Set<Int> = []) {
            self.containerNames = containerNames
            self.volumes = volumes
            self.networks = networks
            self.hostPorts = hostPorts
        }
    }

    /// A name for a new stack that clashes with nothing: the stack's id, then `-2`, `-3`…
    public static func suggestedName(for stack: StackSuggestion, taken: Taken,
                                     groupNames: Set<String>) -> String {
        var candidate = stack.id
        var counter = 2
        while nameProblem(candidate, stack: stack, network: .new, taken: taken,
                          groupNames: groupNames) != nil {
            candidate = "\(stack.id)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Why `name` cannot be used, or `nil`.
    public static func nameProblem(_ raw: String, stack: StackSuggestion,
                                   network: StackChoices.Network, taken: Taken,
                                   groupNames: Set<String>) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the stack a name." }
        guard Allowlist.accepts(name, as: .identifier),
              name == name.lowercased() else {
            return "Use lowercase letters, numbers and dashes, starting with a letter or number."
        }
        if groupNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A group called “\(name)” already exists."
        }
        for service in stack.services {
            let container = containerName(name, service.role)
            if taken.containerNames.contains(container) {
                return "A container called “\(container)” already exists."
            }
            for volume in service.volumes where taken.volumes.contains(volumeName(name, service.role, volume)) {
                return "A volume called “\(volumeName(name, service.role, volume))” already exists."
            }
        }
        if network == .new, taken.networks.contains(networkName(name)) {
            return "A network called “\(networkName(name))” already exists."
        }
        return nil
    }

    /// The port on this Mac a `--publish` spec claims: `8080:80`, `127.0.0.1:8080:80`,
    /// `8080:80/tcp`. `nil` for anything else — a range, or a spec that does not parse.
    public static func hostPort(fromPublishSpec spec: String) -> Int? {
        let withoutProto = spec.split(separator: "/").first.map(String.init) ?? spec
        let parts = withoutProto.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        return Int(parts[parts.count - 2])
    }

    /// A free port on this Mac: `preferred`, or the next one up that nothing has.
    public static func freePort(preferring preferred: Int, avoiding used: Set<Int>) -> Int {
        var port = max(preferred, 1024)
        while used.contains(port) { port += 1 }
        return port
    }

    /// Default web ports for a stack: each service's own web port mapped near 8080-style
    /// conventions (80 → 8080), moved up past anything already taken.
    public static func defaultWebPorts(for stack: StackSuggestion, avoiding used: Set<Int>) -> [String: Int] {
        var used = used
        var ports: [String: Int] = [:]
        for service in stack.services {
            guard let web = service.webPort else { continue }
            let port = freePort(preferring: web < 1024 ? 8000 + web : web, avoiding: used)
            ports[service.role] = port
            used.insert(port)
        }
        return ports
    }

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case missingWebPort(String)
        case badOption(String, String)

        public var description: String {
            switch self {
            case .missingWebPort(let role): "Choose a port on this Mac for \(role)."
            case .badOption(let label, let why): "\(label): \(why)"
            }
        }
    }

    /// The whole stack, concretely.
    ///
    /// - Parameters:
    ///   - wiring: names (a domain is in use) or the stack network's gateway, which is only known
    ///     once the network exists — so the app creates the network, then plans.
    ///   - usedHostPorts: for the gateway ports; the web ports are already in `choices`.
    public static func plan(_ stack: StackSuggestion, choices: StackChoices, wiring: StackWiring,
                            usedHostPorts: Set<Int>) throws -> StackPlan {
        let name = choices.name.trimmingCharacters(in: .whitespaces)
        var options: [String: String] = [:]
        for option in stack.options {
            let value = (choices.options[option.id] ?? option.defaultValue)
                .trimmingCharacters(in: .whitespaces)
            if let problem = option.problem(with: value) { throw PlanError.badOption(option.label, problem) }
            options[option.id] = value
        }

        // Where each wired service is reached, decided once for every template that names it.
        var used = usedHostPorts.union(choices.webPorts.values)
        var hosts: [String: String] = [:]
        var ports: [String: Int] = [:]
        var gatewayPorts: [String: Int] = [:]
        for service in stack.services {
            guard let wired = service.wiredPort else { continue }
            switch wiring {
            case .names:
                hosts[service.role] = containerName(name, service.role)
                ports[service.role] = wired
            case .gateway(let gateway):
                // Far from the conventional ports so it never takes one a person would expect:
                // 3306 → 33306, 5432 → 35432, as the September WordPress group did.
                let port = freePort(preferring: 30000 + wired, avoiding: used)
                used.insert(port)
                hosts[service.role] = gateway
                ports[service.role] = port
                gatewayPorts[service.role] = port
            }
        }

        func fill(_ text: String) -> String {
            var out = text
            for (id, value) in options { out = out.replacingOccurrences(of: "{{option:\(id)}}", with: value) }
            for (role, host) in hosts { out = out.replacingOccurrences(of: "{{host:\(role)}}", with: host) }
            for (role, port) in ports { out = out.replacingOccurrences(of: "{{port:\(role)}}", with: "\(port)") }
            return out
        }

        let network: String
        let createsNetwork: Bool
        switch choices.network {
        case .new: network = networkName(name); createsNetwork = true
        case .existing(let existing): network = existing; createsNetwork = false
        }

        var members: [GroupMember] = []
        var volumes: [String] = []
        for service in stack.services {
            var published: [String] = []
            if let web = service.webPort {
                guard let host = choices.webPorts[service.role] else {
                    throw PlanError.missingWebPort(service.title)
                }
                // This Mac only: a development stack has no business on the office network.
                published.append("127.0.0.1:\(host):\(web)")
            }
            if case .gateway(let gateway) = wiring, let port = gatewayPorts[service.role],
               let wired = service.wiredPort {
                // On the gateway, never 0.0.0.0: reachable from containers and this Mac, refused
                // on its LAN address (measured 14 September).
                published.append("\(gateway):\(port):\(wired)")
            }
            let mounts = service.volumes.map { volume -> String in
                let volumeName = volumeName(name, service.role, volume)
                volumes.append(volumeName)
                return "\(volumeName):\(volume.path)"
            }
            members.append(GroupMember(name: containerName(name, service.role), image: service.image,
                                       ports: published, env: service.env.map(fill),
                                       volumes: mounts, command: service.command,
                                       readyPort: service.readyPort, secretEnv: service.secretEnv))
        }

        let group = ContainerGroup(name: name, network: network, members: members,
                                   notes: stack.notes.map(fill))
        let openURL = stack.opens.flatMap { role in choices.webPorts[role] }
            .map { "http://127.0.0.1:\($0)" }
        return StackPlan(group: group, network: network, createsNetwork: createsNetwork,
                         volumes: volumes, images: stack.images,
                         secrets: GroupSecrets.secretNames(in: group), wiring: wiring,
                         openURL: openURL, notes: stack.notes.map(fill))
    }
}
