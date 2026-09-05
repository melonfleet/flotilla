import Foundation

// The Q1 security boundary (see DECISIONS.md → "Proposal review", Q1: the middle path).
//
// A host-mode peer never accepts an arbitrary command string and is never a generic
// remote shell. Every argv that reaches `ContainerHost.run` is first matched against
// this table: `args[0]` (plus a second level, e.g. `image pull`) must name an
// allowlisted `container` subcommand, and each flag/operand is validated against a
// declared shape. Anything not explicitly listed is rejected — **default deny**.
//
// This file is pure logic: no Process, no I/O, no platform APIs. That is deliberate —
// it is the piece most worth testing exhaustively, so it must be testable anywhere.
//
// Note on shell metacharacters: we spawn via argv (`Process.arguments`), never through
// a shell, so `;` and `|` are not injection vectors by themselves. We reject them in
// structured positions anyway — defence in depth, and it keeps the audit record
// (`ValidatedCommand.auditDescription`) unambiguous when it is later pasted or logged.

// MARK: - Value shapes

/// The permitted shape of a flag value or operand. Each case is a whitelist, not a
/// blacklist: anything the shape does not explicitly describe is rejected.
public enum ValueShape: String, Sendable, Equatable, CaseIterable {
    /// Container / volume / network name or id. Deliberately ASCII-only, which is
    /// what rejects Unicode lookalikes (Cyrillic `а` in `аlpine`, etc.).
    case identifier
    /// `[registry[:port]/]name[:tag][@sha256:…]`.
    case imageReference
    /// `[bindIP:]hostPort:containerPort[/tcp|/udp]`.
    case portMapping
    /// `KEY=VALUE`.
    case envAssignment
    /// `source:/dest[:ro|rw]` where source is a named volume or an absolute host path.
    case mountSpec
    /// Absolute path, no `.`/`..` components.
    case absolutePath
    /// One end of a `container copy`: either `name:/path/in/container` or `/path/on/host`.
    case copyEndpoint
    /// A host path a **build** reads: the context directory, or a Dockerfile.
    ///
    /// Deliberately not `.absolutePath`, which checks shape and nothing else. A build
    /// context is a whole directory *tree* handed to the builder, so this is a broader read
    /// grant than `copy`'s single file and must cross `MountPolicy` for the same reason
    /// `.copyEndpoint`'s host side does — grammar is not authorisation.
    case hostBuildPath
    /// `container build --progress`: `auto`, `plain` or `tty`. A closed set, taken from the
    /// captured help, not a free string.
    case progressType
    /// One `container machine set` setting: `cpus=<n>`, `memory=<size>` or
    /// `home-mount=<ro|rw|none>`. **A closed set, not a generic `key=value`.**
    case machineSetting

    /// A **bare** home-directory mount mode — `ro`, `rw` or `none`.
    ///
    /// Distinct from `.machineSetting` on purpose. `machine set` takes `home-mount=ro` as a
    /// `key=value` operand, but `machine create --home-mount` takes the value **alone**.
    /// Confirmed against the leaf help, and getting it wrong broke create from both ends at
    /// once: the allowlist refused the CLI's own spelling, and the spelling the allowlist
    /// wanted was one the CLI rejects. Per-leaf asymmetry again — do not merge these.
    case homeMountMode
    /// Whole seconds, 0…86400.
    case durationSeconds
    /// `SIGTERM`, `TERM`, or a signal number 1…64.
    case signal
    /// Small positive integer, 1…1024 (cpus, log lines, …).
    case memorySize
    /// `<digits>[K|M|G][B]`.
    case count
    /// `os/arch[/variant]`.
    case platform
    /// IPv4 CIDR, `a.b.c.d/n`.
    case cidr
    /// IPv6 CIDR, `prefix::/n`. Separate from `.cidr` rather than a widened version of it:
    /// accepting either shape wherever one is expected would let an IPv6 prefix through to
    /// `--subnet` (and vice versa), which the CLI would then reject far less clearly.
    case cidrV6
    /// `key=value` for `--label` / `--opt` / `--option`.
    case keyValue
    /// One of the CLI's `--format` values.
    case outputFormat
    /// `--format` for the **machine** leaves, which take only `json` or `table`.
    ///
    /// Separate from `.outputFormat` because the captured help proves the sets differ: every
    /// other leaf lists `json, table, yaml, toml`, and `container machine list` lists exactly
    /// `json, table`. Accepting the wider set there let a caller past validation into a CLI
    /// rejection — grammar drift, and the allowlist must be at least as strict as the CLI.
    case machineOutputFormat
    /// A token of the command line run *inside* the container. The one deliberately
    /// permissive shape — see `TrailingPolicy.command`.
    case commandToken
}

extension ValueShape {
    /// Whether a value of this shape is **data supplied by the caller** rather than a name or a
    /// choice from a closed set. Drives audit redaction — see `Allowlist.redact`.
    ///
    /// Written as an exhaustive `switch` with no `default` on purpose: a new shape must be
    /// classified before it compiles, so the failure mode is a build error rather than a value
    /// quietly defaulting into an audit log. The partition is the same discipline the exposure
    /// registry test enforces for `Exposure`.
    var carriesFreeFormData: Bool {
        switch self {
        // Arbitrary caller data. `envAssignment` is the SEC-03 case verbatim: `--env
        // DATABASE_PASSWORD=…`. `keyValue` backs `--label`/`--opt`/`--option`, which are just as
        // open, and `commandToken` is a token of a shell command line.
        case .envAssignment, .keyValue, .commandToken:
            true
        // Host paths. These carry the account name, and often the sensitive part *is* the path —
        // `--volume /Users/someone/.ssh:/keys` says more than it looks like it does.
        case .mountSpec, .absolutePath, .copyEndpoint, .hostBuildPath:
            true
        // Names, and closed sets. These have to survive: an audit line that hides *which*
        // container was deleted, *which* image was pulled, or *which* `machine set` setting was
        // changed records that something happened and withholds the only interesting part.
        case .identifier, .imageReference, .machineSetting, .homeMountMode,
             .progressType, .signal, .platform, .outputFormat, .machineOutputFormat:
            false
        // Numbers, sizes and network shapes. Configuration rather than content. A port mapping
        // can carry a bind address, which is precisely what an auditor wants to see.
        case .portMapping, .durationSeconds, .memorySize, .count, .cidr, .cidrV6:
            false
        }
    }

    /// What the shape actually permits, in words a user can act on.
    ///
    /// Added because the message read `'Test 1' is not a valid identifier`, which states the
    /// verdict and withholds the rule. The owner reasonably concluded capitals were the problem
    /// and retried in lowercase; the real objection was the **space** — `Test1` is fine. A
    /// validation message that leads someone to the wrong conclusion is worse than a terse
    /// one, because they then design around a constraint that does not exist.
    public var rule: String {
        switch self {
        case .identifier:
            "Use letters, numbers, dots, dashes or underscores, starting with a letter or number. No spaces."
        case .imageReference:
            "Expected something like `docker.io/library/alpine:latest` — no spaces."
        case .portMapping:
            "Expected `hostPort:containerPort`, optionally `/tcp` or `/udp` — for example `8080:80`."
        case .envAssignment:
            "Expected `KEY=VALUE`."
        case .mountSpec:
            "Expected `source:/destination`, optionally `:ro` or `:rw`, where source is a named volume or an absolute path."
        case .absolutePath:
            "Expected an absolute path with no `.` or `..` components."
        case .copyEndpoint:
            "Expected `container:/path` or an absolute path on this Mac."
        case .hostBuildPath:
            "Expected an absolute path on this Mac that the mount policy permits the build to read."
        case .progressType:
            "Expected `auto`, `plain` or `tty`."
        case .machineSetting:
            "Expected `cpus=<number>`, `memory=<size>` such as 8G, or `home-mount=ro|rw|none`."
        case .homeMountMode:
            "Expected `ro`, `rw` or `none`."
        case .durationSeconds:
            "Expected whole seconds, 0 to 86400."
        case .signal:
            "Expected a signal name like `SIGTERM` or `TERM`, or a number from 1 to 64."
        case .memorySize:
            "Expected a size like `512M` or `2G`."
        case .count:
            "Expected a whole number from 1 to 1024."
        case .platform:
            "Expected `os/arch`, optionally `/variant` — for example `linux/arm64`."
        case .cidr:
            "Expected an IPv4 range in CIDR form — for example `10.0.0.0/24`."
        case .cidrV6:
            "Expected an IPv6 prefix in CIDR form — for example `fd00:1234::/64`."
        case .keyValue:
            "Expected `key=value`."
        case .outputFormat:
            "Expected one of the CLI's `--format` values."
        case .machineOutputFormat:
            "Expected `json` or `table`."
        case .commandToken:
            "Not a permitted command token."
        }
    }
}

// MARK: - Table types

/// One flag a subcommand accepts. `value == nil` means a boolean switch.
public struct FlagSpec: Sendable, Equatable {
    public let long: String?
    public let short: Character?
    public let value: ValueShape?
    public let repeatable: Bool
    public let maxRepeats: Int

    public init(long: String? = nil,
                short: Character? = nil,
                value: ValueShape? = nil,
                repeatable: Bool = false,
                maxRepeats: Int = 1) {
        precondition(long != nil || short != nil, "a flag needs at least one spelling")
        self.long = long
        self.short = short
        self.value = value
        self.repeatable = repeatable
        self.maxRepeats = repeatable ? maxRepeats : 1
    }

    /// How the flag is written back into the canonical argv: long form when it has one.
    var canonicalSpelling: String { long.map { "--\($0)" } ?? "-\(short!)" }
}

/// How many bare (non-flag) operands the subcommand takes, and their shape.
public struct OperandSpec: Sendable, Equatable {
    public let shape: ValueShape
    public let min: Int
    public let max: Int
    /// Long flag names that waive the `min` — e.g. `stop --all` needs no container id.
    public let minWaivedBy: Set<String>

