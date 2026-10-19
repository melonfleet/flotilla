import Testing
import Foundation
@testable import FlotillaCore

/// The helper's states, wording and buttons (DECISIONS Q41, amended 19 October).
struct HelperHealthTests {
    private func health(_ registration: HelperRegistration, _ probe: HelperProbe = .notAsked) -> HelperHealth {
        HelperHealth.derive(registration: registration, probe: probe, current: 5)
    }

    @Test func registrationDecidesBeforeAnyProbe() {
        #expect(health(.unavailable, .answered(version: 5)) == .unavailable)
        #expect(health(.notInstalled, .answered(version: 5)) == .notInstalled)
        #expect(health(.awaitingApproval, .answered(version: 5)) == .needsApproval)
    }

    @Test func anApprovedHelperIsJudgedByWhatItAnswers() {
        #expect(health(.enabled) == .checking)
        #expect(health(.enabled, .silent) == .notAnswering)
        #expect(health(.enabled, .answered(version: 4)) == .outOfDate(running: 4, current: 5))
        #expect(health(.enabled, .answered(version: 5)) == .running(version: 5))
        #expect(health(.enabled, .answered(version: 6)) == .running(version: 6), "newer than the app is not stale")
    }

    @Test func theWordingAndTonesAreTheOnesKamalAsked() {
        #expect(health(.enabled, .answered(version: 5)).title == "Running (version 5)")
        #expect(health(.enabled, .answered(version: 5)).tone == .good)
        #expect(health(.enabled, .answered(version: 4)).title == "Out of date")
        #expect(health(.enabled, .silent).title == "Approved but not answering")
        #expect(health(.awaitingApproval).title == "Needs your approval")
        #expect(health(.notInstalled).tone == .bad)
        #expect(health(.unavailable).tone == .neutral)
        for state in [HelperHealth.outOfDate(running: 4, current: 5), .notAnswering, .needsApproval] {
            #expect(state.tone == .warning)
        }
    }

    @Test func installAndRemoveNeverShowTogether() {
        let all: [HelperHealth] = [.unavailable, .notInstalled, .needsApproval, .checking, .notAnswering,
                                   .outOfDate(running: 4, current: 5), .running(version: 5)]
        for state in all {
            let actions = state.actions
            #expect(!(actions.contains(.install) && actions.contains(.remove)), "\(state)")
        }
    }

    @Test func eachStateOffersWhatCanHelp() {
        #expect(HelperHealth.notInstalled.actions == [.install])
        #expect(HelperHealth.unavailable.actions.isEmpty)
        #expect(HelperHealth.needsApproval.actions.contains(.openLoginItems))
        #expect(HelperHealth.notAnswering.actions.contains(.restart))
        #expect(HelperHealth.notAnswering.actions.contains(.reinstall))
        #expect(HelperHealth.outOfDate(running: 4, current: 5).actions.contains(.restart))
        #expect(HelperHealth.running(version: 5).actions.contains(.restart))
        #expect(!HelperHealth.running(version: 5).actions.contains(.install))
    }

    @Test func onlyARunningHelperIsUsable() {
        #expect(health(.enabled, .answered(version: 5)).isUsable)
        #expect(!health(.enabled, .answered(version: 4)).isUsable)
        #expect(!health(.enabled, .silent).isUsable)
    }

    @Test func autoRegisterRespectsADeliberateRemove() {
        #expect(HelperAutoRegister.shouldRegister(registration: .notInstalled, removedByOwner: false))
        #expect(!HelperAutoRegister.shouldRegister(registration: .notInstalled, removedByOwner: true))
        #expect(!HelperAutoRegister.shouldRegister(registration: .unavailable, removedByOwner: false),
                "an unsigned build never registers")
        #expect(!HelperAutoRegister.shouldRegister(registration: .awaitingApproval, removedByOwner: false))
        #expect(!HelperAutoRegister.shouldRegister(registration: .enabled, removedByOwner: false))
    }

    @Test func aProbeIsTrustedForThirtySeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(!HelperProbeCache.isFresh(lastProbe: nil, now: now))
        #expect(HelperProbeCache.isFresh(lastProbe: now.addingTimeInterval(-29), now: now))
        #expect(!HelperProbeCache.isFresh(lastProbe: now.addingTimeInterval(-30), now: now))
        #expect(!HelperProbeCache.isFresh(lastProbe: now.addingTimeInterval(5), now: now), "a clock set back is stale")
    }
}
