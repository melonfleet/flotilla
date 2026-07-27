import Foundation
import Observation
import FlotillaCore

/// UI-facing state for the app shell.
///
/// Deliberately thin: every rule about *what may run* lives in `FlotillaCore`
/// (`Allowlist`, `MountPolicy`), not here. A view must never construct an argv and hand it
/// to a host directly — it goes through `ContainerCLI`, which validates first. Keeping that
/// boundary in one place is what makes the security review meaningful.
@MainActor
@Observable
final class AppModel {

    enum LoadState: Equatable {
        case idle
        case loading
        /// `container` is absent or too old — the UI shows preflight guidance rather than an
        /// empty table pretending the fleet is healthy.
        case unavailable(String)
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var containers: [Container] = []
    private(set) var lastRefresh: Date?

    /// Which host each row came from. Phase 1 is local-only, but the table is a *cross-host*
    /// table by design (the one thing no comparable tool has), so rows carry their origin
    /// from the start rather than being retrofitted in Phase 3.
    var hostLabel: String { "This Mac" }

    private let cli: ContainerCLI

    init(cli: ContainerCLI = ContainerCLI(host: LocalHost())) {
        self.cli = cli
    }

    /// Result of the last preflight, so the UI can explain *why* nothing is listed.
    private(set) var preflight: PreflightResult?

    /// Check the runtime before listing anything. Without this the app cannot tell
    /// "no containers" from "no `container` installed", which are very different and
    /// look identical in an empty table.
    func runPreflight() async {
        let result = await Task.detached { [cli] in Preflight(cli: cli).run() }.value
        preflight = result
        switch result {
        case .ok:
            break
        case .missing:
            state = .unavailable("Apple's `container` CLI isn't installed.")
        case .tooOld(let found, let required):
            state = .unavailable("`container` \(found) is too old — \(required) or newer is required.")
        case .unusable(let reason):
            state = .unavailable("`container` is installed but unusable: \(reason)")
        }
    }

    /// True until preflight says otherwise. Nil means preflight hasn't run yet, in which
    /// case we optimistically try — an unnecessary refresh is cheaper than a blank screen.
    private var runtimeUsable: Bool {
        guard let preflight else { return true }
        if case .ok = preflight { return true }
        return false
    }

    func refresh() async {
        // Don't poll a runtime preflight already told us is unusable — it would replace a
        // precise diagnosis ("container isn't installed") with a generic failure.
        guard runtimeUsable else { return }
        state = .loading
        do {
            // Off the main actor: this shells out to `container` and would otherwise stall
            // the UI on a slow or unreachable runtime.
            let fetched = try await Task.detached { [cli] in try cli.listContainers() }.value
            containers = fetched
            lastRefresh = Date()
            state = .loaded
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// `container` reports state as a free-form string. Compare case-insensitively and
    /// treat anything we don't recognise as not-running: a table that quietly shows an
    /// unknown state as healthy is worse than one that shows it as stopped.
    static func isRunning(_ container: Container) -> Bool {
        container.status.state.lowercased() == "running"
    }

    var running: [Container] { containers.filter(Self.isRunning) }
    var stopped: [Container] { containers.filter { !Self.isRunning($0) } }

    // MARK: Lifecycle actions

    /// Ids with an action in flight, so the UI can disable their controls rather than
    /// letting an impatient second click fire a duplicate stop.
    private(set) var busy: Set<Container.ID> = []
    /// Surfaced to the user; an action that fails must say so rather than looking like
    /// nothing happened.
    private(set) var actionError: String?

    func clearActionError() { actionError = nil }

    enum Action { case start, stop, restart, delete }

    func perform(_ action: Action, on container: Container) async {
        let id = container.id
        guard !busy.contains(id) else { return }
        busy.insert(id)
        defer { busy.remove(id) }

        do {
            // Off the main actor: each of these spawns `container` and waits on it.
            // Note every one routes through ContainerCLI, which validates against the
            // Allowlist first — the UI never builds an argv itself.
            try await Task.detached { [cli] in
                switch action {
                case .start:   try cli.start(id)
                case .stop:    try cli.stop(id)
                case .restart: try cli.restart(id)
                case .delete:  try cli.remove(id)
                }
            }.value
        } catch {
            actionError = "\(Self.label(for: action)) failed for \(id): \(error)"
        }

        // Refresh regardless: on failure the container's real state is now unknown, and
        // showing a stale row is worse than showing the truth.
        await refresh()
    }

    private static func label(for action: Action) -> String {
        switch action {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .delete: "Delete"
        }
    }
}
