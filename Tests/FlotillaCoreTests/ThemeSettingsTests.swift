import Foundation
import Testing
@testable import FlotillaCore

// The theme pair (`design/THEMES.md`): six light themes and four dark, with a light choice and a
// dark choice stored separately so Auto can switch between them. The colours live in
// the app target; FlotillaCore only owns which theme is chosen, which is what a managed profile
// and an export need to agree on.

@Test func themesDefaultToTheLookTheAppShippedWith() {
    let store = SettingsStore()
    #expect(store[SettingsKeys.lightTheme] == .cantaloupe)
    #expect(store[SettingsKeys.darkTheme] == .flesh)
    #expect(store.source(of: SettingsKeys.lightTheme) == .builtIn)
    #expect(store.source(of: SettingsKeys.darkTheme) == .builtIn)
}

@Test func lightAndDarkThemesAreIndependent() throws {
    let store = SettingsStore()
    // The same four names exist in both slots. Choosing the dark Stripe must not touch the light one.
    try store.set(DarkTheme.stripe, for: SettingsKeys.darkTheme)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
    #expect(store[SettingsKeys.lightTheme] == .cantaloupe)

    try store.set(LightTheme.canary, for: SettingsKeys.lightTheme)
    #expect(store[SettingsKeys.lightTheme] == .canary)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
}

@Test func theSameThemeCanBeChosenForBoth() throws {
    let store = SettingsStore()
    try store.set(LightTheme.stripe, for: SettingsKeys.lightTheme)
    try store.set(DarkTheme.stripe, for: SettingsKeys.darkTheme)
    #expect(store[SettingsKeys.lightTheme] == .stripe)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
}

@Test func themesStoreTheirBrandTokenNotADisplayString() {
    // An exported profile should read `canaryHoneydew`, not "Canary Honeydew".
    #expect(LightTheme.canaryHoneydew.settingValue == .string("canaryHoneydew"))
    #expect(DarkTheme.flesh.settingValue == .string("flesh"))
    // Declaration order is picker order. Light has six; dark has four.
    #expect(LightTheme.allowedRawValues ==
            ["stripe", "flesh", "cantaloupe", "canary", "canaryHoneydew", "fleshHoneydew"])
    #expect(DarkTheme.allowedRawValues == ["stripe", "flesh", "cantaloupe", "canary"])
}

@Test func theFourSharedThemesKeepTheirStoredNamesInBothLists() {
    // A preference saved before the honeydew themes existed must still decode in either slot.
    for raw in ["stripe", "flesh", "cantaloupe", "canary"] {
        #expect(LightTheme(rawValue: raw) != nil)
        #expect(DarkTheme(rawValue: raw) != nil)
    }
}

@Test func aLightOnlyThemeIsRefusedForDarkAndDarkFallsBackToFlesh() throws {
    let store = SettingsStore()
    // The honeydew variants have no dark form. Writing one to the dark key must fail outright...
    for raw in ["canaryHoneydew", "fleshHoneydew"] {
        #expect(throws: SettingsError.self) {
            try store.setRaw(.string(raw), forKeyNamed: SettingsKeys.darkTheme.name)
        }
    }
    #expect(store[SettingsKeys.darkTheme] == .flesh)
    // ...and the light key takes them.
    try store.setRaw(.string("fleshHoneydew"), forKeyNamed: SettingsKeys.lightTheme.name)
    #expect(store[SettingsKeys.lightTheme] == .fleshHoneydew)
}

@Test func aManagedProfileNamingALightOnlyThemeForDarkIsIgnored() {
    // An administrator's typo, or a profile written for light, must not leave dark unresolvable.
    let managed = StaticManagedPreferences(defaults: [SettingsKeys.darkTheme.name: .string("canaryHoneydew")])
    let store = SettingsStore(managed: managed)
    #expect(store[SettingsKeys.darkTheme] == .flesh)
}

@Test func aRetiredOrUnknownThemeIsRejected() {
    let store = SettingsStore()
    // `rind` was a theme in the first draft and was replaced by `stripe` the same day; a stored
    // `rind` must not be accepted as if it still existed.
    #expect(throws: SettingsError.self) {
        try store.setRaw(.string("rind"), forKeyNamed: SettingsKeys.lightTheme.name)
    }
    #expect(throws: SettingsError.self) {
        try store.setRaw(.string("rainbow"), forKeyNamed: SettingsKeys.darkTheme.name)
    }
    #expect(store[SettingsKeys.lightTheme] == .cantaloupe)
    #expect(store[SettingsKeys.darkTheme] == .flesh)
}

@Test func aLockedThemeWinsOverTheUsersChoice() {
    let managed = StaticManagedPreferences(locked: [SettingsKeys.darkTheme.name: .string("stripe")])
    let store = SettingsStore(managed: managed,
                              userValues: [SettingsKeys.darkTheme.name: .string("cantaloupe")])
    #expect(store[SettingsKeys.darkTheme] == .stripe)
    #expect(store.isLocked(SettingsKeys.darkTheme))
    #expect(!store.isLocked(SettingsKeys.lightTheme))
}

@Test func bothThemeKeysAreRegisteredAndManageable() {
    let names = SettingsRegistry.manageable.map(\.name)
    #expect(names.contains("lightTheme"))
    #expect(names.contains("darkTheme"))
    #expect(SettingsRegistry.descriptor(named: "lightTheme") != nil)
    #expect(SettingsRegistry.descriptor(named: "darkTheme") != nil)
}

@Test func everyThemeHasADisplayTitle() {
    #expect(LightTheme.allCases.map(\.title) ==
            ["Stripe", "Flesh", "Cantaloupe", "Canary", "Canary Honeydew", "Flesh Honeydew"])
    #expect(DarkTheme.allCases.map(\.title) == ["Stripe", "Flesh", "Cantaloupe", "Canary"])
}
