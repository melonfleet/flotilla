import Foundation

public enum ContainerCLIError: Error, Equatable, Sendable {
    /// `container inspect`/`image inspect` returned a well-formed but empty JSON array
    /// for an id the caller asked about.
    case emptyInspectResult(id: String)
}

/// High-level, typed convenience over a `ContainerHost`. Both `LocalHost` and (later)
/// `RemoteHost` flow through this identically, so client and host modes share all
/// container semantics. See `reference/container-cli.md` for the command surface.
public struct ContainerCLI: Sendable {
    public let host: ContainerHost
    /// See the note on `execute` below: `.unrestricted` is the right default only
    /// because a `ContainerCLI` driving `LocalHost` is trusted with its own disk.
    public let mountPolicy: MountPolicy

    public init(host: ContainerHost, mountPolicy: MountPolicy = .unrestricted) {
        self.host = host
        self.mountPolicy = mountPolicy
    }

    // MARK: Raw JSON

    public func rawContainersJSON() throws -> String {
        try host.run(["ls", "--all", "--format", "json"]).stdout
    }
    public func rawImagesJSON() throws -> String {
        try host.run(["image", "list", "--format", "json"]).stdout
    }

    // MARK: Typed reads

    public func listContainers() throws -> [Container] {
        try JSONDecoder.flotilla.decode([Container].self, from: Data(try rawContainersJSON().utf8))
    }
    public func listImages() throws -> [ContainerImage] {
        try JSONDecoder.flotilla.decode([ContainerImage].self, from: Data(try rawImagesJSON().utf8))
    }
    public func stats(noStream: Bool = true) throws -> [ContainerStats] {
        var args = ["stats", "--format", "json"]
        if noStream { args.append("--no-stream") }
        return try JSONDecoder.flotilla.decode([ContainerStats].self, from: Data(try host.run(args).stdout.utf8))
    }
    public func systemStatus() throws -> SystemStatus {
        try JSONDecoder.flotilla.decode(SystemStatus.self,
                                        from: Data(try host.run(["system", "status", "--format", "json"]).stdout.utf8))
    }
    public func versions() throws -> [VersionComponent] {
        try JSONDecoder.flotilla.decode([VersionComponent].self,
                                        from: Data(try host.run(["system", "version", "--format", "json"]).stdout.utf8))
    }
    public func rawSystemDiskUsageJSON() throws -> String {
        try host.run(["system", "df", "--format", "json"]).stdout
    }

    /// The disk view. Now typed: the payload was captured from a live `container 1.0.0`
    /// install (`Fixtures/system-df.json`) after this was first left as a raw passthrough
    /// for want of a real schema.
    public func systemDiskUsage() throws -> SystemDiskUsage {
        try JSONDecoder.flotilla.decode(SystemDiskUsage.self,
                                        from: Data(try rawSystemDiskUsageJSON().utf8))
    }
    public func listVolumes() throws -> [ContainerVolume] {
        try JSONDecoder.flotilla.decode([ContainerVolume].self,
                                        from: Data(try host.run(["volume", "list", "--format", "json"]).stdout.utf8))
    }
    public func listNetworks() throws -> [ContainerNetwork] {
        try JSONDecoder.flotilla.decode([ContainerNetwork].self,
                                        from: Data(try host.run(["network", "list", "--format", "json"]).stdout.utf8))
    }

    // MARK: Allowlisted execution

    /// Every mutation — and every read that carries an externally-supplied identifier —
    /// is validated by `Allowlist` before it reaches `ContainerHost.run`.
    ///
    /// `mountPolicy` defaults to `.unrestricted`, which is only safe for a `ContainerCLI`
    /// driving the machine `host` runs on *on behalf of its own owner* — the caller
    /// already trusts itself with its own filesystem, so there is no wire between "who
    /// asked" and "whose disk". Do **not** construct a remote-serving `ContainerCLI` with
    /// the default: a host peer accepting requests from a client (Phase 2) must be given
    /// its own `MountPolicy.roots(...)` at `init`, or a client could mount
    /// `/Users:/host:ro` on someone else's Mac. See `MountPolicy`.
    @discardableResult
    private func execute(_ args: [String]) throws -> CommandResult {
        let validated = try Allowlist.validated(args, mountPolicy: mountPolicy)
        return try host.run(validated.arguments)
    }

