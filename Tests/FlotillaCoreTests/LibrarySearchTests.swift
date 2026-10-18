import Testing
@testable import FlotillaCore

/// Kamal, 18 October: "database" must find the Databases category, and licences must be searchable.
@Suite struct LibrarySearchTests {
    private let chroma = LibraryEntry(id: "chromadb", title: "Chroma", summary: "A vector store.",
                                      categories: ["AI & Machine Learning", "Databases"], kind: .container)
    private let pdf = LibraryEntry(id: "stirling-pdf", title: "Stirling PDF", summary: "PDF tools.",
                                   categories: ["Business & Office"], kind: .container,
                                   licenceNote: "Licensed under GPL-3.0-only, a copyleft licence.")

    @Test func aCategoryWordFindsItsEntries() {
        #expect(chroma.matches("database"))
        #expect(!pdf.matches("database"))
    }

    @Test func licencesAreSearchableInBothSpellings() {
        for word in ["licence", "license", "GPL", "copyleft"] { #expect(pdf.matches(word), "\(word)") }
        #expect(!chroma.matches("license"))
        #expect(chroma.matches("open source"))
    }

    @Test func everyWordMustMatchAndCaseDoesNot() {
        #expect(chroma.matches("VECTOR databases"))
        #expect(!chroma.matches("vector office"))
        #expect(chroma.matches(""))
    }
}
