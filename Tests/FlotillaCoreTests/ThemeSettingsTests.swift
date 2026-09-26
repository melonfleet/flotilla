import Foundation
import Testing
@testable import FlotillaCore

// The theme pair (`design/THEMES.md`): four themes, the same four in light and dark, with a light
// choice and a dark choice stored separately so Auto can switch between them. The colours live in
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
    try store.set(ThemeName.stripe, for: SettingsKeys.darkTheme)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
    #expect(store[SettingsKeys.lightTheme] == .cantaloupe)

    try store.set(ThemeName.canary, for: SettingsKeys.lightTheme)
    #expect(store[SettingsKeys.lightTheme] == .canary)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
}

@Test func theSameThemeCanBeChosenForBoth() throws {
    let store = SettingsStore()
    try store.set(ThemeName.stripe, for: SettingsKeys.lightTheme)
    try store.set(ThemeName.stripe, for: SettingsKeys.darkTheme)
    #expect(store[SettingsKeys.lightTheme] == .stripe)
    #expect(store[SettingsKeys.darkTheme] == .stripe)
}

@Test func themesStoreTheirBrandTokenNotADisplayString() {
    // An exported profile should read `stripe`, not "Stripe" or a translation of it.
    #expect(ThemeName.stripe.settingValue == .string("stripe"))
    #expect(ThemeName.flesh.settingValue == .string("flesh"))
    // Declaration order is picker order, and both pickers offer all four.
    #expect(ThemeName.allowedRawValues == ["stripe", "flesh", "cantaloupe", "canary"])
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
    #expect(ThemeName.allCases.map(\.title) == ["Stripe", "Flesh", "Cantaloupe", "Canary"])
}