    // MARK: Containers — lifecycle

    @discardableResult public func start(_ id: String) throws -> CommandResult {
        try execute(["start", id])
    }

    @discardableResult public func stop(_ id: String, timeout: Int? = nil) throws -> CommandResult {
        var args = ["stop"]
        if let timeout { args += ["--time", String(timeout)] }
        args.append(id)
        return try execute(args)
    }

    /// `container` has no native `restart` subcommand (see `Allowlist`'s notes on the
    /// table); this composes the two allowlisted operations it does have.
    @discardableResult public func restart(_ id: String, timeout: Int? = nil) throws -> CommandResult {
        try stop(id, timeout: timeout)
        return try start(id)
    }

    @discardableResult public func remove(_ id: String, force: Bool = false) throws -> CommandResult {
        var args = ["rm"]
        if force { args.append("-f") }
        args.append(id)
        return try execute(args)
    }

    /// Immediate, unlike `stop`: no `--time` grace period exists on the real CLI, and
    /// the default signal is `KILL` rather than `stop`'s `TERM`.
    @discardableResult public func kill(_ id: String, signal: String? = nil) throws -> CommandResult {
        var args = ["kill"]
        if let signal { args += ["--signal", signal] }
        args.append(id)
        return try execute(args)
    }

    /// Every container that has ever run and stopped, gone in one call — the real CLI
    /// takes no operands and no confirmation flag, so there is nothing to narrow here
    /// beyond what `Allowlist`'s grammar already enforces.
    @discardableResult public func pruneContainers() throws -> CommandResult {
        try execute(["prune"])
    }

    /// `container inspect` returns the same `[Container]`-shaped JSON array as
    /// `ls --format json`, so this reuses `Container` rather than a parallel model.
    ///
    /// That was an unverified assumption when written — no live install was available to
    /// capture from. Since confirmed against a real `container 1.0.0` capture
    /// (`Fixtures/inspect-container.json`): it genuinely is a one-element array, not a bare
    /// object, so decoding as `[Container]` and taking `.first` is correct.
    public func inspect(_ id: String) throws -> Container {
        let result = try execute(["inspect", id])
        let containers = try JSONDecoder.flotilla.decode([Container].self, from: Data(result.stdout.utf8))
        guard let container = containers.first else {
            throw ContainerCLIError.emptyInspectResult(id: id)
        }
        return container
    }

    /// The processes running **inside** a container.
    ///
    /// Docker Desktop shows what a container is actually running, and Apple's `container`
    /// can answer it — `container exec <id> ps` works today, no Phase 4 streaming needed.
    ///
    /// The `Allowlist` entry behind this is locked to exactly this one argv (`TrailingPolicy
    /// .exact`), so this method cannot be generalised into arbitrary in-container execution
    /// by passing different arguments — there are none to pass. Interactive `exec` remains
    /// Phase 4 and remains deliberately unallowlisted.
    ///
    /// Returns raw `ps` output; parsing belongs to the caller that renders it.
    public func processes(_ id: String) throws -> String {
        try execute(["exec", id, "--", "ps", "-o", "pid,comm,args"]).stdout
    }

    /// The CLI's own `inspect` output, verbatim — for the inspect tab's raw JSON view,
    /// which must show *the CLI's* shape rather than a re-encode of `Container` that would
    /// silently drop every field Flotilla does not model (`capAdd`, `dns`, `initProcess`,
    /// `rosetta`, `sysctls`, …). Still goes through `execute` so `Allowlist` validates `id`
    /// exactly as `inspect(_:)` does — never bypass it with a direct `host.run`.
    public func rawInspectJSON(_ id: String) throws -> String {
        try execute(["inspect", id]).stdout
    }

