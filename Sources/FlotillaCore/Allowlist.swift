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
    /// `key=value` for `--label` / `--opt` / `--option`.
    case keyValue
    /// One of the CLI's `--format` values.
    case outputFormat
    /// A token of the command line run *inside* the container. The one deliberately
    /// permissive shape — see `TrailingPolicy.command`.
    case commandToken
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
}

/// One allowlisted subcommand.
public struct CommandSpec: Sendable, Equatable {
    /// `["ls"]`, `["image", "pull"]`, …
    public let path: [String]
    /// Whether the operation changes host state. The transport layer (Phase 2) uses
    /// this to decide what needs confirmation and what is safe to retry.
    public let mutates: Bool
    /// Hint for the Phase 2 per-request deadline. Not enforced here — validation is
    /// synchronous and pure; the timeout belongs to whoever spawns the process.
    public let timeoutHint: TimeInterval
    public let flags: [FlagSpec]
    public let operands: OperandSpec
    public let trailing: TrailingPolicy

    public init(_ path: [String],
                mutates: Bool,
                timeoutHint: TimeInterval = 30,
                flags: [FlagSpec] = [],
                operands: OperandSpec = .none,
                trailing: TrailingPolicy = .forbidden) {
        self.path = path
        self.mutates = mutates
        self.timeoutHint = timeoutHint
        self.flags = flags
        self.operands = operands
        self.trailing = trailing
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

    public init(subcommand: [String], arguments: [String], mutates: Bool, timeoutHint: TimeInterval) {
        self.subcommand = subcommand
        self.arguments = arguments
        self.mutates = mutates
        self.timeoutHint = timeoutHint
    }

    /// The audit record: what a host peer logs as having been asked to run.
    public var auditDescription: String { (["container"] + arguments).joined(separator: " ") }
}

public enum AllowlistError: Error, Equatable, Sendable {
    case emptyCommand
    case unknownSubcommand(String)
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
        case .unknownFlag(let f): "flag not allowed: \(f)"
        case .malformedFlag(let f): "malformed flag: \(f)"
        case .flagRequiresValue(let f): "flag \(f) requires a value"
        case .flagTakesNoValue(let f): "flag \(f) takes no value"
        case .repeatedFlag(let f): "flag \(f) repeated"
        case .invalidValue(let c, let v, let s): "\(c): '\(v)' is not a valid \(s.rawValue)"
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
    /// - `exec`, `cp`, `export`, `build`, `push`, `registry login` — not Phase 1, and
    ///   each is a data-exfiltration or credential surface that deserves its own review.
    /// - `logs --follow`, `stats` streaming — Phase 4 streaming transport; a bounded
    ///   fetch is all Phase 1 offers, so `-f` is not accepted.
    /// - `system start/stop`, `builder …`, `prune` — fleet-wide destructive or
    ///   privileged; Phase 3+.
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
            CommandSpec(["stats"], mutates: false,
                        flags: [format, FlagSpec(long: "no-stream")],
                        operands: OperandSpec(shape: .identifier, min: 0, max: 32)),
            CommandSpec(["logs"], mutates: false,
                        flags: [FlagSpec(short: "n", value: .count), FlagSpec(long: "boot")],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),

