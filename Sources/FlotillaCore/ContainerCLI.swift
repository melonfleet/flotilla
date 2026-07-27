import Foundation

/// High-level, typed convenience over a `ContainerHost`. Both `LocalHost` and (later)
/// `RemoteHost` flow through this identically, so client and host modes share all
/// container semantics. See `reference/container-cli.md` for the command surface.
public struct ContainerCLI: Sendable {
    public let host: ContainerHost
    public init(host: ContainerHost) { self.host = host }

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
    /// `mountPolicy: .unrestricted` is passed **explicitly and only here**: this
    /// `ContainerCLI` drives the machine `host` runs on *on behalf of its own owner*, so
    /// the caller already trusts itself with its own filesystem — there is no wire
    /// between "who asked" and "whose disk". Do **not** copy `.unrestricted` into a
    /// remote-serving path: a host peer accepting requests from a client (Phase 2) must
    /// supply its own `MountPolicy.roots(...)` instead, or a client could mount
    /// `/Users:/host:ro` on someone else's Mac. See `MountPolicy`.
    @discardableResult
    private func execute(_ args: [String]) throws -> CommandResult {
        let validated = try Allowlist.validated(args, mountPolicy: .unrestricted)
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

        public init(name: String? = nil, ports: [String] = [], env: [String] = [],
                    volumes: [String] = [], detach: Bool = true) {
            self.name = name
            self.ports = ports
            self.env = env
            self.volumes = volumes
            self.detach = detach
        }
    }

    @discardableResult
    public func run(image: String, options: RunOptions = RunOptions(), command: [String] = []) throws -> CommandResult {
        var args = ["run"]
        if options.detach { args.append("-d") }
        if let name = options.name { args += ["--name", name] }
        for assignment in options.env { args += ["-e", assignment] }
        for mapping in options.ports { args += ["-p", mapping] }
        for mount in options.volumes { args += ["-v", mount] }
        args.append(image)
        // An explicit `--` before the in-container command, even when it happens to be
        // empty here: a command token that itself starts with `-` (e.g. `--version`)
        // would otherwise be parsed as a flag *of `container run`* — see the separator
        // note on `Allowlist.validated`.
        if !command.isEmpty {
            args.append("--")
            args.append(contentsOf: command)
        }
        return try execute(args)
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

    // MARK: Volumes — mutate

    @discardableResult public func createVolume(_ name: String) throws -> CommandResult {
        try execute(["volume", "create", name])
    }

    @discardableResult public func removeVolume(_ name: String) throws -> CommandResult {
        try execute(["volume", "rm", name])
    }

    // MARK: Networks — mutate

    @discardableResult public func createNetwork(_ name: String) throws -> CommandResult {
        try execute(["network", "create", name])
    }

    @discardableResult public func removeNetwork(_ name: String) throws -> CommandResult {
        try execute(["network", "rm", name])
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
