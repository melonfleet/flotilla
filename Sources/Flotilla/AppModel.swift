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

    func refresh() async {
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
}
