import Foundation
import Network
import FlotillaNet

/// Whether macOS lets Flotilla use the local network, as far as an app can tell (Iris,
/// `research/FIRST-RUN.md`; TN3179).
///
/// There is no API to ask. The system prompt appears the first time the app does something on the
/// local network, and the answer is only visible in what that operation does next. So this browses
/// for Flotilla's own Bonjour service — the one a host advertises — and reads the result:
///
/// - **Something found**, which on a host includes its own advertisement: allowed.
/// - **Waiting with `kDNSServiceErr_PolicyDenied`**: not allowed, or not answered yet. A later
///   answer of Allow moves the browser on, so this is not final; it is read again when Flotilla
///   comes back to the front, which is when someone returns from System Settings.
/// - **Neither, after a while**: unconfirmed. Never "allowed" just because the prompt was triggered.
///
/// Bonjour advertising can be switched off for a host (`bonjourEnabled`), and then a host finds
/// nothing of its own; that reads as unconfirmed, which is honest.
@MainActor
@Observable
final class LocalNetworkCheck {
    enum State: Equatable {
        case notAsked, asking, allowed, denied, unconfirmed
    }

    private(set) var state: State = .notAsked

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    /// How long to wait for a first result before saying "unconfirmed". The host's own listener has
    /// to come up and advertise first.
    private static let patience: Duration = .seconds(20)

    /// `kDNSServiceErr_PolicyDenied`, from `<dns_sd.h>`: the error a browse waits on when the local
    /// network is not allowed.
    private static let policyDenied: DNSServiceErrorType = -65570

    /// Starts (or restarts) the browse that asks. The first one shows macOS's prompt.
    func start() {
        stop()
        if state != .allowed { state = .asking }
        let browser = NWBrowser(for: .bonjour(type: WireTLS.serviceType, domain: nil), using: .tcp)
        // `@Sendable` and a hop to the main actor: Network calls these on the queue given to
        // `start`, and an unmarked closure written here would be main-actor isolated (CLAUDE.md,
        // the helper crash of 9 October). The queue is main today; the closure must not depend on it.
        browser.stateUpdateHandler = { @Sendable [weak self] new in
            Task { @MainActor in self?.handle(new) }
        }
        browser.browseResultsChangedHandler = { @Sendable [weak self] results, _ in
            let found = !results.isEmpty
            Task { @MainActor in if found { self?.state = .allowed } }
        }
        browser.start(queue: .main)
        self.browser = browser
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self, self.state == .asking else { return }
            self.state = .unconfirmed
        }
    }

    /// Reads the answer again, if it has been asked and isn't known to be allowed.
    func recheck() {
        guard state == .denied || state == .unconfirmed else { return }
        start()
    }

    func stop() {
        deadline?.cancel()
        deadline = nil
        browser?.cancel()
        browser = nil
    }

    private func handle(_ new: NWBrowser.State) {
        switch new {
        case .waiting(let error):
            if case .dns(let code) = error, code == Self.policyDenied, state != .allowed { state = .denied }
        case .failed:
            if state == .asking { state = .unconfirmed }
        default:
            break
        }
    }
}
