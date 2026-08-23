import Foundation
import Testing
@testable import FlotillaCore

/// The delete decision is here rather than in the views because the app target has no test target,
/// and "does this destroy things without asking" should not be in the untested half.

@Test func bulkAlwaysConfirmsRegardlessOfThePreference() {
    // The point of deleting `confirmBulkActions`: there is no configuration that reaches this.
    for confirmsSingle in [true, false] {
        let policy = DeletePolicy(confirmsSingleDeletes: confirmsSingle)
        #expect(policy.requiresConfirmation(.bulk(count: 2)))
        #expect(policy.requiresConfirmation(.bulk(count: 47)))
        // Even a "bulk" selection of one, which is what a multi-select with a single row is.
        #expect(policy.requiresConfirmation(.bulk(count: 1)))
    }
}

@Test func singleDeletesFollowThePreferenceInBothDirections() {
    #expect(DeletePolicy(confirmsSingleDeletes: true).requiresConfirmation(.single))
    // The half that never worked: with the preference off, a single delete proceeds. Containers
    // and Machines used to confirm anyway, which made the switch a no-op on two of five screens.
    #expect(!DeletePolicy(confirmsSingleDeletes: false).requiresConfirmation(.single))
}

@Test func confirmationIsOnByDefaultInTheRegistry() {
    // The safe position has to be the default, and this is the assertion that would fail if the
    // registry default were ever flipped to false in passing.
    #expect(SettingsKeys.confirmDestructiveActions.defaultValue)
}

@Test func theBulkPreferenceIsGoneFromTheRegistry() {
    // A deleted setting that lingers in the descriptor list still shows up in the Settings UI and
    // the generated Jamf key list, so its absence is worth pinning rather than assuming.
    #expect(!SettingsRegistry.all.contains(where: { $0.name == "confirmBulkActions" }))
    #expect(SettingsRegistry.all.contains(where: { $0.name == "confirmDestructiveActions" }))
}

// MARK: - Settings honesty
//
// The registry half of the audit's largest finding. The app-layer half — "every available setting
// has a consumer" — is `Scripts/check-settings-consumers.sh`, because the consumers live in a target
// this test bundle cannot import.

@Test func unbuiltSettingsAreNeverOfferedToAnMDMProfile() {
    // An administrator pushing `hostListenPort` to a fleet would believe they had configured a
    // listener. There is no listener. Nobody at the keyboard is positioned to notice, which makes
    // this the worse half of the same problem.
    let advertised = Set(SettingsRegistry.manageable.map(\.name))
    for descriptor in SettingsRegistry.notBuilt {
        #expect(!advertised.contains(descriptor.name),
                "\(descriptor.name) is not built and must not appear in the managed payload")
    }
}

@Test func everyUnbuiltSettingSaysWhatIsMissing() {
    // The reason is shown to the user verbatim, so an empty or apologetic one is a bug. It must
    // name the absent thing.
    for descriptor in SettingsRegistry.notBuilt {
        let reason = descriptor.availability.unbuiltReason ?? ""
        #expect(reason.count > 20, "\(descriptor.name) needs a reason that explains itself")
    }
}

@Test func theKnownUnbuiltSetIsExactlyWhatWeThinkItIs() {
    // Pinned deliberately. A new setting arriving unwired should force a decision here rather than
    // joining a list nobody reads — and a setting that gets *built* should have to remove itself.
    #expect(Set(SettingsRegistry.notBuilt.map(\.name)) == [
        "mode", "hostListenPort", "bonjourEnabled", "identityKeychainLabel",
        "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUScheduledCheckInterval",
        "updateChannel",
    ])
}