    public init(shape: ValueShape = .identifier, min: Int, max: Int, minWaivedBy: Set<String> = []) {
        self.shape = shape
        self.min = min
        self.max = max
        self.minWaivedBy = minWaivedBy
    }

    // `public` because it is used as a default argument in the public
    // CommandSpec.init below — an internal member can't be referenced there.
    public static let none = OperandSpec(min: 0, max: 0)
}

/// What may follow the operands.
public enum TrailingPolicy: Sendable, Equatable {
    /// No extra tokens, and a bare `--` is itself rejected.
    case forbidden
    /// A command line to run inside the container (`container run alpine echo hi`).
    case command(maxTokens: Int)
    /// **Exactly** this token sequence, or nothing. Nothing else is accepted — not a
    /// superset, not a reordering, not a single extra flag.
    ///
    /// Exists for `exec`. A process list needs `container exec <id> ps …`, but allowlisting
    /// `exec` with `.command` would permit `exec <id> sh`, which is arbitrary code execution
    /// inside the container and would hollow out the whole point of having a command
    /// allowlist — most of all in Phase 2, where this grammar *is* the wire boundary and the
    /// caller is a remote peer rather than the machine's owner.
    ///
    /// So the app gets the one fixed invocation it needs and nothing more. If a second fixed
    /// command is ever required, add a second `CommandSpec`; do not relax this to `.command`.
    case exact([String])
}

/// Whether this caller may run **arbitrary** commands inside a container.
///
/// The `.exact` note above says not to relax `exec` to `.command`, and that still stands —
/// this does not relax it. It selects between two separate specs, so the strict one remains
/// the default and the permissive one has to be asked for by name.
///
/// The distinction is *who is asking*, which grammar alone cannot express. On the machine's
/// own owner a shell inside a container grants nothing they could not get by typing
/// `container exec -it … sh` themselves. Reached over the Phase 2 wire it is remote code
/// execution on someone else's Mac. Same tokens, completely different risk — so a host
/// serving a remote peer must leave this at `.processListOnly`, exactly as it must pass its
/// own `MountPolicy` rather than one the client supplied.
public enum ExecPolicy: Sendable, Equatable {
    /// `exec` is limited to the one fixed process-list query. **The default**, and the only
    /// safe setting for a host acting on behalf of anyone but itself.
    case processListOnly
    /// `exec` may also start an interactive process — a shell — in a running container.
    /// Only ever for a `ContainerCLI` driving its own machine on behalf of the person at the
    /// keyboard. This is what backs the detail view's Terminal tab.
    case interactiveShell
}

/// One allowlisted subcommand.
/// Who is asking, and therefore which subcommands are on offer at all.
///
/// **The third capability dimension, alongside `MountPolicy` and `ExecPolicy`, and it exists
/// because `Allowlist` cannot express this any other way.** The table validates *grammar*: it
/// answers "is this argv well-formed for this subcommand". The 47-spec audit (2026-08-18,
/// `research/ALLOWLIST-AUDIT.md`) found five blockers that no value shape can fix, because the
/// argv is already perfectly well-formed — `machine delete production` is valid grammar, and so
/// is `machine set home-mount=rw`, which points the default machine at this user's home directory
/// read-write on its next boot. Tightening a regex cannot refuse an operation; only a capability
/// can.
///
/// Injected per `ContainerCLI` exactly as the other two are, so one table serves a local owner
/// and a remote peer differently rather than being copied and edited.
public enum WirePolicy: Sendable, Equatable {
    /// The machine's own owner, driving their own Mac. Everything the table allows is on offer.
    case localOwner
    /// A Phase 2 peer over mTLS. Only specs marked `.exposed` are reachable, and specs that carry
    /// `wireRequiredFlags` must include them — an unbounded read is a denial-of-service against
    /// the host peer even when its grammar is impeccable.
    case remotePeer
}

/// Whether a subcommand is offered to a remote caller at all.
public enum Exposure: Sendable, Equatable {
    /// Reachable by a Phase 2 peer, subject to the rest of the table and to `MountPolicy`.
    case exposed
    /// **Local only.** Reachable by the machine's owner; refused outright over the wire, with the
    /// reason recorded on each spec so the decision is readable where it is made.
    case localOnly(reason: String)
}

public struct CommandSpec: Sendable, Equatable {
    /// `["ls"]`, `["image", "pull"]`, …
    public let path: [String]
    /// Whether the operation changes host state. The transport layer (Phase 2) uses
    /// this to decide what needs confirmation and what is safe to retry.
    public let mutates: Bool
    /// The per-invocation deadline, in seconds. **Enforced** — `LocalHost` terminates, waits out
    /// a grace period, then `SIGKILL`s a child that outlives it (DECISIONS.md Q15). Not enforced
    /// *here*: validation stays synchronous and pure, and the timeout belongs to whoever spawns
    /// the process.
    ///
    /// `0` means no deadline, which is right for the interactive substitutes and wrong for
    /// everything else. These numbers went unread for weeks, so treat any change to one as a
    /// behaviour change: `image pull` and `build` need 1800, not the 30s default.
    public let timeoutHint: TimeInterval
    public let flags: [FlagSpec]
    public let operands: OperandSpec
    public let trailing: TrailingPolicy
    /// Whether a Phase 2 peer may reach this at all. See `WirePolicy`.
    public let exposure: Exposure
    /// Long flag names a remote caller **must** supply. Empty for almost everything; it exists
    /// for the commands whose default is unbounded — `logs` without `-n` "will print all of the
    /// logs" (its own help), and `stats` streams until killed. Harmless locally, a memory and
    /// wire hazard from a peer.
    public let wireRequiredFlags: [String]

    public init(_ path: [String],
                mutates: Bool,
                timeoutHint: TimeInterval = 30,
                flags: [FlagSpec] = [],
                operands: OperandSpec = .none,
                trailing: TrailingPolicy = .forbidden,
                exposure: Exposure = .exposed,
                wireRequiredFlags: [String] = []) {
        self.path = path
        self.mutates = mutates
        self.timeoutHint = timeoutHint
        self.flags = flags
        self.operands = operands
        self.trailing = trailing
        self.exposure = exposure
        self.wireRequiredFlags = wireRequiredFlags
    }

    public var name: String { path.joined(separator: " ") }

    func flag(long: String) -> FlagSpec? { flags.first { $0.long == long } }
    func flag(short: Character) -> FlagSpec? { flags.first { $0.short == short } }
}

// MARK: - Result types

/// An argv that has passed the allowlist. The only thing `ContainerCLI` hands to a
/// `ContainerHost`. `arguments` is *canonicalised*, not the caller's original array:
/// `-a` becomes `--all`, `--format=json` becomes `--format json`, and flags are
/// grouped before operands. Two spellings of the same request therefore produce one
/// audit string.
public struct ValidatedCommand: Sendable, Equatable {
    public let subcommand: [String]
    public let arguments: [String]
    public let mutates: Bool
    public let timeoutHint: TimeInterval

    /// The audit record: what a host peer logs as having been asked to run, **with free-form
    /// values shaped away**. `container run --env <envAssignment> --volume <mountSpec> alpine`.
    ///
    /// Stored rather than computed, and computed by the validator, because that is the only place
    /// the *spec* is known — and without the spec you cannot tell a flag's value from an operand.
    /// It is stored rather than derivable-on-demand so there is no unredacted form to reach for by
    /// mistake: see `localPreview` for the one case that legitimately wants the whole argv.
    public let auditDescription: String

    public init(subcommand: [String], arguments: [String], mutates: Bool,
                timeoutHint: TimeInterval, auditDescription: String? = nil) {
        self.subcommand = subcommand
        self.arguments = arguments
        self.mutates = mutates
        self.timeoutHint = timeoutHint
        // The fallback is for the handful of direct constructions in tests. It shapes nothing,
        // because with no spec there is nothing to shape *by* — so it redacts every value.
        self.auditDescription = auditDescription
            ?? (["container"] + subcommand
                + arguments.dropFirst(subcommand.count).map { $0.hasPrefix("-") ? $0 : "<value>" })
                .joined(separator: " ")
    }

    /// The full argv, for showing a person the command **they just typed** before they run it.
    ///
    /// Deliberately a different property with a different name from `auditDescription`, because
    /// the two have opposite requirements and one string cannot serve both. A build form's preview
    /// is useless if it renders the `--build-arg` the user just entered as `<keyValue>`; an audit
    /// line that carries that same value is the SEC-03 finding. Distinguishing them by *audience*
    /// is the only way both can be right.
    ///
    /// **Never log this, never put it on a wire, never put it in an alert.** The audience is the
    /// person at the keyboard who supplied the values, and nobody else.
    public var localPreview: String { (["container"] + arguments).joined(separator: " ") }
}

public enum AllowlistError: Error, Equatable, Sendable {
    case emptyCommand
    case unknownSubcommand(String)
    /// The subcommand exists and the argv is well-formed, and it is **not offered to remote
    /// callers**. Distinct from `unknownSubcommand` on purpose: "you may not" and "no such thing"
    /// are different answers, and a host peer that conflated them would teach a caller that
    /// probing is indistinguishable from a typo.
    case notExposedToWire(command: String, reason: String)
    /// A remote caller omitted a flag that bounds the command's output.
    case flagRequiredOverWire(command: String, flag: String)
    case unknownFlag(String)
    case malformedFlag(String)
    case flagRequiresValue(String)
    case flagTakesNoValue(String)
    case repeatedFlag(String)
    case invalidValue(context: String, value: String, shape: ValueShape)
    case pathTraversal(context: String, value: String)
    /// A bind-mount source that is a well-formed absolute path but is not permitted by
    /// the filesystem owner's `MountPolicy`. Distinct from `invalidValue` on purpose:
    /// the value is *valid*, the caller is simply not authorised to mount it.
    case hostPathNotPermitted(context: String, path: String)
    case illegalCharacter(argument: String, scalar: UInt32)
    case tooManyArguments(count: Int, limit: Int)
    case argumentTooLong(length: Int, limit: Int)
    case commandTooLong(length: Int, limit: Int)
    case tooManyOperands(count: Int, limit: Int)
    case missingOperand(subcommand: String, need: Int)
    case separatorNotAllowed
}

