import Foundation
import Testing
@testable import FlotillaCore

// Covers the two-tier `defaults`/`locked` precedence rule (`DECISIONS.md` Q4) and the
// rest of the SettingsStore contract. `StaticManagedPreferences` is the injectable
// fake for the managed domain — real `CFPreferences` reading is the app layer's job
// and never happens in `FlotillaCore` (see `ManagedPreferences.swift`).

// MARK: - Precedence, every rung

@Test func builtInWinsWhenNothingElseIsSet() {
    let store = SettingsStore()
    #expect(store[SettingsKeys.pollIntervalSeconds] == 5)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .builtIn)
}

@Test func managedDefaultBeatsBuiltInWhenNoUserValue() {
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.pollIntervalSeconds.name: .int(20)])
    let store = SettingsStore(managed: managed)
    #expect(store[SettingsKeys.pollIntervalSeconds] == 20)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .managedDefault)
}

@Test func userValueBeatsManagedDefault() {
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.pollIntervalSeconds.name: .int(20)])
    let store = SettingsStore(managed: managed, userValues: [SettingsKeys.pollIntervalSeconds.name: .int(7)])
    #expect(store[SettingsKeys.pollIntervalSeconds] == 7)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .user)
}

@Test func userValueBeatsBuiltInWithNoManagedDomainAtAll() {
    let store = SettingsStore(userValues: [SettingsKeys.pollIntervalSeconds.name: .int(7)])
    #expect(store[SettingsKeys.pollIntervalSeconds] == 7)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .user)
}

@Test func lockedBeatsManagedDefault() {
    let managed = StaticManagedPreferences(
        defaults: [SettingsKeys.pollIntervalSeconds.name: .int(20)],
        locked: [SettingsKeys.pollIntervalSeconds.name: .int(1)]
    )
    let store = SettingsStore(managed: managed)
    #expect(store[SettingsKeys.pollIntervalSeconds] == 1)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .locked)
}

@Test func lockedBeatsBuiltInWithNoDefaultsSeed() {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.pollIntervalSeconds.name: .int(1)])
    let store = SettingsStore(managed: managed)
    #expect(store[SettingsKeys.pollIntervalSeconds] == 1)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .locked)
}

@Test func lockedBeatsUserValueEvenWhenUserWroteFirst() {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.pollIntervalSeconds.name: .int(99)])
    let store = SettingsStore(managed: managed, userValues: [SettingsKeys.pollIntervalSeconds.name: .int(7)])
    #expect(store[SettingsKeys.pollIntervalSeconds] == 99)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .locked)
}

// MARK: - `locked` really is immutable

@Test func lockedKeyRejectsUserWriteAndValueDoesNotChange() {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.logTailLines.name: .int(50)])
    let store = SettingsStore(managed: managed)

    #expect(store.isLocked(SettingsKeys.logTailLines))
    #expect(throws: SettingsError.locked(SettingsKeys.logTailLines.name)) {
        try store.set(999, for: SettingsKeys.logTailLines)
    }
    #expect(store[SettingsKeys.logTailLines] == 50)
    #expect(store.source(of: SettingsKeys.logTailLines) == .locked)
}

@Test func isLockedIsFalseForAManageableKeyWithNoLockedValue() {
    let store = SettingsStore()
    #expect(!store.isLocked(SettingsKeys.logTailLines))
}

@Test func isLockedIsFalseWhenTheLockedValueHasTheWrongShape() {
    // A locked payload of the wrong type/shape must not lock the key or apply —
    // `resolveLocked`/`isLocked` both gate on `descriptor.accepts`, so a corrupt or
    // stale managed payload degrades to "not locked", not a silent coercion.
    let managed = StaticManagedPreferences(locked: [SettingsKeys.pollIntervalSeconds.name: .string("nope")])
    let store = SettingsStore(managed: managed, userValues: [SettingsKeys.pollIntervalSeconds.name: .int(7)])

    #expect(!store.isLocked(SettingsKeys.pollIntervalSeconds))
    #expect(store[SettingsKeys.pollIntervalSeconds] == 7)
    #expect(store.source(of: SettingsKeys.pollIntervalSeconds) == .user)
}

@Test func lockedValueForAnEnumKeyMustBeOneOfTheDeclaredCases() throws {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.appearance.name: .string("rainbow")])
    let store = SettingsStore(managed: managed)

    #expect(!store.isLocked(SettingsKeys.appearance))
    #expect(store[SettingsKeys.appearance] == .notChosen)

    // A disallowed-but-unlocked value for an enum key is still writable by the user.
    try store.chooseAppearance(.dark)
    #expect(store.chosenAppearance == .dark)
}

// MARK: - `defaults` is only a seed

