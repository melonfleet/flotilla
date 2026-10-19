import Testing
@testable import FlotillaCore

@Suite struct PluralTests {
    @Test func oneIsSingularAndEveryOtherCountIsPlural() {
        #expect(Plural.count(1, "machine") == "1 machine")
        #expect(Plural.count(0, "machine") == "0 machines")
        #expect(Plural.count(3, "machine") == "3 machines")
    }

    /// The irregular plural is given, never guessed: "registrys" is what a bare `+ "s"` writes.
    @Test func anIrregularPluralIsTakenAsGiven() {
        #expect(Plural.count(1, "registry", "registries") == "1 registry")
        #expect(Plural.count(2, "registry", "registries") == "2 registries")
        #expect(Plural.noun(2, "registry", "registries") == "registries")
    }
}
