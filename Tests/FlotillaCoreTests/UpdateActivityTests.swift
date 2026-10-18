import Foundation
import Testing
@testable import FlotillaCore

@Suite struct UpdateActivityTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func wordingMatchesTheBrief() {
        #expect(UpdateStage.checking.text(for: .library) == "Checking for new suggestions…")
        #expect(UpdateStage.checking.text(for: .app) == "Checking for Flotilla updates…")
        #expect(UpdateStage.upToDate(nil).text(for: .app) == "Flotilla is up to date")
        #expect(UpdateStage.found("1.0 beta 5").text(for: .app) == "Flotilla 1.0 beta 5 is available")
        #expect(UpdateStage.upToDate("2026.10.18.1").text(for: .library) == "Suggestions up to date (2026.10.18.1)")
        #expect(UpdateStage.updated(version: "2026.10.18.1", count: 32).text(for: .library)
                == "Updated to 2026.10.18.1, 32 suggestions")
        #expect(UpdateStage.logos(done: 3, of: 32).text(for: .library) == "Downloading logos (3 of 32)…")
        #expect(UpdateStage.failed("Couldn't check: offline").text(for: .library) == "Couldn't check: offline")
    }

    @Test func stepsAreInProgressAndResultsAreNot() {
        let steps: [UpdateStage] = [.checking, .downloading(nil), .downloaded, .verifying, .extracting,
                                    .installing, .logos(done: 1, of: 2)]
        for step in steps { #expect(step.isInProgress) }
        let results: [UpdateStage] = [.found("2"), .upToDate(nil), .updated(version: "1", count: 1),
                                      .finished("x"), .failed("x")]
        for result in results { #expect(!result.isInProgress) }
        #expect(UpdateStage.failed("x").isFailure)
        #expect(!UpdateStage.upToDate(nil).isFailure)
    }

    @Test func aStepOutranksAResultAndTheNewestStepWins() {
        var activity = UpdateActivity()
        activity.report(.upToDate(nil), from: .app, at: t0)
        activity.report(.checking, from: .library, at: t0.addingTimeInterval(-3))
        #expect(activity.headline?.source == .library)
        #expect(activity.isBusy)
        activity.report(.verifying, from: .app, at: t0.addingTimeInterval(1))
        #expect(activity.headline?.stage == .verifying)
        activity.report(.upToDate(nil), from: .app, at: t0.addingTimeInterval(2))
        activity.report(.finished("done"), from: .library, at: t0.addingTimeInterval(3))
        #expect(!activity.isBusy)
        #expect(activity.headline?.text == "done")
    }

    @Test func resultsFadeAfterFiveSecondsButStepsDoNot() {
        var activity = UpdateActivity()
        activity.report(.upToDate(nil), from: .app, at: t0)
        activity.report(.checking, from: .library, at: t0)
        activity.expire(now: t0.addingTimeInterval(4.9))
        #expect(activity.stage(of: .app) != nil)
        activity.expire(now: t0.addingTimeInterval(5))
        #expect(activity.stage(of: .app) == nil)
        #expect(activity.stage(of: .library) == .checking)
        activity.report(.failed("x"), from: .library, at: t0.addingTimeInterval(100))
        activity.expire(now: t0.addingTimeInterval(106))
        #expect(activity.headline == nil)
    }

    @Test func clearRemovesOnlyThatSource() {
        var activity = UpdateActivity()
        activity.report(.checking, from: .app, at: t0)
        activity.report(.checking, from: .library, at: t0)
        activity.clear(.app)
        #expect(activity.stage(of: .app) == nil)
        #expect(activity.isBusy(.library))
    }
}