@Test func userCanOverrideAManagedDefaultAndTheOverrideSurvives() throws {
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.logTailLines.name: .int(50)])
    let store = SettingsStore(managed: managed)
    #expect(store[SettingsKeys.logTailLines] == 50)

    try store.set(300, for: SettingsKeys.logTailLines)
    #expect(store[SettingsKeys.logTailLines] == 300)
    #expect(store.source(of: SettingsKeys.logTailLines) == .user)

    // Still overridable a second time — a seed is not a one-shot.
    try store.set(400, for: SettingsKeys.logTailLines)
    #expect(store[SettingsKeys.logTailLines] == 400)
}

// MARK: - Unset and unknown keys

@Test func unsetKeysFallThroughToTheBuiltInDefault() {
    let store = SettingsStore()
    #expect(store[SettingsKeys.hostListenPort] == 7443)
    #expect(store[SettingsKeys.defaultRegistryDomain] == "docker.io")
    #expect(store.source(of: SettingsKeys.hostListenPort) == .builtIn)
}

@Test func unknownKeyNameIsRejectedOnWriteAndReadsAsNoSource() {
    let store = SettingsStore()
    #expect(throws: SettingsError.unknownKey("not.a.real.setting")) {
        try store.setRaw(.bool(true), forKeyNamed: "not.a.real.setting")
    }
    #expect(store.source(ofKeyNamed: "not.a.real.setting") == nil)
    #expect(!store.isLocked(keyNamed: "not.a.real.setting"))
    #expect(SettingsRegistry.descriptor(named: "not.a.real.setting") == nil)
}

// MARK: - Type safety

@Test func settingRawValueOfTheWrongKindIsRejectedNotCoerced() {
    let store = SettingsStore()
    #expect(throws: SettingsError.typeMismatch(
        key: SettingsKeys.pollIntervalSeconds.name, expected: .int, found: .string
    )) {
        try store.setRaw(.string("5"), forKeyNamed: SettingsKeys.pollIntervalSeconds.name)
    }
    // Unchanged — no partial or coerced write happened.
    #expect(store[SettingsKeys.pollIntervalSeconds] == 5)
}

@Test func settingAnEnumKeyToAnUndeclaredRawValueIsRejected() {
    let store = SettingsStore()
    #expect(throws: SettingsError.disallowedValue(key: SettingsKeys.appearance.name, value: "string(\"rainbow\")")) {
        try store.setRaw(.string("rainbow"), forKeyNamed: SettingsKeys.appearance.name)
    }
    #expect(store[SettingsKeys.appearance] == .notChosen)
}

@Test func doubleKeyAcceptsAWholeIntButNotAnArbitraryString() throws {
    // `Double.init(settingValue:)` deliberately widens `.int` (a plist/JSON `5` for a
    // Double key is unambiguous) but must not accept a non-numeric string.
    #expect(Double(settingValue: .int(5)) == 5.0)
    #expect(Double(settingValue: .string("5")) == nil)
}

// MARK: - Export / import round trip; reset

@Test func exportOmitsSensitiveKeysAndImportRoundTripsTheRest() throws {
    let store = SettingsStore()
    try store.set(42, for: SettingsKeys.pollIntervalSeconds)
    try store.set(777, for: SettingsKeys.logTailLines)
    try store.set(["deadbeef"], for: SettingsKeys.peerAllowlist) // isSensitive: true

    let exported = store.export(.userValues)
    #expect(exported.values[SettingsKeys.pollIntervalSeconds.name] == .int(42))
    #expect(exported.values[SettingsKeys.logTailLines.name] == .int(777))
    #expect(exported.values[SettingsKeys.peerAllowlist.name] == nil)

    let data = try store.exportJSON(.userValues)
    let fresh = SettingsStore()
    let report = try fresh.importJSON(data)

    #expect(report.applied.sorted() == [SettingsKeys.logTailLines.name, SettingsKeys.pollIntervalSeconds.name].sorted())
    #expect(report.unknown.isEmpty)
    #expect(report.typeMismatched.isEmpty)
    #expect(report.rejectedValues.isEmpty)
    #expect(report.skippedLocked.isEmpty)
    #expect(!report.hasProblems)
    #expect(fresh[SettingsKeys.pollIntervalSeconds] == 42)
    #expect(fresh[SettingsKeys.logTailLines] == 777)
    // Never round-tripped — the sensitive key simply isn't in the file.
    #expect(fresh[SettingsKeys.peerAllowlist] == [])
}

@Test func importSkipsLockedKeysAndReportsThem() throws {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.logTailLines.name: .int(1)])
    let store = SettingsStore(managed: managed)
    let export = SettingsExport(contents: .userValues, values: [SettingsKeys.logTailLines.name: .int(999)])

    let report = store.import(export)
    #expect(report.skippedLocked == [SettingsKeys.logTailLines.name])
    #expect(report.applied.isEmpty)
    #expect(store[SettingsKeys.logTailLines] == 1)
}

