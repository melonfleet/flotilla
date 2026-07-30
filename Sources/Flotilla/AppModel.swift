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

    /// Internal rather than `private` so `AppModelDetail.swift`'s extension can share **this**
    /// instance. It was private, which Swift's same-file rule put out of reach of an
    /// extension in another file, so that extension built a second `ContainerCLI` of its own.
    /// That compiles as a bypass of nothing — both cross `Allowlist` — but it silently
    /// discards this one's `mountPolicy`, and a narrowed policy that some call sites quietly
    /// ignore is worse than no policy at all. One instance, one boundary.
    let cli: ContainerCLI

    /// Shared with the Settings screen. Unmanaged by default, matching the personal,
    /// unmanaged-Mac case (`DECISIONS.md` Q4) — a managed source is wired in once the
    /// app reads `/Library/Managed Preferences` for real.
    let settingsStore: SettingsStore

    /// Retained for as long as the app runs. `SettingsPersistence` writes on every change
    /// through this token, and dropping it would stop persistence silently — which looks
    /// identical to the bug it exists to fix.
    private let persistence: SettingsObservation?

    /// The default store is seeded from `UserDefaults` and writes back on change. Tests and
    /// previews pass their own in-memory store, which then persists nothing.
    init(cli: ContainerCLI = ContainerCLI(host: LocalHost()), settingsStore: SettingsStore? = nil) {
        let resolved: (store: SettingsStore, observation: SettingsObservation?)
        if let settingsStore {
            resolved = (settingsStore, nil)
        } else {
            let made = SettingsPersistence.makeStore()
            resolved = (made.store, made.observation)
        }

        self.cli = cli
        self.settingsStore = resolved.store
        self.persistence = resolved.observation
        self.appearance = resolved.store.effectiveAppearance
        self.needsAppearanceOnboarding = resolved.store.needsAppearanceOnboarding
        self.presentation = resolved.store[SettingsKeys.presentation]
        self.notifier = Notifier(categories: Self.notificationSettings(from: resolved.store))
        observeSettings()
    }

    // MARK: Appearance
    //
    // `SettingsStore` is Foundation-only, so it is not `@Observable` and cannot drive
    // SwiftUI on its own — and `SettingRow` keeps each edit in local `@State`, so nothing
    // propagated past the row that made it. The result was a picker offering Light / Dark /
    // Auto that changed precisely nothing. This is the bridge: the store's change
    // notifications become observable properties the scenes can read.

    /// What the app should actually render with. `.auto` means follow the system.
    private(set) var appearance: AppearanceMode
    /// True until the user (or a managed profile) has answered the first-run question.
    /// Distinct from "chose auto" — see `AppearancePreference.notChosen`.
    private(set) var needsAppearanceOnboarding: Bool

    private var settingsObservation: SettingsObservation?

    private func observeSettings() {
        settingsObservation = settingsStore.observeChanges { [weak self] _ in
            // The store may notify from any thread; this state is main-actor isolated.
            Task { @MainActor [weak self] in self?.reloadAppearance() }
        }
    }

    /// `SettingsStore` exposes notification state one category at a time
    /// (`isEnabled(_:)`); `NotificationSettings` is the value the notifier wants. This
    /// collects the former into the latter, honouring precedence per key, so a managed
    /// profile that locks a category is respected here too.
    private static func notificationSettings(from store: SettingsStore) -> NotificationSettings {
        NotificationSettings(enabled: Dictionary(uniqueKeysWithValues:
            NotificationCategory.allCases.map { ($0, store.isEnabled($0)) }
        ))
    }

    /// **Show Flotilla in: Menu bar / Dock / Both.** Read by `AppDelegate`, which is the only
    /// place that can act on it — activation policy is an `NSApplication` concern.
    private(set) var presentation: AppPresentation

    /// Called after any settings change, so a preference edit takes effect without relaunch.
    var onPresentationChange: (() -> Void)?

    private func reloadAppearance() {
        appearance = settingsStore.effectiveAppearance
        needsAppearanceOnboarding = settingsStore.needsAppearanceOnboarding

        let newPresentation = settingsStore[SettingsKeys.presentation]
        if newPresentation != presentation {
            presentation = newPresentation
            onPresentationChange?()
        }

        // The interval may have been what changed; restart the timers against the new values.
        restartPolling()
        restartStatsPolling()
        // Categories may have been toggled.
        notifier.updateCategories(Self.notificationSettings(from: settingsStore))
    }

    // MARK: Polling
    //
    // `pollIntervalSeconds` has been in the registry and on the Settings screen from the
    // start — "Seconds between `container ls` refreshes. 0 disables polling." — and nothing
    // ever polled. Flotilla only refreshed when you pressed Refresh, so a container that
    // exited on its own sat in the table looking healthy indefinitely. That is the same
    // class of bug as showing an empty list for a failed load, just slower to notice.

    private var pollTask: Task<Void, Never>?

    /// Seconds between refreshes, or nil when the user has turned polling off. Guards
    /// against a nonsensical stored value: a negative or absurd interval from a corrupt
    /// preference or a managed profile must not become a spin loop.
    private var pollInterval: Duration? {
        let seconds = settingsStore[SettingsKeys.pollIntervalSeconds]
        guard seconds > 0 else { return nil }          // 0 (or nonsense) means off
        return .seconds(min(seconds, 3600))
    }

    /// Called on launch and whenever settings change. Cancelling first is what makes this
    /// safe to call repeatedly — otherwise every settings edit would leave another timer
    /// running and the refresh rate would silently multiply.
    func restartPolling() {
        pollTask?.cancel()
        guard let interval = pollInterval else { pollTask = nil; return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Skip a tick rather than queue behind one: if an action is in flight it
                // will refresh when it finishes, and a poll landing mid-action would fight
                // the optimistic state the row is showing.
                guard self.busy.isEmpty else { continue }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        statsTask?.cancel()
        statsTask = nil
    }

    // MARK: Stats
    //
    // `cli.stats` and `StatsSampler` both existed and nothing rendered either, so the table
    // had no CPU or Memory columns despite the approved mockup carrying them from the start.
    // CPU is a *delta* measure: one sample cannot produce a percentage, which is why the
    // sampler returns nil until it has two and why nil must never be drawn as 0%.

    /// Delivers the per-category notifications the Settings pane has been offering toggles
    /// for all along with nothing behind them. A no-op when there is no app bundle, so
    /// `swift run Flotilla` keeps working — see `Notifier`.
    let notifier: Notifier

    private let sampler = StatsSampler()
    private var statsTask: Task<Void, Never>?

    /// CPU percent per container id, or absent when not yet measurable.
    private(set) var cpuPercents: [String: Double] = [:]
    /// Memory bytes per container id, straight from the last sample.
    private(set) var memoryUsage: [String: Int64] = [:]

    func cpuPercent(for id: String) -> Double? { cpuPercents[id] }
    func memoryBytes(for id: String) -> Int64? { memoryUsage[id] }

    /// A dash, never "0%". "We have not sampled this yet" and "this container is idle" are
    /// different facts and must not share a rendering.
    func cpuLabel(for id: String) -> String {
        guard let percent = cpuPercents[id] else { return "—" }
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    func memoryLabel(for id: String) -> String {
        guard let bytes = memoryUsage[id] else { return "—" }
        return ByteCountFormatStyle(style: .memory).format(bytes)
    }

    /// CPU history for one container, oldest → newest, for the card's sparkline.
    ///
    /// `nil` entries are preserved rather than dropped: they are the samples where a
    /// percentage could not be computed (first sample, or a counter reset after a restart),
    /// and a line drawn straight through them would claim continuity that never existed.
    ///
    /// Reads through `statsGeneration` so SwiftUI actually re-renders — `StatsSampler` is a
    /// reference type outside the observation graph, so a view calling this directly would
    /// never be invalidated when new samples land.
    func cpuHistory(for id: String) -> [Double?] {
        _ = statsGeneration
        return sampler.history(for: id).map(\.cpuPercent)
    }

    /// Bumped on every sample so `@Observable` has a stored property to track.
    private(set) var statsGeneration = 0

    private var statsInterval: Duration? {
        let seconds = settingsStore[SettingsKeys.statsPollIntervalSeconds]
        guard seconds > 0 else { return nil }
        return .seconds(min(seconds, 3600))
    }

    /// Separate from the container poll on purpose: `container stats` is heavier than `ls`,
    /// and the registry gives the two their own intervals so stats can be slowed or switched
    /// off without blinding the container list.
    func restartStatsPolling() {
        statsTask?.cancel()
        guard let interval = statsInterval else { statsTask = nil; return }

        statsTask = Task { [weak self] in
            // Sample immediately, then on the interval: the first sample can never produce a
            // percentage, so waiting a full interval before taking it would leave the columns
            // empty for twice as long as necessary.
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleStats()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func sampleStats() async {
        guard runtimeUsable else { return }
        do {
            let samples = try await Task.detached { [cli] in try cli.stats() }.value
            let now = Date()
            // Same discipline as `containers`: an unconditional write invalidates every
            // view reading these on each sample, whether or not a single figure moved.
            let newCPU = sampler.update(with: samples, at: now)
            if newCPU != cpuPercents { cpuPercents = newCPU }

            let newMemory = Dictionary(
                uniqueKeysWithValues: samples.compactMap { sample in
                    sample.memoryUsageBytes.map { (sample.id, $0) }
                }
            )
            if newMemory != memoryUsage { memoryUsage = newMemory }

            // The history grew by a point, so this genuinely did change — it is what drives
            // the sparkline forward.
            statsGeneration &+= 1
        } catch {
            // Deliberately quiet: stats are decoration next to the container list, and a
            // failing `stats` must not raise a modal over a table that is working fine. The
            // columns fall back to dashes, which is the honest rendering of "unknown".
            cpuPercents = [:]
            memoryUsage = [:]
        }
    }

    /// Records the first-run choice. Failure is surfaced rather than swallowed: the only
    /// realistic cause is a managed profile having locked appearance, and silently
    /// discarding the user's pick would leave onboarding looking broken.
    func chooseAppearance(_ mode: AppearanceMode) {
        do {
            try settingsStore.chooseAppearance(mode)
        } catch {
            actionError = "Couldn't save that appearance choice: \(error)"
        }
        reloadAppearance()
    }

    /// Result of the last preflight, so the UI can explain *why* nothing is listed.
    private(set) var preflight: PreflightResult?

    /// Check the runtime before listing anything. Without this the app cannot tell
    /// "no containers" from "no `container` installed", which are very different and
    /// look identical in an empty table.
    func runPreflight() async {
        let result = await Task.detached { [cli] in Preflight(cli: cli).run() }.value
        preflight = result
        if let reason = Self.unavailableReason(for: result) {
            state = .unavailable(reason)
        }
    }

    /// Shared with `refreshVolumes`/`refreshNetworks`: they fail the same runtime check
    /// containers do, and repeating the diagnosis text in three places would let them drift.
    private static func unavailableReason(for result: PreflightResult) -> String? {
        switch result {
        case .ok:
            return nil
        case .missing:
            return "Apple's `container` CLI isn't installed."
        case .tooOld(let found, let required):
            return "`container` \(found) is too old — \(required) or newer is required."
        case .unusable(let reason):
            // Name the fix, not just the fault. The commonest cause by far is the API
            // service simply not being started, and the user should not have to go
            // looking for the one command that resolves it.
            let remedy = reason.lowercased().contains("apiserver")
                || reason.lowercased().contains("xpc")
                || reason.lowercased().contains("connection")
                ? "\n\nStart it with:  container system start"
                : ""
            return "`container` is installed but not usable — \(reason)\(remedy)"
        }
    }

    /// True until preflight says otherwise. Nil means preflight hasn't run yet, in which
    /// case we optimistically try — an unnecessary refresh is cheaper than a blank screen.
    private var runtimeUsable: Bool {
        guard let preflight else { return true }
        if case .ok = preflight { return true }
        return false
    }

    /// What the Refresh control must call. Re-runs preflight FIRST: if the runtime was
    /// unusable, `refresh()` alone would hit its own guard and silently do nothing, so the
    /// user could start the service and never recover without relaunching the app.
    func reload() async {
        preflight = nil          // clear the stale verdict, or the guard below still bites
        state = .loading
        await runPreflight()
        // Explicit, user-initiated: a spinner here is honest, unlike on a background tick.
        await refresh(showingProgress: true)
        // Start (or restart) polling only once we know the runtime is usable — polling a
        // runtime that isn't there would spawn a doomed Process every few seconds.
        restartPolling()
        restartStatsPolling()
    }

    /// - Parameter showingProgress: whether this refresh may put the UI into `.loading`.
    ///   **False for every background poll**, and that is the whole point.
    ///
    /// This used to set `.loading` unconditionally. Since the poll timer landed that meant
    /// the container list switched to a spinner and back every few seconds — SwiftUI tore
    /// down the whole table and rebuilt it on each tick, which is exactly the flicker the owner
    /// saw and correctly noted that Docker Desktop does not have. Live data does not require
    /// a visible reload; it requires updating the data *in place*.
    ///
    /// A spinner is only honest when there is nothing on screen yet. Once rows exist, a
    /// background fetch should be invisible until it has something different to show.
    func refresh(showingProgress: Bool = false) async {
        // Don't poll a runtime preflight already told us is unusable — it would replace a
        // precise diagnosis ("container isn't installed") with a generic failure.
        guard runtimeUsable else { return }
        if showingProgress { state = .loading }
        do {
            // Off the main actor: this shells out to `container` and would otherwise stall
            // the UI on a slow or unreachable runtime.
            let fetched = try await Task.detached { [cli] in try cli.listContainers() }.value
            notifyUnexpectedExits(previous: containers, current: fetched)

            // Only assign when something actually changed. `@Observable` notifies on every
            // write regardless of equality, so an unconditional assignment invalidates every
            // view reading `containers` on each poll even when the fleet is completely
            // static — the second half of the flicker.
            if fetched != containers { containers = fetched }

            lastRefresh = Date()
            if state != .loaded { state = .loaded }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// "Container exited unexpectedly" — the category the notifications pane has offered
    /// since day one with nothing behind it.
    ///
    /// *Unexpectedly* is the whole point: a container we were asked to stop is expected and
    /// must stay silent, so anything with an action in flight is excluded. `busy` is the
    /// signal — a user-initiated stop holds the id for the duration of the call, and the
    /// refresh that follows it happens after `busy` is released, which is why this also
    /// requires the container to have been absent from `busy` when the poll ran.
    ///
    /// Only fires for containers we previously *saw* running: a container that was already
    /// stopped when the app launched has not just exited, and announcing it on first refresh
    /// would be noise on every launch.
    private func notifyUnexpectedExits(previous: [Container], current: [Container]) {
        guard !previous.isEmpty else { return }   // first load has no "before" to compare

        let stillRunning = Set(current.filter(Self.isRunning).map(\.id))
        let nowStopped = previous
            .filter { Self.isRunning($0) && !stillRunning.contains($0.id) }
            .filter { !recentlyActed.contains($0.id) }

        for container in nowStopped {
            let name = container.id
            Task { [notifier] in
                await notifier.post(
                    .containerExited,
                    title: "Container exited",
                    body: "\(name) stopped on its own."
                )
            }
        }
    }

    /// Ids we deliberately acted on recently, so their stopping is not reported as a
    /// surprise. Cleared as each action completes its follow-up refresh.
    private var recentlyActed: Set<Container.ID> = []

    // MARK: Volumes

    private(set) var volumesState: LoadState = .idle
    private(set) var volumes: [ContainerVolume] = []

    func refreshVolumes() async {
        guard runtimeUsable else {
            volumesState = .unavailable(preflight.flatMap(Self.unavailableReason) ?? "`container` is unavailable.")
            return
        }
        volumesState = .loading
        do {
            let fetched = try await Task.detached { [cli] in try cli.listVolumes() }.value
            volumes = fetched
            volumesState = .loaded
        } catch {
            volumesState = .failed(String(describing: error))
        }
    }

    func createVolume(_ name: String) async {
        do {
            _ = try await Task.detached { [cli] in try cli.createVolume(name) }.value
        } catch {
            actionError = "Create volume failed for \(name): \(error)"
        }
        await refreshVolumes()
    }

    func removeVolume(_ volume: ContainerVolume) async {
        guard !busy.contains(volume.id) else { return }
        busy.insert(volume.id)
        defer { busy.remove(volume.id) }
        do {
            _ = try await Task.detached { [cli] in try cli.removeVolume(volume.name) }.value
        } catch {
            actionError = "Delete volume failed for \(volume.name): \(error)"
        }
        await refreshVolumes()
    }

    // MARK: Networks

    private(set) var networksState: LoadState = .idle
    private(set) var networks: [ContainerNetwork] = []

    func refreshNetworks() async {
        guard runtimeUsable else {
            networksState = .unavailable(preflight.flatMap(Self.unavailableReason) ?? "`container` is unavailable.")
            return
        }
        networksState = .loading
        do {
            let fetched = try await Task.detached { [cli] in try cli.listNetworks() }.value
            networks = fetched
            networksState = .loaded
        } catch {
            networksState = .failed(String(describing: error))
        }
    }

    func createNetwork(_ name: String) async {
        do {
            _ = try await Task.detached { [cli] in try cli.createNetwork(name) }.value
        } catch {
            actionError = "Create network failed for \(name): \(error)"
        }
        await refreshNetworks()
    }

    func removeNetwork(_ network: ContainerNetwork) async {
        guard !busy.contains(network.id) else { return }
        busy.insert(network.id)
        defer { busy.remove(network.id) }
        do {
            _ = try await Task.detached { [cli] in try cli.removeNetwork(network.id) }.value
        } catch {
            actionError = "Delete network failed for \(network.id): \(error)"
        }
        await refreshNetworks()
    }

    /// `container` reports state as a free-form string. Compare case-insensitively and
    /// treat anything we don't recognise as not-running: a table that quietly shows an
    /// unknown state as healthy is worse than one that shows it as stopped.
    static func isRunning(_ container: Container) -> Bool {
        container.status.state.lowercased() == "running"
    }

    var running: [Container] { containers.filter(Self.isRunning) }
    var stopped: [Container] { containers.filter { !Self.isRunning($0) } }

    // MARK: Images

    private(set) var imagesState: LoadState = .idle
    private(set) var images: [ContainerImage] = []

    func refreshImages() async {
        guard runtimeUsable else {
            imagesState = .unavailable(preflight.flatMap(Self.unavailableReason) ?? "`container` is unavailable.")
            return
        }
        imagesState = .loading
        do {
            let fetched = try await Task.detached { [cli] in try cli.listImages() }.value
            images = fetched
            imagesState = .loaded
        } catch {
            imagesState = .failed(String(describing: error))
        }
    }

    func pullImage(_ reference: String) async {
        do {
            _ = try await Task.detached { [cli] in try cli.pull(reference) }.value
        } catch {
            actionError = "Pull failed for \(reference): \(error)"
        }
        await refreshImages()
    }

    func removeImage(_ image: ContainerImage) async {
        guard !busy.contains(image.id) else { return }
        busy.insert(image.id)
        defer { busy.remove(image.id) }
        do {
            _ = try await Task.detached { [cli] in try cli.removeImage(image.reference) }.value
        } catch {
            actionError = "Delete image failed for \(image.reference): \(error)"
        }
        await refreshImages()
    }

    // MARK: Logs

    /// Backs `ContainerDetailView`'s Logs tab. Streaming and `exec` are Phase 4, so this
    /// is a plain bounded fetch — the view drives it with its own Reload button and owns
    /// its own loading/error display, rather than the shared `actionError` alert, because
    /// a stale log view failing to reload shouldn't pop a modal over the rest of the app.
    func fetchLogs(for id: String, lines: Int = 200) async throws -> LogChunk {
        try await Task.detached { [cli] in try cli.logs(id, lines: lines) }.value
    }

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
        // Held past `busy` being released, so the refresh that follows this action does not
        // report an intentional stop as an unexpected exit.
        recentlyActed.insert(id)
        defer { busy.remove(id) }

        do {
            // Off the main actor: each of these spawns `container` and waits on it.
            // Note every one routes through ContainerCLI, which validates against the
            // Allowlist first — the UI never builds an argv itself.
            try await Task.detached { [cli] () -> Void in
                switch action {
                case .start:   try cli.start(id)
                case .stop:    try cli.stop(id)
                case .restart: try cli.restart(id)
                case .delete:  try cli.remove(id)
                }
            }.value
        } catch {
            let message = "\(Self.label(for: action)) failed for \(id): \(error)"
            actionError = message
            // Errors are the one mandatory category — not disableable, per FEATURES.md.
            Task { [notifier] in
                await notifier.post(.error, title: "\(Self.label(for: action)) failed", body: message)
            }
        }

        // Refresh regardless: on failure the container's real state is now unknown, and
        // showing a stale row is worse than showing the truth.
        await refresh()
        recentlyActed.remove(id)
    }

    /// Bulk counterpart to `perform(_:on:)`, for the containers table's multi-selection
    /// action bar. Runs every id through the same allowlisted `ContainerCLI` calls and
    /// refreshes once at the end rather than once per id — `perform(_:on:)` itself is left
    /// untouched so single-row callers keep their existing per-action refresh.
    func performBulk(_ action: Action, on ids: Set<Container.ID>) async {
        // Collected, not assigned per-iteration. Writing `actionError` inside the loop
        // meant each failure overwrote the last, so stopping eight containers and failing
        // five of them reported exactly one — the user would fix that one and believe the
        // job was done. A bulk operation has to report its true blast radius.
        var failures: [(id: Container.ID, error: String)] = []

        for id in ids.sorted() where !busy.contains(id) {
            busy.insert(id)
            do {
                try await Task.detached { [cli] () -> Void in
                    switch action {
                    case .start:   try cli.start(id)
                    case .stop:    try cli.stop(id)
                    case .restart: try cli.restart(id)
                    case .delete:  try cli.remove(id)
                    }
                }.value
            } catch {
                failures.append((id, String(describing: error)))
            }
            busy.remove(id)
        }

        if let first = failures.first {
            let verb = Self.label(for: action)
            if failures.count == 1 {
                actionError = "\(verb) failed for \(first.id): \(first.error)"
            } else {
                // Name a bounded handful rather than a wall of ids, but always state the
                // true count so the number is never smaller than what actually failed.
                let named = failures.prefix(4).map(\.id).joined(separator: ", ")
                let rest = failures.count > 4 ? ", and \(failures.count - 4) more" : ""
                actionError = """
                    \(verb) failed for \(failures.count) of \(ids.count) containers \
                    (\(named)\(rest)).

                    First error: \(first.error)
                    """
            }
        }

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

    // MARK: Run

    func runContainer(image: String, options: ContainerCLI.RunOptions, command: [String] = []) async {
        do {
            _ = try await Task.detached { [cli] in try cli.run(image: image, options: options, command: command) }.value
        } catch {
            actionError = "Run failed for \(image): \(error)"
        }
        await refresh()
    }

    /// The validated argv for `container run …`, or the `Allowlist` error that rejects
    /// it. Built from `ContainerCLI.runArguments` — the same construction `run(image:...)`
    /// itself executes — and validated with `mountPolicy: .unrestricted`, matching
    /// `ContainerCLI`'s own local-execution policy exactly, so the run sheet's live
    /// preview can never show a command as accepted or rejected differently than reality
    /// would. Static and pure so the view holds no allowlist logic of its own.
    static func runPreview(
        image: String, options: ContainerCLI.RunOptions, command: [String] = []
    ) -> Result<ValidatedCommand, AllowlistError> {
        Allowlist.validate(ContainerCLI.runArguments(image: image, options: options, command: command),
                           mountPolicy: .unrestricted)
    }
}
