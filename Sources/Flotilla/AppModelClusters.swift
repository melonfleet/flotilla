import Foundation
import FlotillaCore

/// Local Kubernetes clusters.
///
/// **Nodes, not clusters, in the data.** `container k8s list` prints a CLUSTER column that comes
/// back empty even with two clusters present, and puts the cluster's name under NODE — measured
/// on 1.4.1 and captured in the fixtures. So there is no hierarchy to model: each row is a
/// cluster, and `K8sNode.node` is its name. If Apple ever populates that column this becomes the
/// place that has to grow a grouping.
@MainActor
extension AppModel {

    // MARK: Loading

    func refreshClusters() async {
        guard runtimeUsable else { return }
        clustersState = .loading
        do {
            let fetched = try await Task.detached { [cli] in try cli.k8sNodes() }.value
            // The same equality guard the containers and machines polls use: `@Observable`
            // notifies on every write, so an unconditional assignment invalidates every view on
            // each poll even when nothing moved.
            if fetched != clusters {
                recordClusterTransitions(previous: clusters, current: fetched)
                clusters = fetched
            }
            clustersState = .loaded
            clustersLastRefresh = Date()
        } catch {
            clusters = []
            clustersState = .failed(describe(error))
            record("Could not list Kubernetes clusters: \(error)", subsystem: "k8s")
        }
    }

