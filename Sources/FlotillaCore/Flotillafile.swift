import Foundation

// A declarative description of machines and containers to create — a Vagrantfile-style
// spec, at the owner's request for Flotilla 1.0. Apple `container` has no format like this at
// all (verified: zero hits for compose/manifest/declarative anywhere in the captured
// `--help` corpus in `reference/cli-help/`), so this is entirely Flotilla's own.
//
// Parsing only. Nothing in this file executes anything, resolves a path, reads another
// file, or follows an include or URL — a Flotillafile yields a validated value, and a UI
// layer turns that into pre-filled run forms the user still confirms. That is the same
// boundary `research/GAP-PLAN.md` draws around compose import ("read a file into
// pre-filled run forms", not `vagrant up`), and it applies here for the same reason: the
// actual invocation still crosses `Allowlist` and `MountPolicy` later, at confirmation
// time, not here.
//
// A Flotillafile is untrusted input from a file someone else may have sent, so validation
// is the point, not decoding: unknown keys are refused rather than ignored, every field is
// checked against the same value vocabulary `Allowlist.ValueShape` defines for the CLI
// itself (reusing `Allowlist.isIdentifier` and `ValueShape.rule` directly rather than
// inventing parallel spellings), and every list, string and the file itself are bounded
// before most of the JSON is even walked.

// MARK: - Model

public struct Flotillafile: Sendable, Equatable {
    public let version: Int
    public let machines: [MachineSpec]
    public let containers: [ContainerSpec]
}

/// `container machine create`'s `--home-mount` / `machine set`'s `home-mount=`
/// (`research/MACHINES-SPEC.md`). Its own enum rather than a `Bool`: the CLI's third
/// state, `none`, has no sensible true/false reading.
public enum HomeMountMode: String, Sendable, Equatable, CaseIterable {
    case ro, rw, none
}

/// One `machines` entry. `cpus`, `memory` and `homeMount` are optional and, left
/// unset, mean "let the CLI apply its own default" — the same meaning an absent
/// `--cpus`/`--memory`/`--home-mount` has on `container machine create`.
public struct MachineSpec: Sendable, Equatable {
    public let name: String
    public let image: String
    public let cpus: Int?
    public let memory: String?
    public let homeMount: HomeMountMode?
}

/// One `containers` entry. `ports`, `env` and `volumes` default to empty rather than
/// optional, since an absent list and an empty one mean the same thing here.
public struct ContainerSpec: Sendable, Equatable {
    public let name: String
    public let image: String
    public let ports: [String]
    public let env: [String]
    public let volumes: [String]
    public let cpus: Int?
    public let memory: String?
}

// MARK: - Errors

public enum FlotillafileError: Error, Equatable, Sendable {
    /// Checked before a single byte is parsed, so a pathological file fails without the
    /// cost of building a JSON object graph from it.
    case fileTooLarge(bytes: Int, limit: Int)
    case malformedJSON(String)
    /// A field exists but decodes to the wrong JSON type (a string where a number was
    /// required, an object where an array was required, …). `detail` is the decoder's
    /// own description of the mismatch, which already names what was found.
    case wrongType(context: String, field: String, detail: String)
    case missingVersion
    /// A version this build has never heard of. Refused outright rather than partially
    /// interpreted under the current field set — a newer schema may not mean the same
    /// thing by `machines` or `containers`.
    case unsupportedVersion(found: Int, supported: Int)
    case missingField(context: String, field: String)
    /// Refused rather than silently dropped — see `research/VM-SECURITY-REVIEW.md`'s
    /// `machine set` row: a key the file's author believed was applied and was not is
    /// worse than an outright refusal.
    case unknownField(context: String, field: String)
    case invalidValue(context: String, field: String, value: String, rule: String)
    case tooManyEntries(context: String, limit: Int)
    case duplicateName(context: String, name: String)
}