    /// Options for `container run`. Ports, env and volumes are passed as already-shaped
    /// CLI values (`HOST:CONTAINER`, `KEY=VALUE`, `SOURCE:DEST[:ro|rw]`) — `Allowlist`
    /// validates their shape at `execute` time, so there is no need to duplicate that
    /// parsing here.
    public struct RunOptions: Sendable {
        public var name: String?
        public var ports: [String]
        public var env: [String]
        public var volumes: [String]
        public var detach: Bool
        /// `--rm`: remove the container automatically when it exits.
        public var rm: Bool
        /// `--cpus`/`-c`: whole CPU count, `Allowlist`'s `.count` shape (1…1024).
        public var cpus: Int?
        /// `--memory`/`-m`: `Allowlist`'s `.memorySize` shape, e.g. `"512M"` or plain digits.
        public var memory: String?
        /// `--network`: an existing network's identifier.
        public var network: String?
        /// `--platform`: `os/arch[/variant]`.
        public var platform: String?

        public init(name: String? = nil, ports: [String] = [], env: [String] = [],
                    volumes: [String] = [], detach: Bool = true, rm: Bool = false,
                    cpus: Int? = nil, memory: String? = nil, network: String? = nil,
                    platform: String? = nil) {
            self.name = name
            self.ports = ports
            self.env = env
            self.volumes = volumes
            self.detach = detach
            self.rm = rm
            self.cpus = cpus
            self.memory = memory
            self.network = network
            self.platform = platform
        }
    }

    /// The argv `run` will execute, without executing it.
    ///
    /// Exists so the run sheet's **live command preview** shows the real thing rather than
    /// a hand-assembled lookalike. A view must never build an argv to *execute* — that is
    /// what keeps the `Allowlist` meaningful — but a preview that drifts from what actually
    /// runs is worse than no preview at all, so both share this one construction.
    ///
    /// Pair it with `Allowlist.validated(_:mountPolicy:)` to show the user a command that
    /// is not merely plausible but accepted: an invalid mount or port should be visible in
    /// the sheet before anyone presses Run.
    public static func runArguments(
        image: String, options: RunOptions = RunOptions(), command: [String] = []
    ) -> [String] {
        var args = ["run"]
        if options.detach { args.append("-d") }
        if let name = options.name { args += ["--name", name] }
        for assignment in options.env { args += ["-e", assignment] }
        for mapping in options.ports { args += ["-p", mapping] }
        for mount in options.volumes { args += ["-v", mount] }
        if options.rm { args.append("--rm") }
        if let cpus = options.cpus { args += ["--cpus", String(cpus)] }
        if let memory = options.memory { args += ["--memory", memory] }
        if let network = options.network { args += ["--network", network] }
        if let platform = options.platform { args += ["--platform", platform] }
        args.append(image)
        // An explicit `--` before the in-container command, even when it happens to be
        // empty here: a command token that itself starts with `-` (e.g. `--version`)
        // would otherwise be parsed as a flag *of `container run`* — see the separator
        // note on `Allowlist.validated`.
        if !command.isEmpty {
            args.append("--")
            args.append(contentsOf: command)
        }
        return args
    }

    @discardableResult
    public func run(image: String, options: RunOptions = RunOptions(), command: [String] = []) throws -> CommandResult {
        try execute(Self.runArguments(image: image, options: options, command: command))
    }

    // MARK: Images

    @discardableResult public func pull(_ reference: String) throws -> CommandResult {
        try execute(["image", "pull", reference])
    }

    @discardableResult public func removeImage(_ reference: String, force: Bool = false) throws -> CommandResult {
        var args = ["image", "rm"]
        if force { args.append("-f") }
        args.append(reference)
        return try execute(args)
    }

    /// `container image tag <source> <target>` — the real CLI has no `--force` or other
    /// flags; retagging an existing target simply overwrites it.
    @discardableResult public func tag(_ source: String, as target: String) throws -> CommandResult {
        try execute(["image", "tag", source, target])
    }

