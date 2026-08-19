import Foundation

public enum ContainerCLIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `container inspect`/`image inspect` returned a well-formed but empty JSON array
    /// for an id the caller asked about.
    case emptyInspectResult(id: String)

    /// The CLI ran and **failed**, reporting why on stderr.
    ///
    /// This case exists because for a long time nothing checked the exit code.
    /// `LocalHost.run` returned a `CommandResult` carrying `exitCode` and an `ok` property
    /// that no call site read, so every failure the CLI reported was discarded and the
    /// operation looked like it had worked. Creating a network that already exists is the
    /// clearest example — the CLI exits 1 saying `network X already exists` and the app said
    /// nothing at all.
    case commandFailed(command: String, exitCode: Int32, message: String)

    /// No `container` binary in any directory we look in. Carries the list so the message can
    /// say where it looked — "isn't installed" with no evidence is exactly the claim that was
    /// wrong for three weeks.
    case runtimeNotFound(searched: [String])

    public var description: String {
        switch self {
        case .emptyInspectResult(let id):
            "‘\(id)’ returned no information."
        case .commandFailed(let command, let exitCode, let message):
            // Lead with what the CLI said. A usage dump is useful in a diagnostic bundle and
            // useless in an alert, so `message` is already reduced to the salient line by
            // `ContainerCLI.failureMessage`.
            message.isEmpty
                ? "`container \(command)` failed (exit \(exitCode))."
                : message
        case .runtimeNotFound(let searched):
            "Apple's `container` CLI was not found in: \(searched.joined(separator: ", "))"
        }
    }
}

/// High-level, typed convenience over a `ContainerHost`. Both `LocalHost` and (later)
/// `RemoteHost` flow through this identically, so client and host modes share all
/// container semantics. See `reference/container-cli.md` for the command surface.
public struct ContainerCLI: Sendable {
    public let host: ContainerHost
    /// See the note on `execute` below: `.unrestricted` is the right default only
    /// because a `ContainerCLI` driving `LocalHost` is trusted with its own disk.
    public let mountPolicy: MountPolicy

    /// Whether this instance may start a shell inside a container. Defaults to the strict
    /// setting, so a `ContainerCLI` built without thinking about it cannot hand out shells —
    /// the same default-deny shape as `MountPolicy`. See `ExecPolicy`.
    public let execPolicy: ExecPolicy

    /// Who this CLI is acting for. `.localOwner` by default, matching `mountPolicy`'s reasoning:
    /// an instance driving this Mac on behalf of its own owner. **A Phase 2 host peer must pass
    /// `.remotePeer`**, which refuses the machine-lifecycle family outright and requires the
    /// bounded form of `logs` and `stats` — see `WirePolicy`.
    public let wirePolicy: WirePolicy

    /// - Parameter wirePolicy: **no default, on the review's finding.** A defaulted capability is one a
    ///   remote-serving call site can acquire by forgetting, and this is the executor: the pure
    ///   validator keeps its `.localOwner` default because previews and tests genuinely *are* the
    ///   local owner and cannot run anything, but nothing that spawns a process should be able to
    ///   inherit "trusted" silently.
    public init(host: ContainerHost,
                mountPolicy: MountPolicy = .unrestricted,
                execPolicy: ExecPolicy = .processListOnly,
                wirePolicy: WirePolicy) {
        // A remote peer with unrestricted host paths can read or rewrite the owner's files through
        // `copy` and `run --volume`, whatever the rest of the table says. The two policies are
        // independent by design; this is the one combination that is never intended.
        if wirePolicy == .remotePeer {
            precondition(mountPolicy != .unrestricted,
                         "a remote-serving ContainerCLI must be given a narrowed MountPolicy")
        }
        self.host = host
        self.mountPolicy = mountPolicy
        self.execPolicy = execPolicy
        self.wirePolicy = wirePolicy
    }

    // MARK: Raw JSON

