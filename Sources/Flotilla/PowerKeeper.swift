import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import AppKit
import FlotillaCore

/// When Flotilla keeps this Mac awake, and why (DECISIONS Q44, the owner, 9 October).
///
/// One macOS assertion — `PreventUserIdleSystemSleep`, named "Flotilla: <reasons>" so `pmset -g
/// assertions` and a host's System tab say exactly what holds it — taken while any reason is live
/// and released the moment none is. It stops idle sleep only: the display still sleeps, and closing
/// the lid, choosing Sleep or a battery emergency always win. Never `PreventSystemSleep`.
///
/// The reasons:
/// - **finite work** someone started that breaks if interrupted — updates, pulls, builds, image
///   transfers, `container` installs — for exactly as long as it runs (`keepingAwake`);
/// - **host mode**, while it is on and `keepAwakeAsHost` allows, so the admin can reach the Mac;
///   a laptop only on its power adapter, never on battery;
/// - **running containers**, only if the owner turned `keepAwakeWhileContainersRun` on; never on
///   battery either.
///
/// Live logs and open terminals do not keep a Mac awake (the owner's call). Nothing here needs the
/// Flotilla Helper or admin rights.
@MainActor @Observable
final class PowerKeeper {
    /// The reasons in force, for the menu bar's status line. Empty: Flotilla is not keeping it awake.
    private(set) var reasons: [String] = []
    /// What is on battery now; read again whenever the power source changes.
    private(set) var onBattery = false

    @ObservationIgnored private var work: [UUID: String] = [:]
    @ObservationIgnored private var standing: [String: Bool] = [:]
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var assertionName = ""
    @ObservationIgnored private var powerSourceLoop: CFRunLoopSource?
    /// Called when the power source changes, so standing reasons can be recomputed.
    @ObservationIgnored var onPowerSourceChange: (() -> Void)?

    /// Until when its admin asked this host to stay awake (`.keepAwake`, Q44's time-bounded lease).
    /// Kept across relaunches — an update relaunches Flotilla — and ended by itself at that time.
    private(set) var leaseUntil: Date?
    @ObservationIgnored private var leaseEnd: Task<Void, Never>?
    @ObservationIgnored var onLeaseChange: (() -> Void)?
    private static let leaseKey = "keepAwakeForAdminUntil"

    /// Starts, moves or (with nil) ends the admin's request.
    func setLease(until: Date?) {
        leaseEnd?.cancel()
        let live = until.flatMap { $0 > Date() ? $0 : nil }
        leaseUntil = live
        UserDefaults.standard.set(live?.timeIntervalSince1970, forKey: Self.leaseKey)
        if let live {
            leaseEnd = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, live.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                self.setLease(until: nil)
            }
        }
        onLeaseChange?()
    }

    /// The request a relaunch interrupted, if it has not run out.
    func restoreLease() {
        let stored = UserDefaults.standard.double(forKey: Self.leaseKey)
        setLease(until: stored > 0 ? Date(timeIntervalSince1970: stored) : nil)
    }

    init() {
        onBattery = Self.readOnBattery()
        // Battery ↔ adapter: a laptop host stops keeping awake the moment it is unplugged.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let keeper = Unmanaged<PowerKeeper>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                keeper.onBattery = PowerKeeper.readOnBattery()
                keeper.onPowerSourceChange?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceLoop = source
        }
    }

    /// Runs `operation` with this Mac kept awake for `reason`, released however it ends.
    func keepingAwake<T>(_ reason: String, _ operation: () async throws -> T) async rethrows -> T {
        let token = UUID()
        work[token] = reason
        apply()
        defer {
            work[token] = nil
            apply()
        }
        return try await operation()
    }

    /// The same, for work that ends in a `defer`: `let hold = power.begin("…"); defer { power.end(hold) }`.
    func begin(_ reason: String) -> UUID {
        let token = UUID()
        work[token] = reason
        apply()
        return token
    }

    func end(_ token: UUID) {
        work[token] = nil
        apply()
    }

    /// Turns a standing reason on or off: host mode, or running containers.
    func setStanding(_ reason: String, _ on: Bool) {
        guard standing[reason] != on else { return }
        standing[reason] = on
        apply()
    }

    private func apply() {
        var now = Array(Set(work.values)).sorted()
        now += standing.filter(\.value).map(\.key).sorted()
        reasons = now
        let name = "Flotilla: " + now.joined(separator: ", ")
        if now.isEmpty {
            release()
        } else if assertion == 0 || name != assertionName {
            // Re-created under the new name, so `pmset` always says what holds it now.
            release()
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
                == kIOReturnSuccess {
                assertion = id
                assertionName = name
            }
        }
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        assertionName = ""
    }

    nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

extension AppModel {
    /// The standing reasons, from the settings, the role and the power source (Q44). Recomputed when
    /// any of them changes, and when the containers do.
    func updateStandingPower() {
        let host = hostMode.isHost
        power.setStanding("host mode", host && settingsStore[SettingsKeys.keepAwakeAsHost] && !power.onBattery)
        let running = containers.contains(where: AppModel.isRunning)
        power.setStanding("running containers",
                          running && settingsStore[SettingsKeys.keepAwakeWhileContainersRun] && !power.onBattery)
        // The admin's request: on the adapter only, like every standing reason.
        power.setStanding("its admin's request", power.leaseUntil != nil && hostMode.isHost && !power.onBattery)
    }

    /// Battery changes, and waking up: after sleep every connection may be dead, so one deliberate
    /// refresh and a reconnect to every host rather than waiting for timers to notice.
    func startPowerPolicy() {
        power.onPowerSourceChange = { [weak self] in self?.updateStandingPower() }
        power.onLeaseChange = { [weak self] in self?.updateStandingPower() }
        power.restoreLease()
        updateStandingPower()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.reloadUnlessLoading()
                    await self.hostMode.refreshLiveStatus(force: true)
                }
            }
        }
    }
}