extension FlotillafileError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileTooLarge(let bytes, let limit):
            "Flotillafile is \(bytes) bytes, over the \(limit) byte limit"
        case .malformedJSON(let reason):
            "Flotillafile is not valid JSON: \(reason)"
        case .wrongType(let context, let field, let detail):
            "\(context): field '\(field)' has the wrong type — \(detail)"
        case .missingVersion:
            "Flotillafile is missing the required 'version' field"
        case .unsupportedVersion(let found, let supported):
            "Flotillafile version \(found) is newer than this build supports (max \(supported)) " +
            "— upgrade Flotilla, or change the file's 'version'"
        case .missingField(let context, let field):
            "\(context) is missing required field '\(field)'"
        case .unknownField(let context, let field):
            "\(context) has unknown field '\(field)'"
        case .invalidValue(let context, let field, let value, let rule):
            "\(context): '\(value)' isn't a valid \(field). \(rule)"
        case .tooManyEntries(let context, let limit):
            "\(context) has more entries than the \(limit)-entry limit"
        case .duplicateName(let context, let name):
            "\(context) has more than one entry named '\(name)'"
        }
    }
}

// MARK: - Parsing

extension Flotillafile {
    /// The only schema version this build understands. `research/FEATURES.md`: "Schema
    /// version integer + migration — one field on day one; saves a corrupt-prefs bug
    /// later." `SettingsPersistence` learned this the hard way with no version field at
    /// all; this carries one from the first release.
    public static let currentVersion = 1

    /// Structural limits applied before semantic validation. A Flotillafile may arrive
    /// from anywhere — email, Slack, a repo someone cloned — so a pathological one (a
    /// multi-gigabyte file, or one with ten thousand containers) must fail fast rather
    /// than spend memory or time on it.
    public struct Limits: Sendable, Equatable {
        public var maxFileBytes: Int
        public var maxMachines: Int
        public var maxContainers: Int
        public var maxPortsPerContainer: Int
        public var maxEnvPerContainer: Int
        public var maxVolumesPerContainer: Int

        public init(maxFileBytes: Int = 1_048_576,
                    maxMachines: Int = 64,
                    maxContainers: Int = 64,
                    maxPortsPerContainer: Int = 16,
                    maxEnvPerContainer: Int = 24,
                    maxVolumesPerContainer: Int = 16) {
            self.maxFileBytes = maxFileBytes
            self.maxMachines = maxMachines
            self.maxContainers = maxContainers
            self.maxPortsPerContainer = maxPortsPerContainer
            self.maxEnvPerContainer = maxEnvPerContainer
            self.maxVolumesPerContainer = maxVolumesPerContainer
        }

        // Matches `Allowlist`'s own repeat caps for `--publish` (16), `--env` (24) and
        // `--volume` (16) on `container run` — a Flotillafile shouldn't be able to
        // describe a container the CLI's own allowlist would refuse to create.
        public static let `default` = Limits()
    }

    /// Throwing form. The primary implementation; `parseResult` below wraps it, mirroring
    /// `Allowlist.validated`/`Allowlist.validate`.
    public static func parse(_ data: Data, limits: Limits = .default) throws -> Flotillafile {
        guard data.count <= limits.maxFileBytes else {
            throw FlotillafileError.fileTooLarge(bytes: data.count, limit: limits.maxFileBytes)
        }

        // The version gate runs before anything else is even looked at: an unsupported
        // version must be refused outright, not half-read under a field set that may not
        // apply to it.
        let probe = try decodeChecked(VersionProbe.self, from: data)
        guard let version = probe.version else { throw FlotillafileError.missingVersion }
        guard version == currentVersion else {
            if version < 1 {
                throw FlotillafileError.invalidValue(
                    context: "Flotillafile", field: "version", value: String(version),
                    rule: "Expected a positive integer; only \(currentVersion) is currently supported.")
            }
            throw FlotillafileError.unsupportedVersion(found: version, supported: currentVersion)
        }

        // Unknown-key screening, ahead of typed decoding: rejecting an unrecognised key
        // is a different, more specific complaint than a type mismatch, and the file's
        // author should hear the one that actually explains what is wrong. This walks
        // `JSONSerialization`'s untyped tree purely for key *names* — it never inspects a
        // value's type, so it isn't exposed to the Bool/Int ambiguity `NSNumber` bridging
        // has on both platforms (`true` casts to `Int` as `1`); typed fields are decoded
        // via `JSONDecoder` below instead, which tracks the real JSON token type.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            try checkKeys(root, allowed: ["version", "machines", "containers"], context: "Flotillafile")
            try checkNestedKeys(root, arrayKey: "machines",
                                allowed: ["name", "image", "cpus", "memory", "homeMount"])
            try checkNestedKeys(root, arrayKey: "containers",
                                allowed: ["name", "image", "ports", "env", "volumes", "cpus", "memory"])
        }