extension AllowlistError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyCommand: "empty command"
        case .unknownSubcommand(let s): "subcommand not allowed: \(s)"
        case .notExposedToWire(let c, let reason):
            "`\(c)` is not available to remote callers — \(reason)"
        case .flagRequiredOverWire(let c, let flag):
            // Rendered by length, because `-n` is the one required flag with no long spelling and
            // the message must be copy-pasteable: `logs --n 100 web` is refused by the grammar.
            "`\(c)` requires `\(flag.count == 1 ? "-" : "--")\(flag)` when called remotely, "
            + "so its output is bounded"
        case .unknownFlag(let f): "flag not allowed: \(f)"
        case .malformedFlag(let f): "malformed flag: \(f)"
        case .flagRequiresValue(let f): "flag \(f) requires a value"
        case .flagTakesNoValue(let f): "flag \(f) takes no value"
        case .repeatedFlag(let f): "flag \(f) repeated"
        case .invalidValue(let c, let v, let s): "‘\(v)’ isn't a valid \(s.rawValue) for \(c). \(s.rule)"
        case .pathTraversal(let c, let v): "\(c): path traversal in '\(v)'"
        case .hostPathNotPermitted(let c, let p): "\(c): host path '\(p)' is not permitted by the mount policy"
        case .illegalCharacter(_, let u): "illegal character U+\(String(u, radix: 16, uppercase: true))"
        case .tooManyArguments(let n, let l): "too many arguments: \(n) > \(l)"
        case .argumentTooLong(let n, let l): "argument too long: \(n) > \(l)"
        case .commandTooLong(let n, let l): "command too long: \(n) > \(l)"
        case .tooManyOperands(let n, let l): "too many operands: \(n) > \(l)"
        case .missingOperand(let s, let n): "\(s) needs at least \(n) operand(s)"
        case .separatorNotAllowed: "'--' is not accepted here"
        }
    }
}

// MARK: - Allowlist

public enum Allowlist {
    /// Structural limits applied before anything is parsed. A remote peer must not be
    /// able to make us spend time (or memory) on a pathological argv.
    public struct Limits: Sendable, Equatable {
        public var maxArgumentCount: Int
        public var maxArgumentLength: Int
        public var maxTotalLength: Int

        public init(maxArgumentCount: Int = 64, maxArgumentLength: Int = 1024, maxTotalLength: Int = 8192) {
            self.maxArgumentCount = maxArgumentCount
            self.maxArgumentLength = maxArgumentLength
            self.maxTotalLength = maxTotalLength
        }

        public static let `default` = Limits()
    }

    // MARK: The table

    /// Every subcommand Flotilla is allowed to run in Phase 1. Adding a capability
    /// means adding a row here — that is the point.
    ///
    /// Deliberately absent, with reasons:
    /// - `cp`, `export`, `push`, `registry login` — not Phase 1, and each is a
    ///   data-exfiltration or credential surface that deserves its own review. (`exec` and
    ///   `build` have since had theirs; see their rows.)
    /// - `logs --follow`, `stats` streaming — Phase 4 streaming transport; a bounded
    ///   fetch is all Phase 1 offers, so `-f` is not accepted.
    /// - `system start/stop`, `builder …` — fleet-wide destructive or privileged;
    ///   Phase 3+. (`prune`, unlike those, *is* Phase 1 scope — see the `prune` rows
    ///   below, one per resource kind, matching the real CLI's shape rather than a
    ///   single fleet-wide verb.)
    /// - `restart` — **not a real `container` subcommand**; `ContainerCLI.restart`
    ///   composes `stop` + `start`.
    public static let commands: [CommandSpec] = {
        let format = FlagSpec(long: "format", value: .outputFormat)
        let all = FlagSpec(long: "all", short: "a")
        let force = FlagSpec(long: "force", short: "f")
        let quiet = FlagSpec(long: "quiet", short: "q")

        return [
            // MARK: containers — read
            CommandSpec(["ls"], mutates: false, flags: [format, all, quiet]),
            CommandSpec(["list"], mutates: false, flags: [format, all, quiet]),
            CommandSpec(["inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            // Bare `stats` **streams** until killed (`--no-stream` "disable streaming stats and
            // only pull the first result"). One request occupying a process and a response buffer
            // indefinitely is a denial of service against the host peer, so the bounded form is
            // the only one offered over the wire. The app already always passes it.
            CommandSpec(["stats"], mutates: false,
                        flags: [format, FlagSpec(long: "no-stream")],
                        operands: OperandSpec(shape: .identifier, min: 0, max: 32),
                        wireRequiredFlags: ["no-stream"]),
            // `exec`, deliberately crippled to ONE command: the process list.
            //
            // Not `.command(maxTokens:)`. That would permit `exec <id> sh` — an interactive
            // shell inside the container — which is exactly the "generic remote shell" this
            // whole table exists to prevent (DECISIONS.md, transport). The UI needs a process
            // list and nothing else, so that is all this grants. `mutates: false` because a
            // `ps` changes nothing; the `--tty`/`--interactive` flags are absent on purpose.
            CommandSpec(["exec"], mutates: false, timeoutHint: 15,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1),
                        trailing: .exact(["ps", "-o", "pid,comm,args"])),

            // Reads and writes the host filesystem, so `mutates` is true and both operands
            // are `copyEndpoint`, whose host side must satisfy `MountPolicy`.
            CommandSpec(["copy"], mutates: true, timeoutHint: 120,
                        operands: OperandSpec(shape: .copyEndpoint, min: 2, max: 2)),

            // MARK: container machine
            //
            // Nine leaves, each captured individually from its OWN `--help` — see
            // `reference/cli-help/container-machine-1.0.0-help.txt`. Parent help was not
            // enough, and `research/VM-SECURITY-REVIEW.md` says so in as many words. The
            // calling conventions genuinely differ per leaf and assuming one across the family
            // is the `volume create --size` trap:
            //
            //   `delete`, `set-default`  operand REQUIRED
            //   `stop`, `inspect`, `logs`  operand OPTIONAL (defaults to the default machine)
            //   `run`, `set`             machine named via `-n`, not positionally
            //
            // A machine is the VM every container on this host runs inside, so these are not
            // ordinary additions — `machine delete` destroys that substrate. The review
            // requires `delete`, `run` and `set-default` to be flatly unreachable over the
            // Phase 2 wire and remote `home-mount` refused in both modes. Grammar cannot
            // express "who is asking", so those denials belong in the transport's policy tier;
            // what belongs HERE is that the shapes are exact and no unknown setting key can
            // pass. `mutates` is honest on every one of them.

            CommandSpec(["machine", "list"], mutates: false,
                        flags: [FlagSpec(long: "format", value: .machineOutputFormat),
                                FlagSpec(long: "quiet", short: "q")],
                        operands: .none),

            // Optional operand: bare `machine inspect` inspects the default machine.
            // Local-only on the review's finding. Its payload carries `userSetup.username` — the very
            // field the redaction lesson in CLAUDE.md exists for, which escaped into the machine
            // Inspect panel once already — plus the VM's address and home-mount state. There is no
            // response redaction on the wire yet, so this is fail-closed until there is; the
            // alternative is a promise with no code behind it.
            CommandSpec(["machine", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 0, max: 1),
                        exposure: .localOnly(reason: "it discloses the owner's account name, the VM address and home-mount state, and nothing redacts wire responses yet")),

            // Local-only on the review's finding, for two reasons that compound. It discloses the
            // owner's own data — VM topology, home-mount state, command lines — and `--follow`
            // *satisfies* `wireRequiredFlags: ["n"]` while still streaming indefinitely, so
            // `machine logs -n 1 --follow prod` defeated the bounded-output rule from inside it.
            // `wireRequiredFlags` stays declared: if this is ever exposed with redaction, the
            // bound is already stated rather than needing to be remembered.
            CommandSpec(["machine", "logs"], mutates: false,
                        flags: [FlagSpec(short: "n", value: .count),
                                FlagSpec(long: "boot"),
                                FlagSpec(long: "follow", short: "f")],
                        operands: OperandSpec(shape: .identifier, min: 0, max: 1),
                        exposure: .localOnly(reason: "it discloses VM topology and the owner's command lines, and --follow streams without bound"),
                        wireRequiredFlags: ["n"]),

            // Boots a VM and pulls an image, so `timeoutHint` is generous and `mutates` true.
            // `--cpus`, `--memory` and `--home-mount` are accepted inline here — confirmed
            // against the leaf help, which settles whether a follow-up `set` is required.
            CommandSpec(["machine", "create"], mutates: true, timeoutHint: 600,
                        flags: [FlagSpec(long: "name", short: "n", value: .identifier),
                                FlagSpec(long: "cpus", value: .count),
                                FlagSpec(long: "memory", value: .memorySize),
                                FlagSpec(long: "home-mount", value: .homeMountMode),
                                FlagSpec(long: "no-boot"),
                                FlagSpec(long: "set-default"),
                                FlagSpec(long: "arch", short: "a", value: .identifier),
                                FlagSpec(long: "os", value: .identifier),
                                FlagSpec(long: "platform", value: .platform)],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 1),
                        exposure: .localOnly(reason: "creating a VM chooses its image and can mount the owner's home directory")),

            // Settings are `.machineSetting`, a CLOSED set — an unknown key is refused rather
            // than forwarded on the hope the CLI will catch it.
            CommandSpec(["machine", "set"], mutates: true,
                        flags: [FlagSpec(long: "name", short: "n", value: .identifier)],
                        operands: OperandSpec(shape: .machineSetting, min: 1, max: 3),
                        exposure: .localOnly(reason: "it can point the default machine at the owner's home directory read-write")),

            // `machine run` was **missing entirely** while both `startMachine` and the
            // machine Shell tab used it — so Start and the shell were refused by our own
            // allowlist, and neither had ever worked. Found by a test written after the fact.
            //
            // Two grammars, exactly as `exec` has two. This is the default one, and it is
            // narrow on purpose: a shell inside the machine is arbitrary code execution on the
            // VM that every container on this host runs inside, which is strictly more
            // dangerous than a shell in one container. So by default the only thing permitted
            // is the boot no-op, and the interactive form requires `ExecPolicy.interactiveShell`
            // — a policy a `ContainerCLI` pointed at a remote peer does not carry.
            CommandSpec(["machine", "run"], mutates: true, timeoutHint: 300,
                        flags: [FlagSpec(long: "name", short: "n", value: .identifier)],
                        operands: OperandSpec(shape: .identifier, min: 0, max: 0),
                        trailing: .exact(["/bin/true"]),
                        exposure: .localOnly(reason: "it boots a VM and runs a command inside it")),

            CommandSpec(["machine", "stop"], mutates: true, timeoutHint: 120,
                        operands: OperandSpec(shape: .identifier, min: 0, max: 1),
                        exposure: .localOnly(reason: "it stops a VM the owner is using, by default whichever is current")),

            // Operand REQUIRED, unlike stop/inspect/logs. That asymmetry is the CLI's and it is
            // the right way round: `machine delete` with no argument would silently destroy the
            // default machine, so it must be named.
            CommandSpec(["machine", "delete"], mutates: true, timeoutHint: 120,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1),
                        exposure: .localOnly(reason: "it destroys a VM and its persistent state")),

            CommandSpec(["machine", "set-default"], mutates: true,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1),
                        exposure: .localOnly(reason: "it redirects every later bare machine operation, including the owner's")),

