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
    /// `execPolicy: .interactiveShell` is set **here**, at the one place a client driving its
    /// own Mac is constructed, and nowhere else. It backs the detail view's Terminal tab.
    ///
    /// Deliberately not a constant inside that tab: when Phase 2 builds a `ContainerCLI` for a
    /// remote peer it will pass the strict default, and the terminal must then refuse rather
    /// than carry on because it had the permissive value baked in. The policy travels with the
    /// CLI, exactly as `MountPolicy` does.
    init(cli: ContainerCLI = ContainerCLI(host: LocalHost(), execPolicy: .interactiveShell, wirePolicy: .localOwner),
         settingsStore: SettingsStore? = nil) {
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
        self.errorLog = ErrorLog(settings: resolved.store)
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

    // MARK: Modal form presentation
    //
    // the owner wants the web-modal feel — the interface behind dims and stops responding while
    // the form sits in front — AND macOS's own red close button. Stock presentations force a
    // choice: a sheet is modal but has no title bar and therefore no traffic lights, while a
    // window has traffic lights but floats free.
    //
    // So the form stays a real window and is made to *behave* modally: it counts itself while
    // open, and `MainWindowView` dims and disables its content whenever the count is above
    // zero. A count rather than a flag because two forms can be open at once, and the dim must
    // not lift when only the first closes.

    private(set) var openFormCount = 0

    func formDidOpen() { openFormCount += 1 }
    func formDidClose() { openFormCount = max(0, openFormCount - 1) }

    // MARK: Diagnostics
    //
    // The error log has to be *fed*, or the support bundle ships an empty one and looks like a
    // feature while helping nobody — the same hollow shape as the settings that drove nothing.
    // Every failure that reaches `actionError` is recorded here as well.

    /// Capacity comes from the registry, so the cap the Settings screen shows is the cap that
    /// applies rather than a number the UI invents.
    ///
    /// `@ObservationIgnored` because `ErrorLog` is a thread-safe reference type that manages
    /// its own locking — putting it in the observation graph would invalidate views on every
    /// recorded error for no benefit. It also cannot be `lazy`: `@Observable` rejects that on
    /// stored properties.
    @ObservationIgnored let errorLog: ErrorLog

    /// Honours `diagnosticsEnabled`: with the log switched off, nothing is retained at all —
    /// not merely hidden from the bundle.
    func record(_ message: String, subsystem: String = "app") {
        guard settingsStore[SettingsKeys.diagnosticsEnabled] else { return }
        errorLog.record(.error, subsystem: subsystem, message: message)
    }

    /// Everything the builder needs about this build. `Bundle.main` is empty under
    /// `swift run`, so the fallbacks describe a development build rather than leaving blanks
    /// that read as missing data.
    private var appInfo: DiagnosticsSnapshot.AppInfo {
        DiagnosticsSnapshot.AppInfo(
            name: "Flotilla",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.melonfleet.Flotilla",
            mode: settingsStore[SettingsKeys.mode],
            isManaged: !settingsStore.lockedKeyNames().isEmpty
        )
    }

    /// Model identifier, never the serial or hardware UUID — those identify the machine and
    /// a support bundle must not.
    private var systemInfo: DiagnosticsSnapshot.SystemInfo {
        var model: String?
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [UInt8](repeating: 0, count: size)
            if sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 {
                // sysctl returns a NUL-terminated C string; drop the terminator before
                // decoding, or the trailing \0 ends up inside the Swift string.
                model = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsSnapshot.SystemInfo(
            osName: "macOS",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: Self.architecture,
            modelIdentifier: model
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// Assemble a support bundle. Throws `SupportBundleLeakError` if the final audit finds
    /// anything that must not leave the machine — deliberately a failure rather than a
    /// quietly-scrubbed file, so a redaction gap surfaces here instead of in someone's inbox.
    func makeSupportBundle() throws -> SupportBundle {
        try SupportBundleBuilder().build(
            at: Date(),
            app: appInfo,
            system: systemInfo,
            settings: settingsStore,
            preflight: preflight,
            errorLog: errorLog
        )
    }

    // MARK: Resets
    //
    // Three, and deliberately separate — `research/FEATURES.md`: *Reset preferences ≠ Forget
    // all hosts and trust ≠ Reset window layout*, and **never offer to delete container or
    // image data from a settings reset**. Someone whose window is stranded on a disconnected
    // display should not have to lose their preferences to recover it.
    //
    // Nothing here can reach the container runtime. These clear our own `UserDefaults` keys
    // and in-memory state; containers, images and volumes are owned by `container` and are not
    // ours to delete from a settings screen.

    /// Return every user-set preference to its built-in or managed default.
    func resetPreferences() {
        settingsStore.resetAll()
        SettingsPersistence.clearUserValues()
        reloadAppearance()
    }

    /// Forget saved window geometry. Takes effect on next launch — AppKit writes frames on
    /// close, so a window open right now would immediately save its position again.
    func resetWindowLayout() {
        SettingsPersistence.clearWindowState()
    }

    /// Whether there is any paired host or trust material to forget.
    ///
    /// False throughout Phase 1: there are no hosts and no Keychain identity yet. The control
    /// is shown anyway, disabled, rather than hidden — a reset that appears only once you have
    /// something to lose is one nobody discovers in time.
    var hasHostTrustToForget: Bool {
        !settingsStore[SettingsKeys.peerAllowlist].isEmpty
            || !settingsStore[SettingsKeys.trustAnchorFingerprints].isEmpty
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
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Skip a tick rather than queue behind one: if an action is in flight it
                // will refresh when it finishes, and a poll landing mid-action would fight
                // the optimistic state the row is showing.
                guard self.busy.isEmpty else { continue }
                await self.refresh()

                // Machines, images, volumes and networks on a **slower** cadence.
                //
                // They used to be refreshed only by their own section's `.task`, which meant
                // their create/delete events were recorded only while you happened to be looking
                // at them — so the Activity feed was inert for four of five kinds. That is a
                // feature that works exactly when you do not need it.
                //
                // Every sixth tick rather than every tick, because these change rarely and each
                // is a separate CLI invocation. At the default five-second interval that is
                // roughly every thirty seconds: fast enough that the feed and the sidebar counts
                // are honest, slow enough not to spawn four processes a second.
                tick += 1
                if tick % 6 == 0 {
                    await self.refreshMachines()
                    await self.refreshImages()
                    await self.refreshVolumes()
                    await self.refreshNetworks()
                }
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
        // The HOST sample is taken unconditionally, before the runtime guard. Machine CPU and
        // memory are true whether or not `container` is usable, and a dashboard that goes blank
        // because the runtime is down is least useful exactly when you are diagnosing why.
        hostMetrics.sample()

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
        await runPreflight(autoStartingService: true)
    }

    /// - Parameter autoStartingService: whether a stopped service should be started here.
    ///   False when called *by* `startRuntime`, which would otherwise recurse.
    func runPreflight(autoStartingService: Bool) async {
        let result = await Task.detached { [cli] in Preflight(cli: cli).run() }.value
        preflight = result

        // the owner's request, and the right default: a stopped service is the normal state after a
        // reboot, it is one command from working, and making the user find that command is
        // making them do the app's job. Attempted **once** per launch — an auto-start that fails
        // must not be retried on every reload, or a machine with a genuinely broken runtime
        // spawns a process every few seconds forever.
        if case .serviceStopped = result, autoStartingService, !autoStartAttempted {
            autoStartAttempted = true
            await startRuntime()
            return
        }

        if let reason = Self.unavailableReason(for: result) {
            state = .unavailable(reason)
        }
    }

    /// Whether an automatic start has already been tried this launch. The **button** is not
    /// gated by this: a manual retry is a new decision by the user.
    private var autoStartAttempted = false

    /// True while `container system start` is running, so the banner can say so. The CLI takes
    /// several seconds (it launches the API server, then waits for it to answer), which is long
    /// enough that silence reads as nothing happening.
    private(set) var startingRuntime = false

    /// Starts the `container` services, then re-checks and reloads.
    ///
    /// Recorded in the activity feed on success. An automatic side effect with no trace is
    /// indistinguishable from a mystery later.
    func startRuntime() async {
        guard !startingRuntime else { return }
        startingRuntime = true
        state = .loading
        do {
            try await Task.detached { [cli] in try cli.startSystem() }.value
            recordActivity(ContainerEvent(date: Date(), from: "stopped", to: "running",
                                          kind: .runtime, subject: hostLabel,
                                          action: "Runtime started"))
            startingRuntime = false
            await reload()
        } catch {
            startingRuntime = false
            // The CLI's own words. The likeliest real failure is a missing kernel, which we
            // deliberately do not install, and its message says exactly that.
            state = .unavailable("Couldn't start the `container` service — \(error)")
        }
    }

    /// Shared with `refreshVolumes`/`refreshNetworks`: they fail the same runtime check
    /// containers do, and repeating the diagnosis text in three places would let them drift.
    private static func unavailableReason(for result: PreflightResult) -> String? {
        switch result {
        case .ok:
            return nil
        case .missing:
            // Names where it looked. The previous message asserted "isn't installed" with no
            // evidence, and was **wrong** on a machine where the CLI was installed and running:
            // a GUI-launched app's PATH has no `/usr/local/bin`, so the search that backed the
            // claim could not have found it. A diagnosis the reader can check is worth more than
            // a shorter one.
            return "Apple's `container` CLI wasn't found in: "
                + Preflight.searchedDirectories().joined(separator: ", ")
        case .serviceStopped(_, _, let status):
            return "Apple's `container` service isn't running (\(status))."
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
    /// `internal`, not `private`, for the reason recorded on `cli`: Swift's same-file rule puts
    /// a `private` member out of reach of an extension in another file, and the last time that
    /// bit us the extension built its own `ContainerCLI` rather than sharing this one.
    var runtimeUsable: Bool {
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
            recordTransitions(previous: containers, current: fetched)

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

    /// When this section last loaded, for the toolbar's "Updated …" readout. Per-section
    /// rather than one shared timestamp: these refresh independently, and a single figure
    /// would claim the volumes list was as fresh as the containers list when it is not.
    private(set) var volumesLastRefresh: Date?
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
            // Appearance and disappearance are a volume's only events — see `recordExistence`.
            recordExistence(kind: .volume, previous: volumes.map(\.name),
                            current: fetched.map(\.name))
            volumes = fetched
            volumesState = .loaded
            volumesLastRefresh = Date()
        } catch {
            volumesState = .failed(String(describing: error))
        }
    }

    func createVolume(_ name: String, options: ContainerCLI.VolumeOptions = .init()) async {
        do {
            _ = try await Task.detached { [cli] in
                try cli.createVolume(name, options: options)
            }.value
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

    private(set) var networksLastRefresh: Date?
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
            recordExistence(kind: .network, previous: networks.map(\.id),
                            current: fetched.map(\.id))
            networks = fetched
            networksState = .loaded
            networksLastRefresh = Date()
        } catch {
            networksState = .failed(String(describing: error))
        }
    }

    func createNetwork(_ name: String, options: ContainerCLI.NetworkOptions) async {
        do {
            _ = try await Task.detached { [cli] in
                try cli.createNetwork(name, options: options)
            }.value
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

    private(set) var imagesLastRefresh: Date?
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
            // Keyed on `reference`, not `id`: a retag produces a new reference for the same
            // digest, and "nginx:mine created" is the event you want to see, not silence.
            recordExistence(kind: .image, previous: images.map(\.reference),
                            current: fetched.map(\.reference))
            images = fetched
            imagesState = .loaded
            imagesLastRefresh = Date()
        } catch {
            imagesState = .failed(String(describing: error))
        }
    }

    func pullImage(_ reference: String) async {
        do {
            _ = try await Task.detached { [cli] in try cli.pull(reference) }.value
            // Named explicitly: the existence diff would say "Created", which is true but loses
            // the distinction between an image you pulled and one a build produced.
            recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present",
                                          kind: .image, subject: reference, action: "Pulled"))
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

    // MARK: Files

    /// Raw `ls -la` for one directory inside a container. Off the main actor: this shells out.
    func listDirectory(_ path: String, in containerID: String) async throws -> String {
        try await Task.detached { [cli] in try cli.listDirectory(containerID, path: path) }.value
    }

    /// Copies a file out of a container to a path the user chose in a save panel.
    func download(_ containerPath: String, from containerID: String, to hostURL: URL) async throws {
        try await Task.detached { [cli] in
            try cli.copy(from: "\(containerID):\(containerPath)", to: hostURL.path)
        }.value
    }

    /// Copies a file from this Mac into a container. The same `container copy`, reversed —
    /// no separate mechanism, and still no network: this is local IPC to the runtime, not scp.
    func upload(_ hostURL: URL, to containerPath: String, in containerID: String) async throws {
        try await Task.detached { [cli] in
            try cli.copy(from: hostURL.path, to: "\(containerID):\(containerPath)")
        }.value
    }

    /// What we have actually **watched happen** to each container, newest first.
    ///
    /// The mockup's Recent Events card is fed "from local history (SwiftData)". There is no
    /// store, so this is the honest version of the same idea: the poll loop already compares
    /// the previous list against the new one to spot unexpected exits, and every state change
    /// it sees is recorded here as it happens. Nothing is inferred or backfilled — the card
    /// says so, because a timeline that begins when the app launched but looks like a complete
    /// history is a lie of omission.
    ///
    /// In memory and bounded. Persisting it needs a real store, which is a Phase 4 decision
    /// rather than something to bolt on here.
    /// **One** flat feed, newest first, covering every resource kind.
    ///
    /// This replaced two dictionaries — one for containers, one for machines — while images,
    /// volumes and networks recorded nothing at all. Three more dictionaries would have made the
    /// question "what has changed on this Mac?" harder to answer, not easier: the Activity
    /// section needs a single ordered list, and the per-subject lists the detail views want are a
    /// filter over it. One store, several views.
    ///
    /// Observable, not `@ObservationIgnored`. The dashboard card got away with being ignored
    /// because it rebuilds whenever `containers` changes anyway; the activity strips must update
    /// on their own. It is only written when something actually happened, so it does not churn.
    ///
    /// In memory and bounded. Persisting it needs a real store, which is a Phase 4 decision
    /// rather than something to bolt on here.
    ///
    /// Not `private(set)` — Swift's access control is per-file, and `AppModelMachines.swift`
    /// appends to it.
    var activity: [ContainerEvent] = []

    /// How many entries the feed keeps. Higher than the old per-subject cap of 50 because this
    /// is now shared by every subject on the machine, and a busy poll of a dozen containers
    /// would otherwise push a machine restart off the end within minutes.
    static let activityLimit = 500

    func events(for subject: String) -> [ContainerEvent] {
        activity.filter { $0.subject == subject }
    }

    func events(ofKind kind: ActivityKind) -> [ContainerEvent] {
        activity.filter { $0.kind == kind }
    }

    /// Appends to the feed, newest first, and trims.
    func recordActivity(_ event: ContainerEvent) {
        activity.insert(event, at: 0)
        if activity.count > Self.activityLimit {
            activity.removeLast(activity.count - Self.activityLimit)
        }
    }

    /// Notes a resource appearing or disappearing between two polls.
    ///
    /// Images, volumes and networks have no lifecycle to transition through — they exist or they
    /// do not — so appearance and disappearance *are* their events. The first-sighting rule still
    /// applies in one direction only: `previous.isEmpty` means this is the initial load, and
    /// announcing every pre-existing image as "created" would fill the feed with noise about
    /// nothing having happened.
    func recordExistence(kind: ActivityKind, previous: [String], current: [String]) {
        guard !previous.isEmpty else { return }
        let before = Set(previous), after = Set(current)
        for added in after.subtracting(before).sorted() {
            recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present",
                                          kind: kind, subject: added, action: "Created"))
        }
        for removed in before.subtracting(after).sorted() {
            recordActivity(ContainerEvent(date: Date(), from: "present", to: "absent",
                                          kind: kind, subject: removed, action: "Deleted"))
        }
    }

    /// Records the transition and returns nothing — called from the poll loop, which is the
    /// only place that can see a *change* rather than a state.
    private func recordTransitions(previous: [Container], current: [Container]) {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.status.state) })
        for container in current {
            let now = container.status.state
            guard let was = before[container.id] else {
                // First sighting is not a transition. Recording "appeared" for every container
                // present at launch would fill the card with noise about nothing happening.
                continue
            }
            guard was.caseInsensitiveCompare(now) != .orderedSame else { continue }
            recordActivity(ContainerEvent(date: Date(), from: was, to: now,
                                          kind: .container, subject: container.id))
        }
    }


    /// Which detail tab each container was last showing, **for this run only**.
    ///
    /// the owner's rule, and it is a good one: reopening a container should return you to the tab
    /// you were on, but a restart should forget. So this is in memory and deliberately not in
    /// `SettingsStore` — a preference that survives a relaunch would make Flotilla open on
    /// Logs weeks later because of something you did once.
    ///
    /// `@ObservationIgnored` because the view seeds its own `@State` from this at init and
    /// writes back on change; making it observable would rebuild the detail view every time
    /// you switched tab, to tell it something it already knows.
    @ObservationIgnored var lastDetailTab: [String: DetailTab] = [:]

    // MARK: Machines
    //
    // A machine is the VM containers run inside — see `AppModelMachines.swift`.

    // Written by the `AppModelMachines.swift` extension, so these cannot be `private(set)` —
    // Swift's access control is per-file, not per-type. Plain `var`: `internal(set)` on an
    // internal property is redundant and the compiler says so.
    var machines: [ContainerMachine] = []
    var machinesState: LoadState = .idle
    var machinesLastRefresh: Date?
    var busyMachines: Set<String> = []

    /// **A second store, not a second namespace inside the first.**
    ///
    /// the CLI owner spotted this in `research/MACHINES-SPEC.md`: `TerminalSessionStore` is keyed by a
    /// plain `String`, and machine names and container names are different namespaces in
    /// `container` itself. A container called `web` and a machine called `web` would have shared
    /// one entry, so opening a shell in one could show or clobber the other's session state.
    ///
    /// Two instances rather than prefixed keys: the type is already generic over "a string key
    /// with sessions under it", so a second instance is free and cannot be got wrong. Encoding
    /// a namespace into the key would put the invariant in every call site instead of the type.
    @ObservationIgnored let machineTerminals = TerminalSessionStore()

    /// Which machine detail tab each machine was last showing, this run only — same rule and
    /// same reasoning as `lastDetailTab` for containers.
    @ObservationIgnored var lastMachineTab: [String: MachineDetailTab] = [:]

    /// Machine CPU, memory and network, read from the OS rather than the container runtime.
    /// See `HostMetricsSampler` — host and container metrics answer different questions and
    /// the dashboard shows both, labelled distinctly.
    @ObservationIgnored let hostMetrics = HostMetricsSampler()

    /// Retained history for one container, for the dashboard's charts and the detail sparkline.
    func statsHistory(for id: String) -> [StatsSampler.HistoryPoint] { sampler.history(for: id) }

    /// Live terminal sessions, owned here so they outlive any view.
    ///
    /// `@ObservationIgnored` on the reference — the store is itself `@Observable`, so views
    /// still react to shells opening and closing; what must not be tracked is this constant
    /// property, which never changes.
    @ObservationIgnored let terminals = TerminalSessionStore()

    // MARK: Requests from the menu bar
    //
    // The popover can *ask* for a screen; it cannot reach into the window's `@State` to set
    // one. These are one-shot requests the window consumes and clears, which keeps the
    // window's selection owned by the window while still letting "Settings…" and "Run…" in
    // the popover land somewhere real. Without them those rows would open a blank window and
    // look broken.

    /// A section the popover asked the window to show. Cleared by `MainWindowView`.
    var pendingSection: Section?
    /// Whether the popover asked for the Run sheet. Cleared by `ContainersView`.
    var pendingRunSheet = false

    func requestSection(_ section: Section) { pendingSection = section }
    /// Ask a section to open one item's detail screen.
    ///
    /// Carries the subject as well as the section, because "show me `web`" and "show me
    /// Containers" are different requests and the popover was only ever able to make the second.
    /// One-shot, like the other pending flags: consumed and cleared by whichever view honours it,
    /// so a rebuild does not reopen it.
    func requestDetail(kind: ActivityKind, subject: String) {
        pendingSection = kind.section
        pendingDetailSubject = subject
    }

    var pendingDetailSubject: String?

    /// Ask the Machines section to open its create form. Mirrors `requestRunSheet`.
    func requestMachineForm() {
        pendingSection = .machines
        pendingMachineForm = true
    }

    var pendingMachineForm = false

    func requestRunSheet() {
        // Run lives on the containers screen, so ask for both — otherwise the sheet would
        // open behind whatever section happened to be selected.
        pendingSection = .containers
        pendingRunSheet = true
    }

    /// This Mac's short host name, for the popover's "This Mac" heading.
    ///
    /// Trailing `.local` stripped: it is noise on every Mac on the network, and the point of
    /// the label is to tell two machines apart once Phase 2 has more than one.
    var hostName: String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    // MARK: Lifecycle actions

    /// Ids with an action in flight, so the UI can disable their controls rather than
    /// letting an impatient second click fire a duplicate stop.
    private(set) var busy: Set<Container.ID> = []
    /// Surfaced to the user; an action that fails must say so rather than looking like
    /// nothing happened.
    var actionError: String?

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
            // The poll loop cannot see this one: a restart of a running container ends running,
            // so there is no transition between refreshes. Record it here or it is invisible.
            if action == .restart {
                recordActivity(ContainerEvent(date: Date(), from: "running", to: "running",
                                              kind: .container, subject: id, action: "Restarted"))
            }
        } catch {
            let message = "\(Self.label(for: action)) failed for \(id): \(error)"
            actionError = message
            record(message, subsystem: "container.lifecycle")
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
                if action == .restart {
                    recordActivity(ContainerEvent(date: Date(), from: "running", to: "running",
                                                  kind: .container, subject: id,
                                                  action: "Restarted"))
                }
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