        let file = try decodeChecked(RawFile.self, from: data)

        let rawMachines = file.machines ?? []
        guard rawMachines.count <= limits.maxMachines else {
            throw FlotillafileError.tooManyEntries(context: "machines", limit: limits.maxMachines)
        }
        var machines: [MachineSpec] = []
        var seenMachineNames = Set<String>()
        for (index, raw) in rawMachines.enumerated() {
            let machine = try parseMachine(raw, context: "machines[\(index)]")
            guard seenMachineNames.insert(machine.name).inserted else {
                throw FlotillafileError.duplicateName(context: "machines", name: machine.name)
            }
            machines.append(machine)
        }

        let rawContainers = file.containers ?? []
        guard rawContainers.count <= limits.maxContainers else {
            throw FlotillafileError.tooManyEntries(context: "containers", limit: limits.maxContainers)
        }
        var containers: [ContainerSpec] = []
        var seenContainerNames = Set<String>()
        for (index, raw) in rawContainers.enumerated() {
            let container = try parseContainer(raw, context: "containers[\(index)]", limits: limits)
            guard seenContainerNames.insert(container.name).inserted else {
                throw FlotillafileError.duplicateName(context: "containers", name: container.name)
            }
            containers.append(container)
        }

        return Flotillafile(version: version, machines: machines, containers: containers)
    }

    public static func parse(_ string: String, limits: Limits = .default) throws -> Flotillafile {
        try parse(Data(string.utf8), limits: limits)
    }

    /// Result form, for call sites (and tests) that want to compare against a specific
    /// error rather than catch — mirrors `Allowlist.validate` alongside `.validated`.
    public static func parseResult(_ data: Data, limits: Limits = .default) -> Result<Flotillafile, FlotillafileError> {
        do { return .success(try parse(data, limits: limits)) }
        catch let error as FlotillafileError { return .failure(error) }
        catch { return .failure(.malformedJSON(String(describing: error))) } // unreachable
    }

    public static func parseResult(_ string: String, limits: Limits = .default) -> Result<Flotillafile, FlotillafileError> {
        parseResult(Data(string.utf8), limits: limits)
    }

    // MARK: Raw decode shapes

    /// Every field optional, so a missing key decodes to `nil` rather than throwing —
    /// presence and shape are `Flotillafile`'s job, not `Decodable`'s. Only a value
    /// present with the *wrong* JSON type makes `JSONDecoder` throw, which is exactly the
    /// signal `decodeChecked` turns into a `.wrongType` error.
    private struct VersionProbe: Decodable { let version: Int? }

    private struct RawFile: Decodable {
        let version: Int?
        let machines: [RawMachine]?
        let containers: [RawContainer]?
    }

    private struct RawMachine: Decodable {
        let name: String?
        let image: String?
        let cpus: Int?
        let memory: String?
        let homeMount: String?
    }

    private struct RawContainer: Decodable {
        let name: String?
        let image: String?
        let ports: [String]?
        let env: [String]?
        let volumes: [String]?
        let cpus: Int?
        let memory: String?
    }

    private static func decodeChecked<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            throw FlotillafileError.wrongType(context: "Flotillafile", field: fieldPath(context),
                                              detail: context.debugDescription)
        } catch let DecodingError.valueNotFound(_, context) {
            throw FlotillafileError.wrongType(context: "Flotillafile", field: fieldPath(context),
                                              detail: context.debugDescription)
        } catch let DecodingError.keyNotFound(_, context) {
            throw FlotillafileError.wrongType(context: "Flotillafile", field: fieldPath(context),
                                              detail: context.debugDescription)
        } catch let DecodingError.dataCorrupted(context) {
            throw FlotillafileError.malformedJSON(context.debugDescription)
        } catch {
            throw FlotillafileError.malformedJSON(String(describing: error))
        }
    }

    private static func fieldPath(_ context: DecodingError.Context) -> String {
        context.codingPath.isEmpty ? "Flotillafile" : context.codingPath.map(\.stringValue).joined(separator: ".")
    }

    // MARK: Unknown-key screening

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>, context: String) throws {
        for key in object.keys where !allowed.contains(key) {
            throw FlotillafileError.unknownField(context: context, field: key)
        }
    }

    private static func checkNestedKeys(_ root: [String: Any], arrayKey: String, allowed: Set<String>) throws {
        // A structural mismatch here (not an array, not objects) is left to the typed
        // decode below to report — this pass only screens key *names* where the shape is
        // as expected.
        guard let array = root[arrayKey] as? [Any] else { return }
        for (index, entry) in array.enumerated() {
            guard let object = entry as? [String: Any] else { continue }
            try checkKeys(object, allowed: allowed, context: "\(arrayKey)[\(index)]")
        }
    }

    // MARK: Entry validation

    private static func parseMachine(_ raw: RawMachine, context: String) throws -> MachineSpec {
        guard let name = raw.name else { throw FlotillafileError.missingField(context: context, field: "name") }
        guard Allowlist.isIdentifier(name) else {
            throw FlotillafileError.invalidValue(context: context, field: "name", value: name,
                                                 rule: ValueShape.identifier.rule)
        }
        guard let image = raw.image else { throw FlotillafileError.missingField(context: context, field: "image") }
        guard isImageReference(image) else {
            throw FlotillafileError.invalidValue(context: context, field: "image", value: image,
                                                 rule: ValueShape.imageReference.rule)
        }
        if let cpus = raw.cpus {
            guard isValidCPUs(cpus) else {
                throw FlotillafileError.invalidValue(context: context, field: "cpus", value: String(cpus),
                                                     rule: ValueShape.count.rule)
            }
        }
        if let memory = raw.memory {
            guard isMemorySize(memory) else {
                throw FlotillafileError.invalidValue(context: context, field: "memory", value: memory,
                                                     rule: ValueShape.memorySize.rule)
            }
        }
        var homeMount: HomeMountMode?
        if let rawMode = raw.homeMount {
            guard let mode = HomeMountMode(rawValue: rawMode) else {
                throw FlotillafileError.invalidValue(context: context, field: "homeMount", value: rawMode,
                                                     rule: "Expected one of `ro`, `rw` or `none`.")
            }
            homeMount = mode
        }
        return MachineSpec(name: name, image: image, cpus: raw.cpus, memory: raw.memory, homeMount: homeMount)
    }

    private static func parseContainer(_ raw: RawContainer, context: String, limits: Limits) throws -> ContainerSpec {
        guard let name = raw.name else { throw FlotillafileError.missingField(context: context, field: "name") }
        guard Allowlist.isIdentifier(name) else {
            throw FlotillafileError.invalidValue(context: context, field: "name", value: name,
                                                 rule: ValueShape.identifier.rule)
        }
        guard let image = raw.image else { throw FlotillafileError.missingField(context: context, field: "image") }
        guard isImageReference(image) else {
            throw FlotillafileError.invalidValue(context: context, field: "image", value: image,
                                                 rule: ValueShape.imageReference.rule)
        }

        let ports = raw.ports ?? []
        guard ports.count <= limits.maxPortsPerContainer else {
            throw FlotillafileError.tooManyEntries(context: "\(context).ports", limit: limits.maxPortsPerContainer)
        }
        for port in ports {
            guard isPortMapping(port) else {
                throw FlotillafileError.invalidValue(context: "\(context).ports", field: "ports", value: port,
                                                     rule: ValueShape.portMapping.rule)
            }
        }

        let env = raw.env ?? []
        guard env.count <= limits.maxEnvPerContainer else {
            throw FlotillafileError.tooManyEntries(context: "\(context).env", limit: limits.maxEnvPerContainer)
        }
        for assignment in env {
            guard isEnvAssignment(assignment) else {
                throw FlotillafileError.invalidValue(context: "\(context).env", field: "env", value: assignment,
                                                     rule: ValueShape.envAssignment.rule)
            }
        }

        let volumes = raw.volumes ?? []
        guard volumes.count <= limits.maxVolumesPerContainer else {
            throw FlotillafileError.tooManyEntries(context: "\(context).volumes", limit: limits.maxVolumesPerContainer)
        }
        for volume in volumes {
            guard isMountSpec(volume) else {
                throw FlotillafileError.invalidValue(context: "\(context).volumes", field: "volumes", value: volume,
                                                     rule: ValueShape.mountSpec.rule)
            }
        }

        if let cpus = raw.cpus {
            guard isValidCPUs(cpus) else {
                throw FlotillafileError.invalidValue(context: context, field: "cpus", value: String(cpus),
                                                     rule: ValueShape.count.rule)
            }
        }
        if let memory = raw.memory {
            guard isMemorySize(memory) else {
                throw FlotillafileError.invalidValue(context: context, field: "memory", value: memory,
                                                     rule: ValueShape.memorySize.rule)
            }
        }

        return ContainerSpec(name: name, image: image, ports: ports, env: env, volumes: volumes,
                             cpus: raw.cpus, memory: raw.memory)
    }

    // MARK: Shape validators
    //
    // These mirror `Allowlist`'s private per-shape checks (`checkImageReference`,
    // `isMemorySize`, `isPortMapping`, `isEnvAssignment`, `checkMountSpec`, …) rather than
    // calling them: those are `private` to `Allowlist.swift`, which this task does not
    // touch. Where a helper is *not* private — `Allowlist.isIdentifier` — it is reused
    // directly rather than duplicated. Unlike `Allowlist`'s mount-spec check, `isMountSpec`
    // here does not consult a `MountPolicy`: a Flotillafile does not execute anything, and
    // the host-path authorisation question belongs to the real invocation later, once a
    // person has confirmed the pre-filled form built from this value.

    private static func isASCIIAlphanumeric(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func isImageReference(_ value: String) -> Bool {
        guard (1...512).contains(value.count), let first = value.first, isASCIIAlphanumeric(first) else { return false }
        let allowed: Set<Character> = ["_", ".", "-", "/", ":", "@"]
        guard value.allSatisfy({ isASCIIAlphanumeric($0) || allowed.contains($0) }) else { return false }

        let pathPart = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        for component in pathPart.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { return false }
            if component == "." || component == ".." { return false }
        }
        if let lastComponent = pathPart.split(separator: "/", omittingEmptySubsequences: false).last,
           let colon = lastComponent.lastIndex(of: ":"), colon == lastComponent.index(before: lastComponent.endIndex) {
            return false
        }
        let digestParts = value.split(separator: "@", omittingEmptySubsequences: false)
        if digestParts.count > 2 { return false }
        if digestParts.count == 2 {
            let digest = digestParts[1]
            guard digest.hasPrefix("sha256:") else { return false }
            let hex = digest.dropFirst("sha256:".count)
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        }
        return true
    }

    private static func isValidCPUs(_ n: Int) -> Bool { (1...1024).contains(n) }

    private static func isMemorySize(_ value: String) -> Bool {
        var digits = Substring(value)
        for suffix in ["KB", "MB", "GB", "TB", "PB", "K", "M", "G", "T", "P", "B"]
        where value.uppercased().hasSuffix(suffix) {
            digits = value.prefix(value.count - suffix.count)
            break
        }
        guard (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits) else { return false }
        return n > 0
    }

    private static func isPort(_ value: Substring) -> Bool {
        guard (1...5).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(value) else { return false }
        return (1...65_535).contains(port)
    }

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            (1...3).contains(octet.count) && octet.allSatisfy { $0.isASCII && $0.isNumber }
                && (Int(octet).map { (0...255).contains($0) } ?? false)
        }
    }

    private static func isPortMapping(_ value: String) -> Bool {
        var body = Substring(value)
        if let slash = body.lastIndex(of: "/") {
            let proto = body[body.index(after: slash)...]
            guard proto == "tcp" || proto == "udp" else { return false }
            body = body[body.startIndex..<slash]
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
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

    private static func isAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), (1...1024).contains(value.utf8.count) else { return false }
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." || component == ".." { return false }
        }
        guard value.contains(where: { $0 != "/" }) else { return false }
        return true
    }

    private static func isMountSpec(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }

        let source = String(parts[0])
        if source.hasPrefix("/") {
            guard isAbsolutePath(source), source != "/" else { return false }
        } else if !Allowlist.isIdentifier(source) {
            return false
        }

        let destination = String(parts[1])
        guard destination != "/", isAbsolutePath(destination) else { return false }

        if parts.count == 3 {
            let options = parts[2].split(separator: ",")
            guard !options.isEmpty, options.allSatisfy({ $0 == "ro" || $0 == "rw" }) else { return false }
            let optionSet = Set(options)
            guard !(optionSet.contains("ro") && optionSet.contains("rw")) else { return false }
        }
        return true
    }
}
