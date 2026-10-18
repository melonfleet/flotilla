import Foundation
import FlotillaCore

/// What Flotilla's update checks are doing, for the status bar and the Updates pane to read.
/// Both updaters report here; this owns the one timer that lets a finished result fade.
@MainActor
@Observable
final class UpdateActivityCenter {
    private(set) var activity = UpdateActivity()
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Called with every report, in order; for tests to read the sequence of stages.
    @ObservationIgnored var observer: ((UpdateSource, UpdateStage) -> Void)?

    func report(_ stage: UpdateStage, from source: UpdateSource) {
        activity.report(stage, from: source)
        observer?(source, stage)
        scheduleExpiry()
    }

    func clear(_ source: UpdateSource) {
        activity.clear(source)
        scheduleExpiry()
    }

    /// Waits for the earliest result's own deadline, not five seconds from the latest report, so
    /// a stream of logo steps can't hold an old result up (Kyle, 18 October).
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let deadline = activity.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.1))
            guard !Task.isCancelled, let self else { return }
            activity.expire()
            scheduleExpiry()
        }
    }
}