    /// Every unused image (or, with `all`, every image not referenced by a container)
    /// gone in one call — see `pruneContainers` for why there is nothing to narrow.
    @discardableResult public func pruneImages(all: Bool = false) throws -> CommandResult {
        var args = ["image", "prune"]
        if all { args.append("--all") }
        return try execute(args)
    }

    /// Same reuse rationale as `inspect(_:)`: `image inspect` is documented as emitting
    /// the same detailed JSON as `image list`, so this decodes into `[ContainerImage]`
    /// rather than a parallel type. Unverified against a live capture — see that note.
    public func inspectImage(_ reference: String) throws -> ContainerImage {
        let result = try execute(["image", "inspect", reference])
        let images = try JSONDecoder.flotilla.decode([ContainerImage].self, from: Data(result.stdout.utf8))
        guard let image = images.first else {
            throw ContainerCLIError.emptyInspectResult(id: reference)
        }
        return image
    }

    /// Same rationale as `rawInspectJSON(_:)`, for images.
    public func rawInspectImageJSON(_ reference: String) throws -> String {
        try execute(["image", "inspect", reference]).stdout
    }

    // MARK: Volumes — mutate

    @discardableResult public func createVolume(_ name: String) throws -> CommandResult {
        try execute(["volume", "create", name])
    }

    @discardableResult public func removeVolume(_ name: String) throws -> CommandResult {
        try execute(["volume", "rm", name])
    }

    @discardableResult public func pruneVolumes() throws -> CommandResult {
        try execute(["volume", "prune"])
    }

    // MARK: Networks — mutate

    /// Options are **create-time only**, and that is a property of the runtime rather than a
    /// gap in this API: `container network` offers create, delete, list, inspect and prune —
    /// there is no update, edit or set (verified 2026-07-30). A network's subnet cannot be
    /// changed once it exists, so if it is not chosen here it is assigned automatically and
    /// the only way to a different one is delete and recreate.
    ///
    /// `Allowlist` has permitted `--subnet` and `--internal` from the start; nothing reached
    /// them until now, which is why every network came out with an auto-assigned range.
    @discardableResult public func createNetwork(
        _ name: String, subnet: String? = nil, isInternal: Bool = false
    ) throws -> CommandResult {
        var args = ["network", "create"]
        if isInternal { args.append("--internal") }
        if let subnet, !subnet.isEmpty { args += ["--subnet", subnet] }
        args.append(name)
        return try execute(args)
    }

    /// The argv `createNetwork` will run, so the sheet can show and validate it before
    /// anything happens — same seam as `runArguments`, same reason: a preview that is
    /// assembled separately drifts from what executes.
    public static func createNetworkArguments(
        _ name: String, subnet: String? = nil, isInternal: Bool = false
    ) -> [String] {
        var args = ["network", "create"]
        if isInternal { args.append("--internal") }
        if let subnet, !subnet.isEmpty { args += ["--subnet", subnet] }
        args.append(name)
        return args
    }

    @discardableResult public func removeNetwork(_ name: String) throws -> CommandResult {
        try execute(["network", "rm", name])
    }

    @discardableResult public func pruneNetworks() throws -> CommandResult {
        try execute(["network", "prune"])
    }

    // MARK: Logs

    /// A bounded fetch of `lines` lines — `container logs --follow` streaming is Phase 4,
    /// so there is no follow flag here (`Allowlist`'s `logs` row does not accept `-f`
    /// either; see its table notes).
    public func logs(_ id: String, lines: Int = 100, bootLog: Bool = false) throws -> LogChunk {
        var args = ["logs", "-n", String(lines)]
        if bootLog { args.append("--boot") }
        args.append(id)
        let result = try execute(args)
        return LogChunk.from(stdout: result.stdout, stderr: result.stderr,
                             containerID: id, requestedLines: lines, isBootLog: bootLog)
    }
}