@Test func importReportsUnknownAndTypeMismatchedKeysWithoutFailingTheWholeImport() throws {
    let store = SettingsStore()
    let export = SettingsExport(contents: .userValues, values: [
        "not.a.real.setting": .bool(true),
        SettingsKeys.pollIntervalSeconds.name: .string("nope"),
        SettingsKeys.logTailLines.name: .int(300),
    ])

    let report = store.import(export)
    #expect(report.unknown == ["not.a.real.setting"])
    #expect(report.typeMismatched == [SettingsKeys.pollIntervalSeconds.name])
    #expect(report.applied == [SettingsKeys.logTailLines.name])
    #expect(store[SettingsKeys.logTailLines] == 300)
    #expect(store[SettingsKeys.pollIntervalSeconds] == 5) // untouched, falls to built-in
}

@Test func resettingASingleKeyRestoresTheManagedSeedNotJustTheBuiltIn() throws {
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.logTailLines.name: .int(50)])
    let store = SettingsStore(managed: managed)
    try store.set(300, for: SettingsKeys.logTailLines)
    #expect(store[SettingsKeys.logTailLines] == 300)

    store.reset(SettingsKeys.logTailLines)
    #expect(store[SettingsKeys.logTailLines] == 50) // back to the admin's seed, not 200
    #expect(store.source(of: SettingsKeys.logTailLines) == .managedDefault)
}

@Test func resetAllClearsUserValuesButNeverTouchesTheManagedDomain() throws {
    let managed = StaticManagedPreferences(
        defaults: [SettingsKeys.logTailLines.name: .int(50)],
        locked: [SettingsKeys.hostListenPort.name: .int(1)]
    )
    let store = SettingsStore(managed: managed)
    try store.set(300, for: SettingsKeys.logTailLines)
    try store.set(42, for: SettingsKeys.pollIntervalSeconds)

    store.resetAll()

    #expect(store.userValuesSnapshot().isEmpty)
    #expect(store[SettingsKeys.logTailLines] == 50) // managed seed survives
    #expect(store[SettingsKeys.pollIntervalSeconds] == 5) // built-in default
    // Locked values are a different tier entirely and were never in userValues.
    #expect(store.isLocked(SettingsKeys.hostListenPort))
    #expect(store[SettingsKeys.hostListenPort] == 1)
}

// MARK: - Appearance: "not yet chosen" vs "chose auto"

@Test func appearanceStartsAsNotChosenAndOnboardingIsNeeded() {
    let store = SettingsStore()
    #expect(store[SettingsKeys.appearance] == .notChosen)
    #expect(store.chosenAppearance == nil)
    #expect(store.needsAppearanceOnboarding)
    // Renders as auto before the question is answered, without counting as answered.
    #expect(store.effectiveAppearance == .auto)
}

@Test func choosingAutoIsDistinctFromNotHavingChosenYet() throws {
    let store = SettingsStore()
    try store.chooseAppearance(.auto)

    #expect(store[SettingsKeys.appearance] == .auto)
    #expect(store.chosenAppearance == .auto)
    #expect(!store.needsAppearanceOnboarding)
    #expect(store.effectiveAppearance == .auto)
}

@Test func choosingLightOrDarkIsRememberedDistinctly() throws {
    let store = SettingsStore()
    try store.chooseAppearance(.dark)
    #expect(store.chosenAppearance == .dark)
    #expect(store.effectiveAppearance == .dark)
    #expect(!store.needsAppearanceOnboarding)

    try store.chooseAppearance(.light)
    #expect(store.chosenAppearance == .light)
}

@Test func aManagedAppearanceAnswersOnboardingWithoutAUserChoice() {
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.appearance.name: .string("dark")])
    let store = SettingsStore(managed: managed)

    #expect(store.chosenAppearance == .dark)
    #expect(!store.needsAppearanceOnboarding)
    #expect(store.source(of: SettingsKeys.appearance) == .managedDefault)
}

@Test func aLockedAppearanceCannotBeChangedByTheUser() {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.appearance.name: .string("light")])
    let store = SettingsStore(managed: managed)

    #expect(store.isLocked(SettingsKeys.appearance))
    #expect(store.chosenAppearance == .light)
    #expect(throws: SettingsError.locked(SettingsKeys.appearance.name)) {
        try store.chooseAppearance(.dark)
    }
    #expect(store.chosenAppearance == .light)
}

@Test func appearancePreferenceChosenAndEffectiveMatchTheDeclaredSemantics() {
    #expect(AppearancePreference.notChosen.chosen == nil)
    #expect(AppearancePreference.auto.chosen == .auto)
    #expect(AppearancePreference.light.chosen == .light)
    #expect(AppearancePreference.dark.chosen == .dark)
    #expect(AppearancePreference.notChosen.effective == .auto)
    #expect(!AppearancePreference.notChosen.isChosen)
    #expect(AppearancePreference.auto.isChosen)
    #expect(AppearancePreference.selectable == [.auto, .light, .dark])
}