            // MARK: containers — mutate
            CommandSpec(["start"], mutates: true, timeoutHint: 120,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            CommandSpec(["stop"], mutates: true, timeoutHint: 120,
                        flags: [all,
                                FlagSpec(long: "time", short: "t", value: .durationSeconds),
                                FlagSpec(long: "signal", short: "s", value: .signal)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["delete"], mutates: true, timeoutHint: 120,
                        flags: [force, all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["rm"], mutates: true, timeoutHint: 120,
                        flags: [force, all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
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
            CommandSpec(["image", "pull"], mutates: true, timeoutHint: 1800,
                        flags: [FlagSpec(long: "platform", value: .platform)],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 1)),
            CommandSpec(["image", "delete"], mutates: true,
                        flags: [all, force],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["image", "rm"], mutates: true,
                        flags: [all, force],
                        operands: OperandSpec(shape: .imageReference, min: 1, max: 32, minWaivedBy: ["all"])),

            // MARK: volumes
            CommandSpec(["volume", "list"], mutates: false, flags: [format, quiet]),
            CommandSpec(["volume", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            CommandSpec(["volume", "create"], mutates: true,
                        flags: [FlagSpec(long: "size", short: "s", value: .memorySize),
                                FlagSpec(long: "opt", value: .keyValue, repeatable: true, maxRepeats: 8),
                                FlagSpec(long: "label", value: .keyValue, repeatable: true, maxRepeats: 8)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),
            CommandSpec(["volume", "delete"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["volume", "rm"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),

            // MARK: networks
            CommandSpec(["network", "list"], mutates: false, flags: [format, quiet]),
            CommandSpec(["network", "inspect"], mutates: false,
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32)),
            CommandSpec(["network", "create"], mutates: true, timeoutHint: 60,
                        flags: [FlagSpec(long: "internal"),
                                FlagSpec(long: "subnet", value: .cidr),
                                FlagSpec(long: "label", value: .keyValue, repeatable: true, maxRepeats: 8),
                                FlagSpec(long: "option", value: .keyValue, repeatable: true, maxRepeats: 8)],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 1)),
            CommandSpec(["network", "delete"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),
            CommandSpec(["network", "rm"], mutates: true,
                        flags: [all],
                        operands: OperandSpec(shape: .identifier, min: 1, max: 32, minWaivedBy: ["all"])),

            // MARK: system — read only
            CommandSpec(["system", "status"], mutates: false, flags: [format]),
            CommandSpec(["system", "version"], mutates: false, flags: [format]),
            CommandSpec(["system", "df"], mutates: false, flags: [format]),
        ]
    }()

    private static let index: [String: CommandSpec] =
        Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })

    /// The spec for a subcommand path, e.g. `spec(for: ["image", "pull"])`.
    public static func spec(for path: [String]) -> CommandSpec? { index[path.joined(separator: " ")] }

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
                                mountPolicy: MountPolicy = .denyHostPaths) -> Result<ValidatedCommand, AllowlistError> {
        do { return .success(try validated(args, limits: limits, mountPolicy: mountPolicy)) }
        catch let error as AllowlistError { return .failure(error) }
        catch { return .failure(.emptyCommand) } // unreachable: nothing else is thrown
    }

    /// Throwing form, for call sites that already propagate errors (`ContainerCLI`).
    public static func validated(_ args: [String],
                                 limits: Limits = .default,
                                 mountPolicy: MountPolicy = .denyHostPaths) throws -> ValidatedCommand {
        guard !args.isEmpty else { throw AllowlistError.emptyCommand }
        try screen(args, limits: limits)

        let spec = try resolve(args)
        var rest = Array(args.dropFirst(spec.path.count))

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
                guard case .command = spec.trailing else { throw AllowlistError.separatorNotAllowed }
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
                if let long = flag.long { presentLongFlags.insert(long) }
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
        } else if !trailing.isEmpty {
            throw AllowlistError.tooManyOperands(count: operands.count + trailing.count, limit: spec.operands.max)
        }

        // Canonical argv: subcommand, flags, operands, then the in-container command
        // behind an explicit `--`. The separator matters: without it a command token
        // like `--rm` would be re-parsed as a flag *of `container run`* by the CLI.
        var argv = spec.path + flagTokens + operands
        if !trailing.isEmpty { argv.append("--"); argv.append(contentsOf: trailing) }

        return ValidatedCommand(subcommand: spec.path,
                                arguments: argv,
                                mutates: spec.mutates,
                                timeoutHint: spec.timeoutHint)
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
        case .keyValue:
            return isKeyValue(value) ? nil : bad
        case .outputFormat:
            return ["json", "table", "yaml", "toml"].contains(value) ? nil : bad
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
        case 1: return isPort(parts[0])
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
        for suffix in ["KB", "MB", "GB", "K", "M", "G", "B"] where value.uppercased().hasSuffix(suffix) {
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

    private static func isKeyValue(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "=") else { return false }
        let key = value[value.startIndex..<equals]
        guard (1...128).contains(key.count), let first = key.first, isASCIIAlphanumeric(first) else { return false }
        guard key.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "_" || $0 == "." || $0 == "-" }) else { return false }
        return value[value.index(after: equals)...].utf8.count <= 512
    }
}
