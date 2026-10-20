import Foundation
import Testing
@testable import FlotillaCore

@Suite("Unified suggestions")
struct SuggestionCatalogueTests {
    private let catalogue = SuggestionCatalogue(library: .builtIn)

    @Test func tabsAndIdentities() {
        #expect(SuggestionTab.allCases.map(\.rawValue) == ["All", "Apps", "Stacks", "Volumes", "Networks", "Domains", "Machines", "Clusters"])
        #expect(Set(catalogue.items.map(\.id)).count == catalogue.items.count)
        #expect(catalogue.items.contains { $0.id == "library:postgres" })
        #expect(catalogue.items.contains { $0.id == "volumes:postgres" })
    }

    @Test func preservesTheSourcesAndTypedHandoffs() {
        #expect(catalogue.items.compactMap(\.libraryEntry) == SuggestionLibrary.builtIn.entries)
        #expect(catalogue.matching("", tab: .volumes) == VolumeSuggestion.catalogue.map(SuggestionItem.volume))
        #expect(catalogue.matching("", tab: .networks) == NetworkSuggestion.catalogue.map(SuggestionItem.network))
        #expect(catalogue.matching("", tab: .domains) == DNSSuggestion.catalogue.map(SuggestionItem.domain))
        #expect(catalogue.matching("", tab: .machines) == MachineSuggestion.catalogue.map(SuggestionItem.machine))
        #expect(catalogue.matching("", tab: .clusters) == ClusterSuggestion.catalogue.map(SuggestionItem.cluster))
        #expect(catalogue.matching("", tab: .apps).allSatisfy { $0.libraryEntry?.container != nil })
        #expect(catalogue.matching("", tab: .stacks).allSatisfy { $0.libraryEntry?.stackSuggestion != nil })
    }

    @Test func searchAndCountsSpanKinds() {
        let counts = catalogue.counts("postgres")
        #expect((counts[.apps] ?? 0) > 0)
        #expect((counts[.stacks] ?? 0) > 0)
        #expect(counts[.volumes] == 1)
        #expect(counts[.networks] == 0)
        #expect(counts[.all] == SuggestionTab.allCases.filter { $0 != .all }.reduce(0) { $0 + (counts[$1] ?? 0) })
        #expect(catalogue.matching("HOST-ONLY databases").map(\.id) == ["networks:backend"])
        #expect(catalogue.matching("alpine:3.22", tab: .machines).map(\.id) == ["machines:alpine"])
        #expect(catalogue.matching("203.0.113.113", tab: .domains).map(\.id) == ["domains:host"])
        #expect(catalogue.matching("/var/lib/mysql", tab: .volumes).map(\.id) == ["volumes:mysql"])
        #expect(catalogue.matching("", tab: .volumes, category: "Databases").isEmpty)
        #expect(!catalogue.matching("", tab: .apps, category: "Databases").isEmpty)
    }

    @Test func paletteUsesTheSameSearchWithoutChangingResourceScopes() {
        let items = catalogue.items
        let candidates = items.map {
            SearchBox.Candidate(title: $0.title, isCommand: false, scope: .suggestion, suggestion: $0)
        } + [SearchBox.Candidate(title: "backend", isCommand: false, scope: .network)]
        let found = SearchBox.results(for: "suggestion: host-only databases", among: candidates)
        #expect(found.commands.isEmpty)
        #expect(found.places.map { items[$0].id } == ["networks:backend"])
        #expect(SearchBox.results(for: "network: backend", among: candidates).places == [items.count])
        #expect(SearchBox.results(for: ">backend", among: candidates).isEmpty)
        #expect(SearchBox.results(for: "suggestion: postgres", among: candidates).places.count == catalogue.matching("postgres").count)
    }

    @Test func batchesKeepTheirExistingBoundaryAndHost() throws {
        let app = try #require(catalogue.matching("", tab: .apps).first)
        let stack = try #require(catalogue.matching("", tab: .stacks).first)
        let volume = SuggestionItem.volume(VolumeSuggestion.catalogue[0])
        let machine = SuggestionItem.machine(MachineSuggestion.catalogue[0])
        let remote = HostRef.peer(try #require(PeerFingerprint(bytes: Array(repeating: 0xAB, count: 32))))
        #expect(SuggestionCatalogue.canUseTogether([app, stack], on: .local))
        #expect(SuggestionCatalogue.canUseTogether([app, stack], on: remote))
        #expect(SuggestionCatalogue.canUseTogether([volume], on: remote))
        #expect(!SuggestionCatalogue.canUseTogether([app, volume], on: .local))
        #expect(!SuggestionCatalogue.canUseTogether([], on: .local))
        #expect(machine.supports(.local))
        #expect(!machine.supports(remote))
        #expect(!SuggestionCatalogue.canUseTogether([machine], on: remote))
    }

    @Test func prefilledFormsStartCleanAndReappearingDoesNotEraseEdits() {
        var tracker = FormEditTracker()
        let prefill = UnsavedForms.signature(["postgres-data", "10G", HostRef.local.token])
        let edited = UnsavedForms.signature(["my-data", "10G", HostRef.local.token])
        #expect(!tracker.isDirty(prefill))
        tracker.open(prefill)
        #expect(!tracker.isDirty(prefill))
        #expect(tracker.isDirty(edited))
        tracker.open(edited)
        #expect(tracker.isDirty(edited))
        #expect(!tracker.isDirty(prefill))
    }

}