    public func rawContainersJSON() throws -> String {
        try execute(["ls", "--all", "--format", "json"]).stdout
    }
    public func rawImagesJSON() throws -> String {
        try execute(["image", "list", "--format", "json"]).stdout
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
        return try JSONDecoder.flotilla.decode([ContainerStats].self, from: Data(try succeeding(args).stdout.utf8))
    }
    /// Starts the `container` services.
    ///
    /// Always with `--disable-kernel-install`: the flag defaults to *prompting*, and there is
    /// nowhere for a windowed app to show a prompt. If the kernel genuinely is missing this
    /// fails with the CLI's own message, which is the correct outcome — installing it is the
    /// user's call, not ours.
    @discardableResult
    public func startSystem(timeoutSeconds: Int = 60) throws -> CommandResult {
        try execute(["system", "start", "--disable-kernel-install",
                     "--timeout", String(timeoutSeconds)])
    }

    /// `container system status`, which reports a **stopped** service by exiting non-zero while
    /// still printing the status JSON on stdout.
    ///
    /// Measured, not assumed. With the services stopped:
    ///
    /// ```
    /// exit=1
    /// stdout={"apiServerAppName":"","…":"","status":"unregistered"}
    /// stderr=
    /// ```
    ///
    /// So the decodable answer is *in* the failure, and `execute`'s exit-code check threw it
    /// away — which is why preflight reported "installed but not usable" with the raw JSON
    /// pasted into a sentence, instead of "the service isn't running" with a button. A decoded
    /// status is preferred over the exit code whenever one is present; a genuinely broken
    /// invocation still throws.
    public func systemStatus() throws -> SystemStatus {
        let result = try attempting(["system", "status", "--format", "json"])
        if let status = try? JSONDecoder.flotilla.decode(SystemStatus.self,
                                                        from: Data(result.stdout.utf8)) {
            return status
        }
        guard result.ok else {
            throw ContainerCLIError.commandFailed(command: "system status",
                                                  exitCode: result.exitCode,
                                                  message: Self.failureMessage(result))
        }
        // Exited zero and still unreadable: a real decode failure, reported as one.
        return try JSONDecoder.flotilla.decode(SystemStatus.self, from: Data(result.stdout.utf8))
    }
    public func versions() throws -> [VersionComponent] {
        try JSONDecoder.flotilla.decode([VersionComponent].self,
                                        from: Data(try execute(["system", "version", "--format", "json"]).stdout.utf8))
    }
    public func rawSystemDiskUsageJSON() throws -> String {
        try execute(["system", "df", "--format", "json"]).stdout
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
                                        from: Data(try execute(["volume", "list", "--format", "json"]).stdout.utf8))
    }
    public func listNetworks() throws -> [ContainerNetwork] {
        try JSONDecoder.flotilla.decode([ContainerNetwork].self,
                                        from: Data(try execute(["network", "list", "--format", "json"]).stdout.utf8))
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
        let validated = try Allowlist.validated(args, mountPolicy: mountPolicy,
                                                execPolicy: execPolicy, wirePolicy: wirePolicy)
        return try succeeding(validated.arguments)
    }

    /// Validated execution that **returns** a non-zero exit rather than throwing on it.
    ///
    /// Still goes through `Allowlist` and `MountPolicy` — that is the invariant, and this is not
    /// a way around it. It exists because one command reports a legitimate, actionable state
    /// *by failing*: see `systemStatus`. Keep the caller list to commands whose failure carries
    /// information; everything else wants `execute`.
    private func attempting(_ args: [String]) throws -> CommandResult {
        let validated = try Allowlist.validated(args, mountPolicy: mountPolicy,
                                                execPolicy: execPolicy, wirePolicy: wirePolicy)
        return try host.run(validated.arguments)
    }

    /// Runs `args` and **throws unless the CLI exited zero**.
    ///
    /// **Never call this directly — call `execute`.** This takes an already-canonicalised argv
    /// and runs it verbatim: it does not validate, so calling it with a caller-built array
    /// skips `Allowlist` and `MountPolicy` completely. Two new methods did exactly that when
    /// the Files tab was added, and the giveaway was the CLI reporting "failed to find target
    /// executable --" — the grammar separator that `execute` would have stripped went straight
    /// through to `container`. A security bypass announced itself as a typo.
    ///
    /// Everything goes through here. Without it a non-zero exit was simply returned and
    /// ignored: a duplicate network, a failed start, a refused pull all completed silently.
    /// The one prior symptom users did see — an invalid name — came from `Allowlist`
    /// throwing *before* execution, which is why validation errors surfaced and real CLI
    /// errors did not.
    private func succeeding(_ args: [String]) throws -> CommandResult {
        let result = try host.run(args)
        guard result.ok else {
            throw ContainerCLIError.commandFailed(
                command: args.joined(separator: " "),
                exitCode: result.exitCode,
                message: Self.failureMessage(result)
            )
        }
        return result
    }

    /// The salient line of a CLI failure.
    ///
    /// `container` prefixes real problems with `Error:` and may then print a `Help:`/`Usage:`
    /// block — valuable in a support bundle, noise in an alert. Prefer the `Error:` line;
    /// fall back to the first non-empty line; fall back again to stdout, because some
    /// failures report there instead.
    /// `public` so the app layer can quote the CLI in a *successful-looking* result too — a
    /// command that prints `Error:` and exits zero leaves its only explanation here.
    public static func failureMessage(_ result: CommandResult) -> String {
        func lines(_ text: String) -> [String] {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let candidates = lines(result.stderr) + lines(result.stdout)
        if let errorLine = candidates.first(where: { $0.hasPrefix("Error:") }) {
            return String(errorLine.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        }
        return candidates.first ?? ""
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

    /// A `ls -la` of one directory inside a running container.
    ///
    /// There is no "list files" subcommand — `container copy` moves files but cannot enumerate
    /// them — so browsing has to go through `exec`, and therefore needs
    /// `ExecPolicy.interactiveShell`. A `ContainerCLI` built for a remote peer carries the
    /// strict default and this throws, which is the correct outcome: letting a remote caller
    /// walk a container's filesystem is not something to enable by accident.
    ///
    /// `--` before the path so a filename beginning with `-` is read as a path and not as an
    /// `ls` flag. Returns raw output; parsing is the caller's problem because `ls` formatting
    /// varies between busybox and coreutils and the UI is where that judgement belongs.
    public func listDirectory(_ id: String, path: String) throws -> String {
        try execute(["exec", id, "--", "ls", "-la", "--", path]).stdout
    }

    /// `container copy <source> <destination>`, either direction.
    ///
    /// Endpoints are `name:/path/in/container` or an absolute host path. The host end is
    /// checked against this instance's `MountPolicy` by the allowlist — grammar alone does not
    /// make writing to the real filesystem safe.
    public func copy(from source: String, to destination: String) throws {
        _ = try execute(["copy", source, destination])
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

    /// `container build [-f <path>] [-t <ref>] … [<context-dir>]`.
    ///
    /// `contextDirectory` and `dockerfile` are host paths the build **reads**, and both cross
    /// this instance's `MountPolicy` at the allowlist — a context is a whole directory tree,
    /// so it is a broader read grant than `copy`'s single file. Under the default
    /// `.denyHostPaths` an explicit path is refused outright; pass `nil` to let the CLI
    /// default the context to the process's own working directory.
    ///
    /// Several of the CLI's flags are deliberately unreachable from here *and* from the
    /// allowlist — `--secret`, `--output`, `--vsock-port` and the `--dns*` family. See the
    /// `build` row in `Allowlist` for why each is refused rather than merely unexposed.
    @discardableResult
    public func buildImage(contextDirectory: String?, dockerfile: String?, tag: String?,
                           buildArgs: [String], labels: [String], noCache: Bool,
                           platform: String?, target: String?) throws -> CommandResult {
        var args = ["build"]
        if let dockerfile, !dockerfile.isEmpty { args += ["--file", dockerfile] }
        if let tag, !tag.isEmpty { args += ["--tag", tag] }
        for argument in buildArgs where !argument.isEmpty { args += ["--build-arg", argument] }
        for label in labels where !label.isEmpty { args += ["--label", label] }
        if noCache { args.append("--no-cache") }
        if let platform, !platform.isEmpty { args += ["--platform", platform] }
        if let target, !target.isEmpty { args += ["--target", target] }
        if let contextDirectory, !contextDirectory.isEmpty { args.append(contextDirectory) }
        return try execute(args)
    }

    // MARK: Volumes — mutate

    /// Everything `container volume create` accepts: a size, labels and driver options.
    ///
    /// Size matters more than it looks. Left unset, a volume is provisioned at the driver's
    /// default — **512 GiB** on this runtime — as a sparse ext4 image. Nothing like that much
    /// is consumed, but it is what `volume list` reports, which makes the size column
    /// misleading unless you set one deliberately.
    public struct VolumeOptions: Sendable, Equatable {
        /// `64M`, `2G`, … — the CLI's own suffixes. Nil means the driver default.
        public var size: String?
        /// `key=value`, max 8 (the `Allowlist` cap).
        public var labels: [String]
        /// `key=value`, max 8. Driver-specific.
        public var driverOptions: [String]

        public init(size: String? = nil, labels: [String] = [], driverOptions: [String] = []) {
            self.size = size
            self.labels = labels
            self.driverOptions = driverOptions
        }
    }

    @discardableResult public func createVolume(
        _ name: String, options: VolumeOptions = VolumeOptions()
    ) throws -> CommandResult {
        try execute(Self.createVolumeArguments(name, options: options))
    }

    /// The argv `createVolume` will run, so a form can preview and validate it first.
    ///
    /// Note `-s` and not `--size`: the CLI has no long form for it, and emitting one is
    /// rejected outright. See the `volume create` entry in `Allowlist`.
    public static func createVolumeArguments(
        _ name: String, options: VolumeOptions = VolumeOptions()
    ) -> [String] {
        var args = ["volume", "create"]
        if let size = options.size, !size.isEmpty { args += ["-s", size] }
        for label in options.labels where !label.isEmpty { args += ["--label", label] }
        for option in options.driverOptions where !option.isEmpty { args += ["--opt", option] }
        args.append(name)
        return args
    }

    @discardableResult public func removeVolume(_ name: String) throws -> CommandResult {
        try execute(["volume", "rm", name])
    }

    @discardableResult public func pruneVolumes() throws -> CommandResult {
        try execute(["volume", "prune"])
    }

    // MARK: Networks — mutate

    /// Everything `container network create` accepts. Options are **create-time only**, and
    /// that is the runtime rather than a gap here: `container network` has create, delete,
    /// list, inspect and prune — no update, edit or set (verified 2026-07-30). A network's
    /// addressing cannot be changed once it exists, so a flag not offered at creation is a
    /// permanently unreachable choice. That is why all of them are plumbed through.
    ///
    /// A network may be v4-only, v6-only, or dual-stack — the two prefixes are independent,
    /// which is why they are separate parameters and separate `ValueShape`s.
    public struct NetworkOptions: Sendable, Equatable {
        public var subnet: String?
        public var subnetV6: String?
        public var isInternal: Bool
        /// `key=value`, max 8 — the `Allowlist` cap.
        public var labels: [String]
        /// `key=value`, max 8. Plugin-specific.
        public var options: [String]
        /// Defaults to `container-network-vmnet` when nil; only set it if you mean to.
        public var plugin: String?

        public init(
            subnet: String? = nil, subnetV6: String? = nil, isInternal: Bool = false,
            labels: [String] = [], options: [String] = [], plugin: String? = nil
        ) {
            self.subnet = subnet
            self.subnetV6 = subnetV6
            self.isInternal = isInternal
            self.labels = labels
            self.options = options
            self.plugin = plugin
        }
    }

    @discardableResult public func createNetwork(
        _ name: String, options: NetworkOptions = NetworkOptions()
    ) throws -> CommandResult {
        try execute(Self.createNetworkArguments(name, options: options))
    }

    /// The argv `createNetwork` will run, so the sheet can show and validate it before
    /// anything happens — same seam as `runArguments`, same reason: a preview assembled
    /// separately drifts from what executes.
    public static func createNetworkArguments(
        _ name: String, options: NetworkOptions = NetworkOptions()
    ) -> [String] {
        var args = ["network", "create"]
        if options.isInternal { args.append("--internal") }
        if let subnet = options.subnet, !subnet.isEmpty { args += ["--subnet", subnet] }
        if let v6 = options.subnetV6, !v6.isEmpty { args += ["--subnet-v6", v6] }
        if let plugin = options.plugin, !plugin.isEmpty { args += ["--plugin", plugin] }
        for label in options.labels where !label.isEmpty { args += ["--label", label] }
        for option in options.options where !option.isEmpty { args += ["--option", option] }
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

    // MARK: Machines

    /// `container machine list --format json` — see `ContainerMachine`'s doc comment for
    /// why the model is flat rather than nested like `Container`.
    public func machines() throws -> [ContainerMachine] {
        try JSONDecoder.flotilla.decode([ContainerMachine].self,
                                        from: Data(try execute(["machine", "list", "--format", "json"]).stdout.utf8))
    }

    /// `container machine inspect [<id>]` — `id` is optional on the real CLI, defaulting
    /// to whichever machine `set-default` currently points at. Same one-element-array
    /// shape as `container inspect`, verified against `Fixtures/machine-inspect.json`.
    /// The CLI's own `machine inspect` output verbatim, for the Inspect tab — same reason
    /// `rawInspectJSON` exists: a re-encode of `ContainerMachine` would silently drop every
    /// field we do not model, which is most of the point of an inspect view.
    ///
    /// Note `machine inspect` has **no** `--format` flag and emits JSON by default, unlike
    /// `container inspect`. Another per-leaf asymmetry.
    public func rawMachineInspectJSON(_ id: String? = nil) throws -> String {
        var args = ["machine", "inspect"]
        if let id { args.append(id) }
        return try execute(args).stdout
    }

    public func inspectMachine(_ id: String? = nil) throws -> ContainerMachine {
        var args = ["machine", "inspect"]
        if let id { args.append(id) }
        let result = try execute(args)
        let machines = try JSONDecoder.flotilla.decode([ContainerMachine].self, from: Data(result.stdout.utf8))
        guard let machine = machines.first else {
            throw ContainerCLIError.emptyInspectResult(id: id ?? "default")
        }
        return machine
    }

    /// `container machine create <image> [--name] [--cpus] [--memory] [--home-mount]`.
    ///
    /// Unlike `container volume`/`network create`, `create` takes sizing and the home-mount
    /// grant inline — confirmed against `reference/cli-help/container-machine-1.0.0-help.txt`,
    /// so no follow-up `set` is required before first boot.
    @discardableResult
    public func createMachine(
        image: String, name: String? = nil, cpus: Int? = nil, memory: String? = nil, homeMount: String? = nil
    ) throws -> CommandResult {
        var args = ["machine", "create"]
        if let name { args += ["--name", name] }
        if let cpus { args += ["--cpus", String(cpus)] }
        if let memory { args += ["--memory", memory] }
        if let homeMount { args += ["--home-mount", homeMount] }
        args.append(image)
        return try execute(args)
    }

    /// `container machine set [--name <id>] <key=value> ...`.
    ///
    /// The settings are bare `key=value` operands, not flags — `cpus=4`, `memory=8G`,
    /// `home-mount=ro`, per the captured help text. Takes effect only after the machine is
    /// next booted; see `research/MACHINES-SPEC.md` §4 for the stop-apply-restart UI this
    /// implies.
    @discardableResult
    public func setMachine(
        _ id: String? = nil, cpus: Int? = nil, memory: String? = nil, homeMount: String? = nil
    ) throws -> CommandResult {
        var args = ["machine", "set"]
        if let id { args += ["--name", id] }
        if let cpus { args.append("cpus=\(cpus)") }
        if let memory { args.append("memory=\(memory)") }
        if let homeMount { args.append("home-mount=\(homeMount)") }
        return try execute(args)
    }

    /// `container machine run --name <id>`, with no trailing command — boots the machine
    /// (creating no new state; `run` "boots the container machine if necessary" per the
    /// CLI's own description) without starting a shell inside it. There is no dedicated
    /// `machine start`; this is the boot-only invocation `research/MACHINES-SPEC.md` §3.2
    /// calls for.
    @discardableResult
    public func startMachine(_ id: String? = nil) throws -> CommandResult {
        var args = ["machine", "run"]
        if let id { args += ["--name", id] }
        // `machine run` with **no command** opens an interactive shell, which needs a PTY on
        // the calling side — exactly the `container exec` trap. Without one it fails with
        // "Operation not supported by device" *after having already booted the VM*, so a Start
        // button would report failure on a successful start. Verified on this Mac.
        //
        // So boot by running something trivial instead. `/bin/true` exists in any POSIX
        // userland, exits 0 immediately, and needs no terminal.
        args += ["--", "/bin/true"]
        return try execute(args)
    }

    /// `machine restart` — synthesised, exactly as `restart(_:)` is for containers, because
    /// the CLI has no such subcommand. Stop, then boot.
    ///
    /// Ordered and short-circuiting: if the stop fails this throws and never calls start, so a
    /// machine that refused to stop is not then told to boot. The container `restart(_:)` above
    /// has the same shape for the same reason.
    ///
    /// Note this is *not* the same weight as restarting a container. A machine is a VM, so
    /// anything running inside it — shells, processes started over `machine run` — ends with it.
    /// It does not disturb containers, though: each container gets its own micro-VM, which was
    /// verified on 3 August by deleting every named machine while four containers kept running.
    @discardableResult
    public func restartMachine(_ id: String) throws -> CommandResult {
        try stopMachine(id)
        return try startMachine(id)
    }

    /// `container machine stop [<id>]` — note the id is a **positional operand** here,
    /// unlike `run`/`set`, which take it via `--name`. Per-leaf asymmetry, confirmed
    /// against the captured help text; do not "normalise" this to `--name`.
    @discardableResult
    public func stopMachine(_ id: String? = nil) throws -> CommandResult {
        var args = ["machine", "stop"]
        if let id { args.append(id) }
        return try execute(args)
    }

    /// `container machine delete <id>` — unlike `stop`, the id is **required**.
    @discardableResult
    public func deleteMachine(_ id: String) throws -> CommandResult {
        try execute(["machine", "delete", id])
    }

    /// `container machine set-default <id>` — id is required, same as `delete`.
    @discardableResult
    public func setDefaultMachine(_ id: String) throws -> CommandResult {
        try execute(["machine", "set-default", id])
    }

    /// `container machine logs [-n <lines>] [--boot] [<id>]` — `id` is optional, defaulting
    /// to the default machine, same as `inspect`/`stop`.
    public func machineLogs(_ id: String? = nil, lines: Int = 100, boot: Bool = false) throws -> LogChunk {
        var args = ["machine", "logs", "-n", String(lines)]
        if boot { args.append("--boot") }
        if let id { args.append(id) }
        let result = try execute(args)
        return LogChunk.from(stdout: result.stdout, stderr: result.stderr,
                             containerID: id ?? "default", requestedLines: lines, isBootLog: boot)
    }
}
