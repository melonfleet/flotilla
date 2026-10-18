import Foundation

/// The recipe's only setup policy: chown the fresh mount root, without recursion or seeding.
public struct VolumeOwner: Sendable, Codable, Equatable {
    public var uid: Int
    public var gid: Int
    public init(uid: Int, gid: Int) { self.uid = uid; self.gid = gid }
    public var isValid: Bool { (0...2_147_483_647).contains(uid) && (0...2_147_483_647).contains(gid) }
    public var numericPair: String { "\(uid):\(gid)" }
    public var pending: String { "pending:\(numericPair)" }
    public var done: String { "done:\(numericPair)" }
}

/// Mutable completion state for container 1.5, whose volume labels are creation-only.
/// Records are scoped by host and bound to a unique creation label, never just a volume name.
/// Calls are serialized, including the foreground helper, so retries cannot overlap in this app.
public final class VolumeSetupStore: @unchecked Sendable {
    public static let label = "dev.melonfleet.flotilla.init"
    public static let operationLabel = "dev.melonfleet.flotilla.init-operation"
    private struct Record: Codable {
        var host: String
        var volume: String
        var operation: String
        var owner: VolumeOwner
        var image: String
        var state: String
    }
    private let file: URL
    private let digest: String
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
        self.digest = Allowlist.volumeSetupBusyboxDigest
    }

    // Only tests may supply a synthetic digest; production has one pin in Allowlist.swift.
    init(file: URL, testDigest: String) { self.file = file; self.digest = testDigest }

    /// A fixed argv; never accepts host paths, helper images, scripts, or command tokens.
    static func helperArguments(volume: String, owner: VolumeOwner, digest: String) throws -> [String] {
        guard owner.isValid, Allowlist.accepts(volume, as: .identifier) else {
            throw ContainerCLIError.unsupported("Invalid volume ownership setup.")
        }
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ContainerCLIError.unsupported("Volume setup needs the approved BusyBox digest. Andy must fill Allowlist.volumeSetupBusyboxDigest from a real pull.")
        }
        return ["run", "--rm", "-v", "\(volume):/mnt", "docker.io/library/busybox@sha256:\(digest)",
                "chown", owner.numericPair, "/mnt"]
    }

    /// `newOwners` contains only original, unedited Suggestions mounts. Other mounts may only
    /// resume an already recorded pending operation; they can never acquire setup provenance.
    /// Existing volumes without our record are left alone, even if their labels say pending.
    public func prepare(cli: ContainerCLI, host: String, image: String, mounts: [String],
                        newOwners: [String: VolumeOwner] = [:], requireNewVolumes: Bool = false, createOnly: Bool = false,
                        settingUp: @Sendable (String) -> Void = { _ in }) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try read()
        let mounted = Set(mounts.compactMap { mount -> String? in
            let parts = mount.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, Allowlist.accepts(String(parts[0]), as: .identifier) else { return nil }
            return String(parts[0])
        })
        guard !newOwners.isEmpty || records.contains(where: {
            $0.host == host && $0.image == image && mounted.contains($0.volume) && $0.state == $0.owner.pending
        }) else { return }
        var volumes = try cli.listVolumes()
        for name in mounted.sorted() {
            var index = records.firstIndex { $0.host == host && $0.volume == name }
            let requestedOwner = mounts.compactMap { mount -> VolumeOwner? in
                guard mount.hasPrefix(name + ":") else { return nil }
                return newOwners[mount]
            }.first
            if index == nil, let owner = requestedOwner {
                if volumes.contains(where: { $0.name == name }) {
                    if requireNewVolumes {
                        throw ContainerCLIError.unsupported("Volume \(name) already exists; the stack needs a fresh volume.")
                    }
                    continue
                }
                // Validate the app pin BEFORE allocating resources. No unpinned fallback.
                _ = try Self.helperArguments(volume: name, owner: owner, digest: digest)
                let record = Record(host: host, volume: name, operation: UUID().uuidString,
                                    owner: owner, image: image, state: owner.pending)
                records.append(record)
                try write(records) // intent survives a disconnect immediately after create
                do {
                    _ = try cli.createVolume(name, options: .init(labels: [
                        "\(Self.label)=\(owner.pending)", "\(Self.operationLabel)=\(record.operation)"
                    ]))
                } catch {
                    // An ambiguous remote failure may have created it. Keep the intent: only
                    // the matching operation label will authorize a retry on the next start.
                    throw error
                }
                volumes = try cli.listVolumes()
                index = records.count - 1
            }
            guard !createOnly, let index else { continue }
            let record = records[index]
            guard record.image == image, record.state == record.owner.pending else { continue }
            guard let volume = volumes.first(where: { $0.name == name }),
                  volume.labels?[Self.operationLabel] == record.operation,
                  volume.labels?[Self.label] == record.owner.pending else {
                throw ContainerCLIError.unsupported("Volume \(name) no longer matches its fresh-volume setup record. Ownership was left unchanged.")
            }
            let args = try Self.helperArguments(volume: name, owner: record.owner, digest: digest)
            // Validate under the actual CLI policy too. The helper gets precisely one named
            // volume, regardless of the local owner's broader MountPolicy.
            _ = try Allowlist.validated(Array(args.prefix(5)) + ["--"] + args.suffix(3), mountPolicy: .denyHostPaths, wirePolicy: cli.wirePolicy)
            settingUp("Setting up \(name) for \(image)…")
            _ = try cli.setupVolume(name, owner: record.owner, digest: digest)
            records[index].state = record.owner.done
            try write(records)
        }
    }

    private func read() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
    }

    private func write(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
