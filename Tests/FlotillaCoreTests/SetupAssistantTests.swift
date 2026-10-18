import Testing
@testable import FlotillaCore

/// The first-run setup assistant (option A, 13 October; `research/FIRST-RUN.md`).
@Suite struct SetupAssistantTests {
    @Test func fiveCountedStepsThenFinish() {
        #expect(SetupStep.allCases == [.welcome, .appearance, .greta, .prepare, .onlineChecks, .finish])
        #expect(SetupStep.counted.count == 5)
        #expect(SetupStep.welcome.progressLabel == "Step 1 of 5")
        #expect(SetupStep.onlineChecks.progressLabel == "Step 5 of 5")
        #expect(SetupStep.finish.number == nil)
        #expect(!SetupStep.finish.progressLabel.contains("of"))
    }

    @Test func continueTicksAndBackKeepsTheTicks() {
        var flow = SetupFlow()
        #expect(!flow.canGoBack)
        flow.advance()
        flow.advance()
        #expect(flow.step == .greta)
        #expect(flow.done == [.welcome, .appearance])
        flow.goBack()
        #expect(flow.step == .appearance)
        #expect(flow.done == [.welcome, .appearance], "going back doesn't un-answer a step")
    }

    @Test func backFromTheFirstStepGoesNowhere() {
        var flow = SetupFlow()
        flow.goBack()
        #expect(flow.step == .welcome)
    }

    @Test func finishIsTheEndOfTheLine() {
        var flow = SetupFlow()
        for _ in 0..<10 { flow.advance() }
        #expect(flow.step == .finish)
        #expect(flow.isFinished)
        #expect(Set(SetupStep.counted).isSubset(of: flow.done))
    }

    @Test func notNowOnlyWhereTheOfferIsOptional() {
        let ready = SetupContext(role: .client, needsContainer: false, gretaAvailable: true, helperOn: false)
        for step in SetupStep.allCases { #expect(!ready.offersNotNow(on: step), "\(step)") }

        let noContainer = SetupContext(role: .client, needsContainer: true, gretaAvailable: true, helperOn: false)
        #expect(noContainer.offersNotNow(on: .prepare))
        // Never the role, the look or the online checks: a global Skip would choose a role silently.
        #expect(!noContainer.offersNotNow(on: .welcome))
        #expect(!noContainer.offersNotNow(on: .appearance))
        #expect(!noContainer.offersNotNow(on: .onlineChecks))

        let noGreta = SetupContext(role: .client, needsContainer: false, gretaAvailable: false, helperOn: false)
        #expect(noGreta.offersNotNow(on: .greta))
    }

    @Test func aHostMaySkipTheHelperButNotBeingAHost() {
        let host = SetupContext(role: .host, needsContainer: true, gretaAvailable: true, helperOn: false)
        #expect(host.offersNotNow(on: .prepare))
        let helped = SetupContext(role: .host, needsContainer: true, gretaAvailable: true, helperOn: true)
        #expect(!helped.offersNotNow(on: .prepare), "a host with the helper has only Local Network, which isn't optional")
    }

    @Test func aHostIsNotAskedAboutAppUpdates() {
        let admin = SetupContext(role: .client, needsContainer: false, gretaAvailable: true, helperOn: false)
        let host = SetupContext(role: .host, needsContainer: false, gretaAvailable: true, helperOn: false)
        #expect(admin.onlineChecks == [.appUpdates, .suggestionsLibrary])
        #expect(host.onlineChecks == [.suggestionsLibrary])
    }

    @Test func eachOnlineCheckNamesWhatItContactsAndARealSetting() {
        for check in SetupOnlineCheck.allCases {
            #expect(!check.contacts.isEmpty)
            for host in check.contacts { #expect(check.detail.contains(host), "\(check) doesn't say it contacts \(host)") }
            #expect(SettingsRegistry.descriptor(named: check.settingName) != nil)
        }
    }

    @Test func gretaWording() {
        #expect(GretaAvailability.available.isAvailable)
        #expect(GretaAvailability.appleIntelligenceOff.offersSettings)
        #expect(!GretaAvailability.deviceNotEligible.offersSettings)
        // The mismatch first: it is the case that never clears by itself.
        let notReady = GretaAvailability.modelNotReady.message
        let language = try? #require(notReady.range(of: "language"))
        let automatic = try? #require(notReady.range(of: "automatically"))
        if let language, let automatic { #expect(language.lowerBound < automatic.lowerBound) }
        // Iris: the ineligible case no longer asserts a cause it can't know.
        #expect(!GretaAvailability.deviceNotEligible.message.contains("virtual machine"))
    }

    @Test func theChecklistDependsOnTheRole() {
        #expect(GetStartedItem.items(for: .client) == [.runContainer, .addHost, .trySuggestion])
        #expect(GetStartedItem.items(for: .host) == [.pairWithAdmin, .checkReachable, .runContainer])
    }

    @Test func theChecklistTicksFromRealStateOnly() {
        let fresh = GetStartedItem.Facts(containerCount: 0, hostCount: 0, adminCount: 0, listening: false)
        #expect(GetStartedItem.runContainer.isDone(fresh) == false)
        #expect(GetStartedItem.trySuggestion.isDone(fresh) == nil)
        #expect(!GetStartedItem.allDone(for: .client, fresh))

        let busyAdmin = GetStartedItem.Facts(containerCount: 2, hostCount: 1, adminCount: 0, listening: false)
        #expect(GetStartedItem.allDone(for: .client, busyAdmin), "an item nothing records doesn't hold the card open")
        #expect(!GetStartedItem.allDone(for: .host, busyAdmin))

        let pairedHost = GetStartedItem.Facts(containerCount: 1, hostCount: 0, adminCount: 1, listening: true)
        #expect(GetStartedItem.allDone(for: .host, pairedHost))
    }
}
