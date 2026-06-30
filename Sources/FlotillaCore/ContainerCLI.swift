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

    // MARK: Lifecycle (fire-and-check)

    @discardableResult public func start(_ id: String) throws -> CommandResult { try host.run(["start", id]) }
    @discardableResult public func stop(_ id: String) throws -> CommandResult { try host.run(["stop", id]) }
    @discardableResult public func remove(_ id: String, force: Bool = false) throws -> CommandResult {
        try host.run(force ? ["rm", "-f", id] : ["rm", id])
    }
    @discardableResult public func pull(_ reference: String) throws -> CommandResult {
        try host.run(["image", "pull", reference])
    }
}