    /// A first sighting is not a transition — the rule the container and machine feeds follow,
    /// for the same reason: announcing every cluster present at launch would fill the strip with
    /// news of nothing having happened.
    func recordClusterTransitions(previous: [K8sNode], current: [K8sNode]) {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.node, $0.state) })
        for cluster in current {
            guard let was = before[cluster.node] else { continue }
            guard was.caseInsensitiveCompare(cluster.state) != .orderedSame else { continue }
            recordActivity(ContainerEvent(date: Date(), from: was, to: cluster.state,
                                          kind: .cluster, subject: cluster.node))
        }
    }

    // MARK: Actions

    /// Creates a cluster.
    ///
    /// Slow enough to deserve saying so: the first one pulls a kind node image of about a
    /// gigabyte and boots a VM, and took over ten minutes on the machine this was built on.
    func createCluster(name: String, cpus: Int?, memory: String?, nodeImage: String?,
                       autoRemove: Bool) async -> Bool {
        await withProgress(
            title: "Create the cluster “\(name)”",
            command: Self.createClusterPreview(name: name, cpus: cpus, memory: memory,
                                               nodeImage: nodeImage, autoRemove: autoRemove),
            work: { [weak self] progress in
                guard let self else { return "" }
                let step = progress.begin("Creating \(name)")
                // Streamed, not buffered. The CLI narrates a create the whole way through —
                // `[2/2] Waiting for cluster to be ready [12m 3s]` — and `execute` would hold
                // all of it until the process exited, leaving a spinner for twelve minutes with
                // no way to tell work from a hang.
                try await runCreate(name: name, cpus: cpus, memory: memory, nodeImage: nodeImage,
                                    autoRemove: autoRemove) { line in
                    progress.update(step, detail: line.summary)
                }
                progress.finish(step, detail: nil)
                recordActivity(ContainerEvent(date: Date(), from: "absent", to: "running",
                                              kind: .cluster, subject: name, action: "Created"))
                return "\(name) created"
            },
            confirm: { [weak self] in
                guard let self else { return true }
                await refreshClusters()
                return clusters.contains { $0.node == name }
            }
        )
    }

    /// Runs the create to completion, reporting each progress line.
    ///
    /// **No cancellation, deliberately.** A create that is stopped half way leaves a VM and a
    /// kubeconfig entry behind and no command to tidy either — `k8s delete` wants a cluster that
    /// finished being made. Offering a Cancel that produced that is worse than not offering one,
    /// so the panel says what is happening and lets it finish. If the CLI ever grows a safe way
    /// to abandon a create, this is where it goes.
    private func runCreate(name: String, cpus: Int?, memory: String?, nodeImage: String?,
                           autoRemove: Bool,
                           onProgress: @escaping @MainActor (K8sCreateProgress) -> Void) async throws {
        let cli = self.cli
        let handle = StreamHandle()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task.detached {
                do {
                    let stream = try cli.createClusterStreaming(
                        name: name, cpus: cpus, memory: memory, nodeImage: nodeImage,
                        autoRemove: autoRemove,
                        onProgress: { progress in
                            Task { @MainActor in onProgress(progress) }
                        },
                        onEnd: { end in
                            if end.exitCode == 0 {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ClusterCreateFailure(exitCode: end.exitCode))
                            }
                        })
                    handle.adopt(stream)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        handle.release()
    }

    func startCluster(_ cluster: K8sNode) async {
        await perform(on: cluster, title: "Start", action: "Started") { cli in
            try cli.startCluster(cluster.node)
        }
    }

    func deleteCluster(_ cluster: K8sNode) async {
        await perform(on: cluster, title: "Delete", action: "Deleted") { cli in
            try cli.deleteCluster(cluster.node)
        }
    }

    /// Loads a local image into a cluster's containerd.
    ///
    /// The command that makes the rest worth having: build an image in Flotilla, load it, and
    /// `kubectl run --image-pull-policy=Never` finds it without a registry in the middle.
    func loadImage(_ reference: String, into cluster: K8sNode) async {
        await perform(on: cluster, title: "Load \(reference) into", action: nil) { cli in
            try cli.loadImage(reference, intoCluster: cluster.node)
        }
    }

    /// Writes the cluster's context to Flotilla's own kubeconfig and returns where it went.
    ///
    /// **Not a way to keep `container` out of `~/.kube/config`.** Measured on 1.4.1: `k8s create`
    /// writes the default kubeconfig itself, at creation time, with no flag to stop it. This is
    /// an additional copy you can point `KUBECONFIG` at — useful because it holds one cluster and
    /// nothing else — and the UI must not claim more than that.
    @discardableResult
    func writeKubeconfig(for cluster: K8sNode) async -> URL? {
        let destination = Self.kubeconfigURL
        let succeeded = await withProgress(
            title: "Write a kubeconfig for “\(cluster.node)”",
            command: "container k8s write-config --name \(cluster.node) --kubeconfig \(destination.path)",
            work: { [weak self] progress in
                guard let self else { return "" }
                let step = progress.begin("Writing \(destination.lastPathComponent)")
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await Task.detached { [cli] in
                    try cli.writeKubeconfig(cluster: cluster.node, to: destination.path)
                }.value
                progress.finish(step, detail: nil)
                return "Written to \(destination.path)"
            }
        )
        return succeeded ? destination : nil
    }

    /// Flotilla's own kubeconfig, beside the app's other support files.
    static var kubeconfigURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appending(path: SettingsPersistence.domain).appending(path: "kubeconfig")
    }

    /// One shape for the three single-argument cluster operations, so they cannot drift in how
    /// they report or what they refresh.
    private func perform(on cluster: K8sNode, title: String, action: String?,
                         work: @escaping @Sendable (ContainerCLI) throws -> CommandResult) async {
        guard !isBusy(cluster.node, kind: .cluster) else { return }
        markBusy(cluster.node, kind: .cluster)
        defer { clearBusy(cluster.node, kind: .cluster) }

        await withProgress(
            title: "\(title) “\(cluster.node)”",
            command: "container k8s …",
            work: { [weak self] progress in
                guard let self else { return "" }
                let step = progress.begin("\(title) \(cluster.node)")
                _ = try await Task.detached { [cli] in try work(cli) }.value
                progress.finish(step, detail: nil)
                if let action {
                    recordActivity(ContainerEvent(date: Date(), from: cluster.state, to: action.lowercased(),
                                                  kind: .cluster, subject: cluster.node, action: action))
                }
                return "\(cluster.node) \(action?.lowercased() ?? "done")"
            }
        )
        await refreshClusters()
    }

    /// The command a create will run, for the form's preview and the progress panel.
    static func createClusterPreview(name: String, cpus: Int?, memory: String?,
                                     nodeImage: String?, autoRemove: Bool) -> String {
        switch createClusterValidation(name: name, cpus: cpus, memory: memory,
                                       nodeImage: nodeImage, autoRemove: autoRemove) {
        case .success(let validated): validated.localPreview
        case .failure(let error): "container k8s create … (\(error))"
        }
    }

    /// The allowlist's verdict on a create, so the form is disabled for the same reasons the
    /// boundary would refuse it rather than for a second set of rules kept in a view.
    static func createClusterValidation(name: String, cpus: Int?, memory: String?,
                                        nodeImage: String?,
                                        autoRemove: Bool) -> Result<ValidatedCommand, AllowlistError> {
        var argv = ["k8s", "create", "--name", name]
        if autoRemove { argv.append("--rm") }
        if let cpus { argv += ["--cpus", String(cpus)] }
        if let memory, !memory.isEmpty { argv += ["--memory", memory] }
        if let nodeImage, !nodeImage.isEmpty { argv += ["--node-image", nodeImage] }
        return Allowlist.validate(argv, mountPolicy: .unrestricted)
    }
}

/// Keeps the child alive for the length of the await.
///
/// The handle arrives on a detached task after `Process.run` returns, which can be *after* the
/// continuation has already resumed on a fast failure. Holding it in a box rather than a local
/// means neither order drops it on the floor.
private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: CommandStream?

    func adopt(_ stream: CommandStream) {
        lock.lock(); defer { lock.unlock() }
        self.stream = stream
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        stream = nil
    }
}

/// The CLI refused or failed. Its own words went to the panel as progress lines; this carries
/// the status so the operation is reported as failed rather than quietly succeeding.
struct ClusterCreateFailure: Error, CustomStringConvertible {
    let exitCode: Int32
    var description: String {
        "`container k8s create` exited with status \(exitCode). The lines above are what it said."
    }
}