            // `-n` is *optional* to the CLI — "if not provided this will print all of the
            // logs", its own help — which is fine for the owner reading their own log and a
            // memory-and-wire hazard from a peer. Required over the wire only.
            CommandSpec(["logs"], mutates: false,
                        flags: [FlagSpec(short: "n", value: .count), FlagSpec(long: "boot")],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1),
                        wireRequiredFlags: ["n"]),

            // MARK: containers — mutate
            // Exactly one operand. Verified: `container start idle cache` is refused with
            // "Unexpected argument 'cache'" and the usage line is singular — unlike `stop`,
            // `rm` and `inspect`, which really are plural. Accepting 32 here let the allowlist
            // canonicalise a command the CLI would reject. (the independent audit, High.)
            CommandSpec(["start"], mutates: true, timeoutHint: 120,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),
            CommandSpec(["stop"], mutates: true, timeoutHint: 120,
                        flags: [all,
                                FlagSpec(long: "time", short: "t", value: .durationSeconds),
                                FlagSpec(long: "signal", short: "s", value: .signal)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            // `container kill` has no `--time` — it is the immediate counterpart to
            // `stop`, and its default signal is KILL rather than stop's TERM.
            CommandSpec(["kill"], mutates: true, timeoutHint: 30,
                        flags: [all, FlagSpec(long: "signal", short: "s", value: .signal)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["delete"], mutates: true, timeoutHint: 120,
                        flags: [force, all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["rm"], mutates: true, timeoutHint: 120,
                        flags: [force, all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            // Real `container prune` takes no operands and no flags beyond `--debug`
            // (which Flotilla does not expose) — it removes every stopped container.
            CommandSpec(["prune"], mutates: true, timeoutHint: 120),
            CommandSpec(["run"], mutates: true, timeoutHint: 600,
                        flags: [FlagSpec(long: "detach", short: "d"),
                                FlagSpec(long: "rm"),
                                FlagSpec(long: "name", value: .identifier),
                                FlagSpec(long: "env", short: "e", value: .envAssignment,
                                         repeatable: true, maxRepeats: 24),
                                FlagSpec(long: "publish", short: "p", value: .portMapping,
                                         repeatable: true, maxRepeats: 16),
                                FlagSpec(long: "volume", short: "v", value: .mountSpec,
                                         repeatable: true, maxRepeats: 16),
                                FlagSpec(long: "cpus", short: "c", value: .count),
                                FlagSpec(long: "memory", short: "m", value: .memorySize),
                                FlagSpec(long: "network", value: .identifier),
                                FlagSpec(long: "platform", value: .platform)],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 1),
                        trailing: .command(maxTokens: 24)),

            // MARK: images
            CommandSpec(["image", "list"], mutates: false, flags: [format, quiet]),
            CommandSpec(["image", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 32)),
            CommandSpec(["image", "pull"], mutates: true, timeoutHint: 1800,
                        flags: [FlagSpec(long: "platform", value: .platform)],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 1)),
            CommandSpec(["image", "delete"], mutates: true,
                        flags: [all, force],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["image", "rm"], mutates: true,
                        flags: [all, force],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["image", "prune"], mutates: true, timeoutHint: 120, flags: [all]),
            CommandSpec(["image", "tag"], mutates: true,
                        operands: OperandSpec(shape: .imageReference, min: 2, max: 2)),

            // MARK: build
            //
            // The most dangerous grammar in the table, and the reason is not the verb but its
            // arguments: three of `build`'s flags reach the host filesystem and environment.
            // In Phase 2 this same grammar faces a REMOTE caller, so what is refused here
            // matters more than what is accepted.
            //
            // Refused outright — no spec, so they fail as unknown flags, and there is a test
            // per flag pinning that:
            //   `--secret`      reads host env vars and host files (`env=`/`src=`). An
            //                   exfiltration primitive the moment a remote peer can name it,
            //                   and one that would launder the value into an image layer.
            //   `--output`      `type=local,dest=<path>` writes an arbitrary host path. The
            //                   default `type=oci` is what we want anyway, so the flag buys
            //                   nothing and costs a lot.
            //   `--vsock-port`  internal builder plumbing; not a caller's choice.
            //   `--dns`, `--dns-domain`, `--dns-option`, `--dns-search`
            //                   deferred — no use case yet, and the table is default-deny, so
            //                   "no use case" means "not listed".
            //
            // `--file` and the context directory are `.hostBuildPath`, so both cross
            // `MountPolicy` exactly as `copy`'s host end does. The context is a whole
            // directory TREE, which is a broader read grant than `copy`'s single file — under
            // `.denyHostPaths` a build naming an explicit path is refused entirely.
            //
            // The operand is optional because the CLI defaults it to `.`; there is no way to
            // spell a *relative* context through this shape, which is deliberate — a relative
            // path cannot be checked against a policy expressed in absolute roots.
            CommandSpec(["build"], mutates: true, timeoutHint: 1800,
                        flags: [FlagSpec(long: "file", short: "f", value: .hostBuildPath),
                                FlagSpec(long: "tag", short: "t", value: .imageReference),
                                FlagSpec(long: "build-arg", value: .envAssignment,
                                         repeatable: true, maxRepeats: 24),
                                FlagSpec(long: "label", short: "l", value: .keyValue,
                                         repeatable: true, maxRepeats: 8),
                                FlagSpec(long: "no-cache"),
                                FlagSpec(long: "pull"),
                                FlagSpec(long: "quiet", short: "q"),
                                FlagSpec(long: "platform", value: .platform),
                                FlagSpec(long: "os", value: .identifier),
                                FlagSpec(long: "arch", short: "a", value: .identifier),
                                FlagSpec(long: "cpus", short: "c", value: .count),
                                FlagSpec(long: "memory", short: "m", value: .memorySize),
                                FlagSpec(long: "target", value: .identifier),
                                FlagSpec(long: "progress", value: .progressType)],
                        // `min: 1`, **not** `min: 0`, even though the CLI defaults the context
                        // to `.`. An absent operand is not "no host path" here — it is an
                        // *implicit* one, the process working directory, and the validator only
                        // shape-checks operands that exist, so `MountPolicy` never saw it. Under
                        // `.denyHostPaths` a build would still have archived whatever directory
                        // the process happened to be in; on the Phase 2 host peer that directory
                        // is an execution detail the remote caller does not choose and the policy
                        // does not authorise. Appending `.` ourselves would not help, because a
                        // relative path cannot be checked against absolute policy roots.
                        // Found in review, 9 August. The original `min: 0` was reasoning about CLI
                        // convenience at a security boundary.
                        operands: OperandSpec(shape: .hostBuildPath, min: 1, max: 1)),

            // MARK: volumes
            CommandSpec(["volume", "list"], mutates: false, flags: [format, quiet]),
            CommandSpec(["volume", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            // `-s` has **no long form**. `container volume create --size 64M` is rejected
            // outright (verified against the CLI); only `-s` is accepted. Declaring `long:
            // "size"` here was therefore a latent bug: `canonicalSpelling` prefers the long
            // spelling, so every sized volume Flotilla created would have emitted `--size`
            // and failed. Short-only is deliberate — do not "tidy" a long name back in.
            CommandSpec(["volume", "create"], mutates: true,
                        flags: [FlagSpec(short: "s", value: .memorySize),
                                FlagSpec(long: "opt", value: .keyValue, repeatable: true, maxRepeats: 8),
                                FlagSpec(long: "label", value: .keyValue, repeatable: true, maxRepeats: 8)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),
            CommandSpec(["volume", "delete"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["volume", "rm"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["volume", "prune"], mutates: true, timeoutHint: 120),

            // MARK: networks
            CommandSpec(["network", "list"], mutates: false, flags: [format, quiet]),
            CommandSpec(["network", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            // `--subnet-v6` and `--plugin` were missing here — found by the CLI study and
            // confirmed against `container network create --help`. A network's addressing can
            // only be set at creation, so an unreachable flag is a permanently unreachable
            // choice.
            CommandSpec(["network", "create"], mutates: true, timeoutHint: 60,
                        flags: [FlagSpec(long: "internal"),
                                FlagSpec(long: "subnet", value: .cidr),
                                FlagSpec(long: "subnet-v6", value: .cidrV6),
                                FlagSpec(long: "plugin", value: .identifier),
                                FlagSpec(long: "label", value: .keyValue, repeatable: true, maxRepeats: 8),
                                FlagSpec(long: "option", value: .keyValue, repeatable: true, maxRepeats: 8)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),
            CommandSpec(["network", "delete"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["network", "rm"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["network", "prune"], mutates: true, timeoutHint: 120),

            // MARK: system — read only
            CommandSpec(["system", "status"], mutates: false, flags: [format]),
            CommandSpec(["system", "version"], mutates: false, flags: [format]),
            CommandSpec(["system", "df"], mutates: false, flags: [format]),

            // MARK: system — the one mutation
            //
            // `--disable-kernel-install` is not optional decoration. Captured help:
            // `--enable-kernel-install/--disable-kernel-install  … (default: prompt user)`.
            // A GUI-launched process has no terminal to answer that prompt on, so an
            // unqualified `system start` on a machine without the kernel would hang until it
            // timed out with nothing on screen explaining why. `--enable-kernel-install` is
            // deliberately **absent**: installing a kernel is exactly the privileged,
            // user-authorised step `DECISIONS.md` says Flotilla never takes on its own.
            //
            // `--app-root`, `--install-root` and `--log-root` are absent for the same reason
            // build's path flags are constrained: they are host paths, and default-deny means
            // an unlisted flag is refused without anyone having to remember to refuse it.
            CommandSpec(["system", "start"], mutates: true, timeoutHint: 120,
                        flags: [FlagSpec(long: "disable-kernel-install"),
                                FlagSpec(long: "timeout", value: .count)],
                        exposure: .localOnly(reason: "starting the host's own runtime services is the owner's decision")),
        ]
    }()

    private static let index: [String: CommandSpec] =
        Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })

    /// The spec for a subcommand path, e.g. `spec(for: ["image", "pull"])`.
    public static func spec(for path: [String]) -> CommandSpec? { index[path.joined(separator: " ")] }

    /// Swaps in the permissive `exec` grammar when — and only when — the caller asked for it.
    ///
    /// A substitution rather than a mutable table: the strict spec stays the one in
    /// `commands`, so anything that inspects the allowlist (the audit, the Phase 2 wire
    /// documentation) still reports the default posture, and a caller has to hold an
    /// `ExecPolicy.interactiveShell` to get anything else.
    private static func refuseUnexposed(_ spec: CommandSpec, wirePolicy: WirePolicy) throws {
        guard wirePolicy == .remotePeer, case .localOnly(let reason) = spec.exposure else { return }
        throw AllowlistError.notExposedToWire(command: spec.name, reason: reason)
    }

    private static func substituting(_ policy: ExecPolicy, into spec: CommandSpec,
                                     args: [String]) -> CommandSpec {
        guard policy == .interactiveShell else { return spec }
        switch spec.path {
        case ["exec"]: return interactiveExec

        case ["machine", "run"]:
            // `machine run` has **two** legitimate shapes and the substitution used to destroy
            // one of them. `interactiveMachineRun` forbids a trailing command, because it
            // exists for the no-command login shell the Shell tab attaches a PTY to. Swapping
            // it in unconditionally meant `startMachine`'s boot form —
            // `machine run --name X -- /bin/true` — was refused with "'--' is not accepted
            // here" for any caller holding `.interactiveShell`.
            //
            // Which is every caller that matters: `AppModel` builds its CLI with
            // `.interactiveShell`. So machine Start and Restart could not work in the app at
            // all, while both were green in the tests — because the tests validated under the
            // *default* policy. A grammar test that does not use production's policy is
            // testing a configuration nothing ships.
            //
            // A `--` means "I am passing a command", so keep the strict boot spec for that and
            // use the interactive one only for the bare shell. Two shapes, neither widened.
            return args.dropFirst(spec.path.count).contains("--") ? spec : interactiveMachineRun

        default: return spec
        }
    }

    /// `container machine run [-n <id>] [-i] [-t]` with **no command** — the login shell the
    /// Shell tab attaches a PTY to.
    ///
    /// No trailing tokens at all, which is stricter than `interactiveExec`: the tab exists to
    /// open a login shell, and the boot no-op is already covered by the default spec. There is
    /// therefore no form of this that carries caller-supplied argv into the VM.
    private static let interactiveMachineRun = CommandSpec(
        ["machine", "run"], mutates: true, timeoutHint: 0,
        flags: [FlagSpec(long: "name", short: "n", value: .identifier),
                FlagSpec(long: "interactive", short: "i"), FlagSpec(long: "tty", short: "t")],
        operands: OperandSpec(shape: .identifier, min: 0, max: 0),
        trailing: .forbidden,
        // Belt and braces with the pre-substitution check: a login shell in the substrate VM is
        // the single most dangerous thing in this table.
        exposure: .localOnly(reason: "it opens a login shell inside the substrate VM"))

    /// `container exec [-i] [-t] <id> <command…>`.
    ///
    /// `mutates: true` — a shell can do anything the container's user can, so nothing about
    /// this is a read. The token cap is deliberately small: this exists to launch a shell,
    /// not to smuggle a script in as argv.
    private static let interactiveExec = CommandSpec(
        ["exec"], mutates: true, timeoutHint: 0,
        flags: [FlagSpec(long: "interactive", short: "i"), FlagSpec(long: "tty", short: "t")],
        operands: OperandSpec(shape: .identifier, min: 1, max: 1),
        trailing: .command(maxTokens: 8),
        // `ExecPolicy` is what selects this grammar, and a remote-serving CLI is not supposed to
        // carry `.interactiveShell` — but "not supposed to" is a convention, and this is a shell
        // in a container. Marked local-only so the capability, not the convention, refuses it.
        exposure: .localOnly(reason: "it carries caller-supplied argv into a container"))

    // MARK: Entry points

    /// Validate an argv. **Default deny**: anything not described by the table above
    /// is an error.
    ///
    /// `mountPolicy` bounds which host paths a bind mount may expose and defaults to
    /// `.denyHostPaths` — command grammar alone does not make `--volume /Users:/host`
    /// safe. A caller driving its *own* machine may pass `.unrestricted`; a host
    /// serving a remote peer must pass its own `.roots(…)` policy and never one the
    /// client supplied. See `MountPolicy`.
    public static func validate(_ args: [String],
                                limits: Limits = .default,
                                mountPolicy: MountPolicy = .denyHostPaths,
                                execPolicy: ExecPolicy = .processListOnly,
                                wirePolicy: WirePolicy = .localOwner) -> Result<ValidatedCommand, AllowlistError> {
        do { return .success(try validated(args, limits: limits, mountPolicy: mountPolicy,
                                           execPolicy: execPolicy, wirePolicy: wirePolicy)) }
        catch let error as AllowlistError { return .failure(error) }
        catch { return .failure(.emptyCommand) } // unreachable: nothing else is thrown
    }

    /// Throwing form, for call sites that already propagate errors (`ContainerCLI`).
    /// - Parameter wirePolicy: defaults to `.localOwner`, which is the only caller that exists
    ///   today. The default is deliberately the permissive one **because there is no wire yet**:
    ///   flipping it would refuse the app's own machine controls with no peer to protect. Phase 2's
    ///   host peer must construct its `ContainerCLI` with `.remotePeer`, and `research/
    ///   ALLOWLIST-AUDIT.md` records that as a launch requirement rather than a nicety.
    public static func validated(_ args: [String],
                                 limits: Limits = .default,
                                 mountPolicy: MountPolicy = .denyHostPaths,
                                 execPolicy: ExecPolicy = .processListOnly,
                                 wirePolicy: WirePolicy = .localOwner) throws -> ValidatedCommand {
        guard !args.isEmpty else { throw AllowlistError.emptyCommand }
        try screen(args, limits: limits)

        let resolved = try resolve(args)

        // **Checked on the RESOLVED spec, before substitution, and again after it.**
        //
        // The review found the bypass this closes (2026-08-19, BLOCKER): `substituting()` swaps
        // `machine run` for `interactiveMachineRun` under `ExecPolicy.interactiveShell`, and that
        // substitute is a separate `CommandSpec` — so it carried the *default* exposure and
        // laundered the local-only marking on the spec it replaced. `machine run -n prod -i -t`
        // from a `.remotePeer` holding `.interactiveShell` would have granted a shell inside the
        // substrate VM. Checking the pre-substitution spec makes exposure impossible to launder
        // no matter what any future substitute declares; the substitutes are *also* marked
        // local-only, because one guard that depends on remembering a second is not a guard.
        //
        // Before any argument is examined, too: exposure is a property of the operation, not of
        // its arguments, and every blocker it closes was a *well-formed* command.
        try refuseUnexposed(resolved, wirePolicy: wirePolicy)

        let spec = try substituting(execPolicy, into: resolved, args: args)
        try refuseUnexposed(spec, wirePolicy: wirePolicy)

        let rest = Array(args.dropFirst(spec.path.count))

        // Parsed pieces, kept in encounter order so the canonical argv is stable.
        var flagTokens: [String] = []
        var seenFlags: [String: Int] = [:]
        var presentLongFlags: Set<String> = []
        var operands: [String] = []
        var trailing: [String] = []
        var afterSeparator = false

        var i = 0
        while i < rest.count {
            let token = rest[i]
            i += 1

            if afterSeparator {
                trailing.append(token)
                continue
            }

            if token == "--" {
                // `.exact` carries an in-container command too, so it needs the separator
                // just as `.command` does — without this the one invocation the spec
                // permits is unreachable.
                switch spec.trailing {
                case .command, .exact: break
                case .forbidden: throw AllowlistError.separatorNotAllowed
                }
                afterSeparator = true
                continue
            }

            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                guard !body.isEmpty else { throw AllowlistError.malformedFlag(token) }
                let (name, inlineValue) = splitInlineValue(body)
                guard let flag = spec.flag(long: name) else { throw AllowlistError.unknownFlag("--\(name)") }
                try record(flag, spelling: "--\(name)", inlineValue: inlineValue,
                           rest: rest, cursor: &i, tokens: &flagTokens, counts: &seenFlags,
                           mountPolicy: mountPolicy)
                presentLongFlags.insert(name)
                continue
            }

            if token.hasPrefix("-"), token != "-" {
                // Only the exact `-x` form is accepted. Combined shorts (`-it`),
                // attached values (`-n5`) and `-n=5` are all rejected rather than
                // guessed at — ambiguity is not something a security boundary should
                // resolve on the sender's behalf.
                let body = token.dropFirst()
                guard body.count == 1, let short = body.first else { throw AllowlistError.malformedFlag(token) }
                guard let flag = spec.flag(short: short) else { throw AllowlistError.unknownFlag(token) }
                try record(flag, spelling: token, inlineValue: nil,
                           rest: rest, cursor: &i, tokens: &flagTokens, counts: &seenFlags, mountPolicy: mountPolicy)
                // Short-only flags are recorded under their letter. Without this a flag with no
                // long spelling — `logs -n` is the only one — was invisible to every check that
                // reads this set, which would have made `wireRequiredFlags: ["n"]` impossible to
                // satisfy: a remote caller passing `-n 100` would still have been refused.
                presentLongFlags.insert(flag.long ?? String(short))
                continue
            }

            // A bare token: an operand while there is room, otherwise the start of the
            // in-container command (`container run alpine echo hi`).
            if operands.count < spec.operands.max {
                operands.append(token)
            } else if case .command = spec.trailing {
                trailing.append(token)
                afterSeparator = true
            } else {
                throw AllowlistError.tooManyOperands(count: operands.count + 1, limit: spec.operands.max)
            }
        }

        // Operand arity.
        // Bounded-output flags, checked once the flags are known. A remote caller that omits
        // `-n` on `logs` is asking the host peer to read an entire log into memory and put it on
        // the wire; the local owner doing the same is just reading their own log.
        if wirePolicy == .remotePeer {
            for required in spec.wireRequiredFlags where !presentLongFlags.contains(required) {
                throw AllowlistError.flagRequiredOverWire(command: spec.name, flag: required)
            }
        }

        let minRequired = presentLongFlags.isDisjoint(with: spec.operands.minWaivedBy) ? spec.operands.min : 0
        guard operands.count >= minRequired else {
            throw AllowlistError.missingOperand(subcommand: spec.name, need: minRequired)
        }
        for operand in operands {
            if let error = check(operand, as: spec.operands.shape, context: "<\(spec.operands.shape.rawValue)>",
                                 mountPolicy: mountPolicy) {
                throw error
            }
        }

        // Trailing in-container command.
        if case .command(let maxTokens) = spec.trailing {
            guard trailing.count <= maxTokens else {
                throw AllowlistError.tooManyArguments(count: trailing.count, limit: maxTokens)
            }
            for token in trailing {
                if let error = check(token, as: .commandToken, context: "command", mountPolicy: mountPolicy) { throw error }
            }
        } else if case .exact(let permitted) = spec.trailing {
            // All-or-nothing, compared element-wise with `.literal` so no Unicode
            // equivalence can smuggle a different command past a visual match — the same
            // reasoning as the operand checks.
            guard trailing.count == permitted.count,
                  zip(trailing, permitted).allSatisfy({ $0.compare($1, options: .literal) == .orderedSame })
            else {
                // Reported as an invalid value rather than a count problem: the objection is
                // *what* was asked for, not how much of it.
                throw AllowlistError.invalidValue(
                    context: "command",
                    value: trailing.joined(separator: " "),
                    shape: .commandToken
                )
            }
        } else if !trailing.isEmpty {
            throw AllowlistError.tooManyOperands(count: operands.count + trailing.count, limit: spec.operands.max)
        }

        // Canonical argv: subcommand, flags, operands, then the in-container command.
        //
        // `run` needs an explicit `--` before that command, or a token like `--rm` gets
        // re-parsed as a flag *of `container run`* by the CLI.
        //
        // `exec` is the opposite: it has no separator at all. `container exec web -- ps`
        // fails with "failed to find target executable --" — it takes `--` as the program
        // name. Verified against the live CLI; the unit tests passed either way, so this was
        // only caught by running it. The input grammar still requires the separator so
        // parsing stays unambiguous, but it is dropped from the argv we actually execute.
        var argv = spec.path + flagTokens + operands
        if !trailing.isEmpty {
            // Keyed on the SUBCOMMAND, not just the trailing policy. `exec` never takes a
            // separator regardless of how its trailing is specified — which matters now that
            // `interactiveExec` uses `.command`, the very case that appends one. Getting this
            // wrong produces "failed to find target executable --" at runtime and passes
            // every unit test, which is how it was missed the first time.
            if case .command = spec.trailing, spec.path != ["exec"] { argv.append("--") }
            argv.append(contentsOf: trailing)
        }

        return ValidatedCommand(subcommand: spec.path,
                                arguments: argv,
                                mutates: spec.mutates,
                                timeoutHint: spec.timeoutHint,
                                auditDescription: redact(argv, against: spec))
    }

    // MARK: Audit redaction

    /// Builds the audit string: **flag and operand *names* survive, free-form *values* do not.**
    ///
    /// SEC-03 in the 2026-08-20 audit: `auditDescription` joined the whole canonical argv, so a
    /// record of `container run --env DATABASE_PASSWORD=… ` carried the password into whatever read
    /// it. The fix has to be structural, not a pattern match on likely-secret-looking text — a
    /// denylist of key names is a guess, and the one that gets missed is the one that mattered.
    ///
    /// It is structural because it walks the **canonical** argv against the **spec**: the argv is
    /// already normalised to `subcommand, flags, operands, [--], trailing`, and the spec says which
    /// flags take values and what shape each value is. So a value is identified by its position in
    /// a grammar, not by how it looks.
    ///
    /// What survives, and why it must: the subcommand, every flag name, and values whose shape is
    /// a **closed set or a resource name** — `identifier`, `imageReference`, `machineSetting`,
    /// `homeMountMode`, `signal`, `platform`, `cidr`, counts and formats. An audit line reading
    /// `machine set home-mount=<machineSetting> prod` would be worthless: *which* setting was
    /// changed is the entire security interest of that command.
    ///
    /// What does not survive: `envAssignment` and `keyValue` (arbitrary data, the SEC-03 case), the
    /// four host-path shapes (`mountSpec`, `absolutePath`, `copyEndpoint`, `hostBuildPath` — these
    /// carry the account name and often the point of the operation), and the entire trailing
    /// in-container command, which is free text and can hold a credential in a `curl` header.
    ///
    /// **The cost, stated plainly:** an audit line no longer says *which* path was mounted, only
    /// that a mount was requested. That is a real loss for the most security-relevant flag on the
    /// list. It is accepted because `MountPolicy` is what actually decides a path, and that
    /// decision — not this string — is the auditable event; a Phase 2 peer that needs path-level
    /// records must carry them in a channel with handling to match, rather than in a description
    /// that ends up in log files and alerts.
    static func redact(_ argv: [String], against spec: CommandSpec) -> String {
        var out: [String] = ["container"]
        var index = 0
        var operandsSeen = 0
        var inTrailing = false
        var trailingCount = 0

        // The subcommand path, verbatim.
        while index < argv.count, index < spec.path.count {
            out.append(argv[index])
            index += 1
        }

        while index < argv.count {
            let token = argv[index]

            if inTrailing {
                trailingCount += 1
                index += 1
                continue
            }

            if token == "--" {
                out.append("--")
                inTrailing = true
                index += 1
                continue
            }

            if token.hasPrefix("-"), token != "-" {
                let flag: FlagSpec? = token.hasPrefix("--")
                    ? spec.flag(long: String(token.dropFirst(2)))
                    : token.dropFirst().first.flatMap { spec.flag(short: $0) }
                // Fail closed. A token shaped like a flag that the spec does not know cannot
                // happen for a canonical argv, so if it ever does, something is wrong upstream and
                // this is not the place to guess which token is a value.
                guard let flag else {
                    out.append("<flag>")
                    index += 1
                    continue
                }
                out.append(token)
                index += 1
                if let shape = flag.value, index < argv.count {
                    out.append(render(argv[index], as: shape))
                    index += 1
                }
                continue
            }

            // A bare token: an operand while the spec has room, otherwise the start of the
            // in-container command for the subcommands that take one without a separator.
            if operandsSeen < spec.operands.max {
                out.append(render(token, as: spec.operands.shape))
                operandsSeen += 1
            } else {
                inTrailing = true
                trailingCount += 1
            }
            index += 1
        }

        if trailingCount > 0 {
            // Counted, not quoted. The count is the useful part — "it ran a 9-token command in
            // there" — and every token of it is free text.
            out.append("<command: \(trailingCount) token\(trailingCount == 1 ? "" : "s")>")
        }
        return out.joined(separator: " ")
    }

    /// A single value: itself when its shape is a name or a closed set, its shape otherwise.
    private static func render(_ value: String, as shape: ValueShape) -> String {
        shape.carriesFreeFormData ? "<\(shape.rawValue)>" : value
    }

    // MARK: Parsing helpers

    /// Structural + character screening, before any interpretation.
    private static func screen(_ args: [String], limits: Limits) throws {
        guard args.count <= limits.maxArgumentCount else {
            throw AllowlistError.tooManyArguments(count: args.count, limit: limits.maxArgumentCount)
        }
        var total = 0
        for arg in args {
            let length = arg.utf8.count
            guard length <= limits.maxArgumentLength else {
                throw AllowlistError.argumentTooLong(length: length, limit: limits.maxArgumentLength)
            }
            total += length
            guard total <= limits.maxTotalLength else {
                throw AllowlistError.commandTooLong(length: total, limit: limits.maxTotalLength)
            }
            // Control and format characters are rejected everywhere, in every shape.
            // That covers NUL, newline smuggling into logs, and the invisible
            // bidi/zero-width characters used to disguise one string as another.
            for scalar in arg.unicodeScalars {
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                    throw AllowlistError.illegalCharacter(argument: arg, scalar: scalar.value)
                default: continue
                }
            }
        }
    }

    /// Longest match first, so `image pull` wins over a hypothetical `image`.
    private static func resolve(_ args: [String]) throws -> CommandSpec {
        if args.count >= 2, !args[1].hasPrefix("-"), let two = spec(for: [args[0], args[1]]) { return two }
        if let one = spec(for: [args[0]]) { return one }
        // Report both levels so "image push" doesn't look like "image is unknown".
        if args.count >= 2, !args[1].hasPrefix("-"), index.keys.contains(where: { $0.hasPrefix(args[0] + " ") }) {
            throw AllowlistError.unknownSubcommand("\(args[0]) \(args[1])")
        }
        throw AllowlistError.unknownSubcommand(args[0])
    }

    /// `--name=value` → (`name`, `value`); `--name` → (`name`, nil).
    private static func splitInlineValue(_ body: String) -> (String, String?) {
        guard let equals = body.firstIndex(of: "=") else { return (body, nil) }
        return (String(body[body.startIndex..<equals]), String(body[body.index(after: equals)...]))
    }

    /// Validate one flag occurrence and append its canonical form to `tokens`.
    private static func record(_ flag: FlagSpec,
                               spelling: String,
                               inlineValue: String?,
                               rest: [String],
                               cursor: inout Int,
                               tokens: inout [String],
                               counts: inout [String: Int],
                               mountPolicy: MountPolicy) throws {
        let key = flag.canonicalSpelling
        let seen = (counts[key] ?? 0) + 1
        counts[key] = seen
        guard seen <= flag.maxRepeats else { throw AllowlistError.repeatedFlag(key) }

        guard let shape = flag.value else {
            guard inlineValue == nil else { throw AllowlistError.flagTakesNoValue(spelling) }
            tokens.append(key)
            return
        }

        let value: String
        if let inline = inlineValue {
            value = inline
        } else {
            guard cursor < rest.count else { throw AllowlistError.flagRequiresValue(spelling) }
            value = rest[cursor]
            cursor += 1
        }
        if let error = check(value, as: shape, context: key, mountPolicy: mountPolicy) { throw error }
        tokens.append(key)
        tokens.append(value)
    }

    // MARK: Shape validation

    private static func check(_ value: String, as shape: ValueShape, context: String,
                              mountPolicy: MountPolicy) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: shape)
        switch shape {
        case .identifier:
            return isIdentifier(value) ? nil : bad
        case .imageReference:
            return checkImageReference(value, context: context) ?? nil
        case .portMapping:
            return isPortMapping(value) ? nil : bad
        case .envAssignment:
            return isEnvAssignment(value) ? nil : bad
        case .mountSpec:
            return checkMountSpec(value, context: context, mountPolicy: mountPolicy)
        case .absolutePath:
            return checkAbsolutePath(value, context: context)
        case .copyEndpoint:
            return checkCopyEndpoint(value, context: context, mountPolicy: mountPolicy)
        case .hostBuildPath:
            return checkHostBuildPath(value, context: context, mountPolicy: mountPolicy)
        case .progressType:
            return ["auto", "plain", "tty"].contains(value) ? nil : bad
        case .machineSetting:
            return checkMachineSetting(value, context: context)
        case .homeMountMode:
            return ["ro", "rw", "none"].contains(value) ? nil : bad
        case .durationSeconds:
            return isInteger(value, in: 0...86_400) ? nil : bad
        case .count:
            return isInteger(value, in: 1...1024) ? nil : bad
        case .signal:
            return isSignal(value) ? nil : bad
        case .memorySize:
            return isMemorySize(value) ? nil : bad
        case .platform:
            return isPlatform(value) ? nil : bad
        case .cidr:
            return isCIDR(value) ? nil : bad
        case .cidrV6:
            return isCIDRV6(value) ? nil : bad
        case .keyValue:
            return isKeyValue(value) ? nil : bad
        case .outputFormat:
            return ["json", "table", "yaml", "toml"].contains(value) ? nil : bad
        case .machineOutputFormat:
            return ["json", "table"].contains(value) ? nil : bad
        case .commandToken:
            // Control characters were already rejected for every argument in `screen`.
            return (1...1024).contains(value.utf8.count) ? nil : bad
        }
    }

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    static func isIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.count), let first = value.first, isASCIIAlphanumeric(first) else { return false }
        return value.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private static func checkImageReference(_ value: String, context: String) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .imageReference)
        guard (1...512).contains(value.count), let first = value.first, isASCIIAlphanumeric(first) else { return bad }
        let allowed: Set<Character> = ["_", ".", "-", "/", ":", "@"]
        guard value.allSatisfy({ isASCIIAlphanumeric($0) || allowed.contains($0) }) else { return bad }

        // `..` as a path component is traversal, not a tag; report it as such.
        let pathPart = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        for component in pathPart.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { return bad }                       // no `//`
            if component == "." || component == ".." {
                return .pathTraversal(context: context, value: value)
            }
        }
        // The final path component may carry `:tag`; if it has a colon at all, the
        // tag after it must be non-empty (`alpine:` is not a valid reference).
        if let lastComponent = pathPart.split(separator: "/", omittingEmptySubsequences: false).last,
           let colon = lastComponent.lastIndex(of: ":"), colon == lastComponent.index(before: lastComponent.endIndex) {
            return bad
        }
        // At most one digest, and it must be a real one.
        let digestParts = value.split(separator: "@", omittingEmptySubsequences: false)
        if digestParts.count > 2 { return bad }
        if digestParts.count == 2 {
            let digest = digestParts[1]
            guard digest.hasPrefix("sha256:") else { return bad }
            let hex = digest.dropFirst("sha256:".count)
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return bad }
        }
        return nil
    }

    private static func isPort(_ value: Substring) -> Bool {
        guard (1...5).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(value) else { return false }
        return (1...65_535).contains(port)
    }

    private static func isPortMapping(_ value: String) -> Bool {
        var body = Substring(value)
        // Optional `/tcp` or `/udp`.
        if let slash = body.lastIndex(of: "/") {
            let proto = body[body.index(after: slash)...]
            guard proto == "tcp" || proto == "udp" else { return false }
            body = body[body.startIndex..<slash]
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        // A bare port is NOT valid. The CLI's grammar is `[host-ip:]host-port:container-port`,
        // and it refuses a single part outright: `-p 9998` fails with
        // `invalid publish value: 9998` (verified). Accepting it here made this shape looser
        // than the CLI's, which is the one direction that matters — a too-loose shape lets
        // invalid input cross the boundary to be rejected less clearly downstream, and in
        // Phase 2 that boundary faces a remote caller. (the independent audit, High.)
        case 2: return isPort(parts[0]) && isPort(parts[1])
        case 3: return isIPv4(String(parts[0])) && isPort(parts[1]) && isPort(parts[2])
        default: return false
        }
    }

    private static func isEnvAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "=") else { return false }
        let key = value[value.startIndex..<equals]
        guard (1...128).contains(key.count), let first = key.first,
              (first.isASCII && first.isLetter) || first == "_" else { return false }
        guard key.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "_" }) else { return false }
        return value[value.index(after: equals)...].utf8.count <= 768
    }

    /// One `container machine set` / `machine create` setting.
    ///
    /// **Enumerated, never generic.** `research/VM-SECURITY-REVIEW.md` is explicit: model the
    /// reviewed keys as typed operations and reject unknown ones, because "unknown future keys
    /// could silently add privilege" — a key this build has never heard of must not be forwarded
    /// on the assumption the CLI will sanity-check it.
    ///
    /// The three keys and their domains are the CLI's own, captured verbatim in
    /// `reference/cli-help/container-machine-1.0.0-help.txt`:
    /// `cpus=<number>`, `memory=<size>`, `home-mount=<ro|rw|none>`.
    ///
    /// `home-mount` is **not** validated against `MountPolicy` here and that is deliberate: it
    /// names a mode, not a path — there is no path to check, because the path is always the
    /// user's own home. The decision that matters for it is *authorisation*, not grammar, and
    /// per the review it must be refused outright for remote callers. Grammar cannot express
    /// "who is asking", so that gate belongs with `ExecPolicy`-style policy, not here.
    private static func checkMachineSetting(_ value: String, context: String) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .machineSetting)
        guard let equals = value.firstIndex(of: "=") else { return bad }
        let key = String(value[value.startIndex..<equals])
        let setting = String(value[value.index(after: equals)...])
        guard !setting.isEmpty else { return bad }

        switch key {
        case "cpus":
            // Same ceiling as `--cpus` elsewhere. A machine with 10,000 vCPUs is a typo or an
            // attack, and either way the VM will not boot.
            return isInteger(setting, in: 1...1024) ? nil : bad
        case "memory":
            return isMemorySize(setting) ? nil : bad
        case "home-mount":
            return ["ro", "rw", "none"].contains(setting) ? nil : bad
        default:
            // Unknown key. Refused, not forwarded.
            return bad
        }
    }

    /// One end of a `container copy`.
    ///
    /// **The host side crosses `MountPolicy`, and that is the whole reason this shape exists.**
    /// `copy` reads and writes the real filesystem: `container copy web:/etc/passwd /tmp/x`
    /// pulls a file out, and the reverse direction writes one in. Grammar alone does not make
    /// that safe — a well-formed path is exactly how you would overwrite something. So the
    /// host end is checked against the same policy that governs bind mounts, which defaults to
    /// permitting nothing.
    ///
    /// The container end is not policy-checked, deliberately: paths inside a container are the
    /// container's own filesystem, which the caller may already read with `exec`.
    private static func checkCopyEndpoint(_ value: String, context: String,
                                          mountPolicy: MountPolicy) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .copyEndpoint)
        guard !value.isEmpty else { return bad }

        // A host path. `/` is refused outright — copying to or from the filesystem root is
        // never what was meant and is catastrophic if it is.
        if value.hasPrefix("/") {
            if let error = checkAbsolutePath(value, context: context) { return error }
            guard value != "/" else { return bad }
            guard mountPolicy.allowsHostPath(value) else {
                return .hostPathNotPermitted(context: context, path: value)
            }
            return nil
        }

        // Otherwise `identifier:/path`. Split once: a container path may itself contain a
        // colon, and splitting on all of them would reject legitimate names.
        guard let separator = value.firstIndex(of: ":") else { return bad }
        let name = String(value[value.startIndex..<separator])
        let path = String(value[value.index(after: separator)...])
        guard isIdentifier(name), !path.isEmpty else { return bad }
        return checkAbsolutePath(path, context: context)
    }

    /// A host path a `container build` reads — the context directory, or `--file`.
    ///
    /// The same shape as `checkCopyEndpoint`'s host branch, and for the same reason: the value
    /// being well-formed says nothing about whether this caller may read it. What differs is
    /// the *breadth* of the grant. `copy` names one file; a build context is a directory tree
    /// that is archived wholesale and handed to the builder, so `/Users` as a context is every
    /// SSH key on the machine. So it crosses `MountPolicy`, which by default permits nothing —
    /// a build with an explicit path under `.denyHostPaths` is refused, and the caller must
    /// either name a permitted root or let the CLI default the context to `.`.
    ///
    /// Only absolute paths. A relative one cannot be judged against roots expressed
    /// absolutely, and resolving it here would mean guessing at a working directory that
    /// belongs to whoever spawns the process — in Phase 2, the other end of the wire.
    private static func checkHostBuildPath(_ value: String, context: String,
                                           mountPolicy: MountPolicy) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .hostBuildPath)
        guard !value.isEmpty, value.hasPrefix("/") else { return bad }
        if let error = checkAbsolutePath(value, context: context) { return error }
        // Building the filesystem root is never what was meant, and is catastrophic if it is.
        guard value != "/" else { return bad }

        // **Must exist now**, which is the review's Medium finding (9 August) narrowed.
        //
        // `MountPolicy` keeps a nonexistent trailing component lexically, because a *mount*
        // source legitimately may not exist yet. A build input is different: you cannot build a
        // context that is not there. Accepting one opened a window — validate
        // `/tmp/allowed/context` while it does not exist, then `ln -s /Users/someone` into place
        // before the build spawns, and the CLI follows the link out of the permitted root.
        //
        // Requiring existence closes that half: there is nothing to create in the gap, only an
        // existing object to repoint. The residual race is narrower and is recorded in the
        // review — fully closing it needs the execution boundary to hold a filesystem handle
        // rather than a string, which `Process` does not give us.
        guard FileManager.default.fileExists(atPath: value) else {
            return .hostPathNotPermitted(context: context, path: value)
        }

        // Checked *after* resolution, so a symlink cannot name a permitted path and point
        // elsewhere. `allowsHostPath` resolves internally; this repeats it explicitly so the
        // containment decision is made about the same string the guard above proved exists.
        let resolved = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
        guard mountPolicy.allowsHostPath(resolved), mountPolicy.allowsHostPath(value) else {
            return .hostPathNotPermitted(context: context, path: value)
        }
        return nil
    }

    /// `source:/dest[:ro|rw]`. Source is a named volume or an absolute host path.
    private static func checkMountSpec(_ value: String, context: String,
                                       mountPolicy: MountPolicy) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .mountSpec)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return bad }

        let source = String(parts[0])
        if source.hasPrefix("/") {
            if let error = checkAbsolutePath(source, context: context) { return error }
            // Handing a container the whole host filesystem defeats the point of the
            // allowlist. Bind mounts must name something narrower than `/`.
            if source == "/" { return bad }
            // Grammar is not authorisation: `/Users:/host:ro` is a well-formed mount
            // spec and also a total compromise of the host. The path must be permitted
            // by the filesystem owner's policy — which defaults to allowing none.
            guard mountPolicy.allowsHostPath(source) else {
                return .hostPathNotPermitted(context: context, path: source)
            }
        } else if !isIdentifier(source) {
            return bad
        }

        let destination = String(parts[1])
        guard destination != "/" else { return bad }
        if let error = checkAbsolutePath(destination, context: context) { return error }

        if parts.count == 3 {
            let options = parts[2].split(separator: ",")
            guard !options.isEmpty, options.allSatisfy({ $0 == "ro" || $0 == "rw" }) else { return bad }
            // `ro` and `rw` together are contradictory, not merely repeated.
            let optionSet = Set(options)
            guard !(optionSet.contains("ro") && optionSet.contains("rw")) else { return bad }
        }
        return nil
    }

    private static func checkAbsolutePath(_ value: String, context: String) -> AllowlistError? {
        let bad = AllowlistError.invalidValue(context: context, value: value, shape: .absolutePath)
        guard value.hasPrefix("/"), (1...1024).contains(value.utf8.count) else { return bad }
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." || component == ".." {
                return .pathTraversal(context: context, value: value)
            }
        }
        // `//` and trailing `/` are tolerated (they are not traversal), but an empty
        // path or one made only of separators is not a path.
        guard value.contains(where: { $0 != "/" }) else { return bad }
        return nil
    }

    private static func isInteger(_ value: String, in range: ClosedRange<Int>) -> Bool {
        guard (1...9).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(value) else { return false }
        return range.contains(n)
    }

    private static func isSignal(_ value: String) -> Bool {
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) { return isInteger(value, in: 1...64) }
        let name = value.hasPrefix("SIG") ? String(value.dropFirst(3)) : value
        guard (2...12).contains(name.count) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private static func isMemorySize(_ value: String) -> Bool {
        var digits = Substring(value)
        // `T` and `P` are documented and accepted — verified: `-m 1T` and `-m 1P` both run.
        // Longest suffixes first so `KB` is not mistaken for `B`.
        for suffix in ["KB", "MB", "GB", "TB", "PB", "K", "M", "G", "T", "P", "B"]
        where value.uppercased().hasSuffix(suffix) {
            digits = value.prefix(value.count - suffix.count)
            break
        }
        guard (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits) else { return false }
        return n > 0
    }

    private static func isPlatform(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            (1...32).contains(part.count) && part.allSatisfy { isASCIIAlphanumeric($0) || $0 == "_" }
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            (1...3).contains(octet.count) && octet.allSatisfy { $0.isASCII && $0.isNumber }
                && (Int(octet).map { (0...255).contains($0) } ?? false)
        }
    }

    private static func isCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isIPv4(String(parts[0])) else { return false }
        guard (1...2).contains(parts[1].count), parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let prefix = Int(parts[1]) else { return false }
        return (0...32).contains(prefix)
    }

    /// IPv6 CIDR. Written out rather than delegating to `inet_pton` because `FlotillaCore`
    /// stays Foundation-only so it builds and tests identically on Linux.
    ///
    /// Accepts the forms that matter for a private network prefix — full groups and a single
    /// `::` elision — and rejects everything else. It is a *validator*, not a parser: being
    /// strict costs a user one clear rejection, while being loose costs a confusing CLI error
    /// later, or an argument shape we did not intend to allow.
    private static func isCIDRV6(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard (1...3).contains(parts[1].count), parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let prefix = Int(parts[1]), (0...128).contains(prefix) else { return false }
        return isIPv6(String(parts[0]))
    }

    private static func isIPv6(_ value: String) -> Bool {
        // At most one "::" elision.
        let elisions = value.ranges(of: "::").count
        guard elisions <= 1 else { return false }
        guard !value.isEmpty, value.count <= 45 else { return false }
        // No stray ":::" and no leading/trailing single colon.
        guard !value.contains(":::") else { return false }
        if value.hasPrefix(":") && !value.hasPrefix("::") { return false }
        if value.hasSuffix(":") && !value.hasSuffix("::") { return false }

        let groups = value.components(separatedBy: ":")
        // Every non-empty group is 1–4 hex digits.
        for group in groups where !group.isEmpty {
            guard (1...4).contains(group.count),
                  group.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        }
        let filled = groups.filter { !$0.isEmpty }.count
        if elisions == 1 {
            // An elision stands for one or more zero groups, so there must be room for it.
            return filled <= 7
        }
        return filled == 8
    }

    private static func isKeyValue(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "=") else { return false }
        let key = value[value.startIndex..<equals]
        guard (1...128).contains(key.count), let first = key.first, isASCIIAlphanumeric(first) else { return false }
        guard key.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }) else { return false }
        return value[value.index(after: equals)...].utf8.count <= 512
    }
}
