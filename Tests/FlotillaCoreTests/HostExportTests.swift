import Foundation
import Testing
@testable import FlotillaCore

/// Hosts in a `.flotilla` file (DECISIONS Q34): claims to verify, never keys and never trust.
@Suite("Host export")
struct HostExportTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let mini = PeerFingerprint(bytes: Array(repeating: 0xAB, count: 32))!
    let vm = PeerFingerprint(bytes: Array(repeating: 0xCD, count: 32))!
    let waiting = PeerFingerprint(bytes: Array(repeating: 0xEF, count: 32))!

    func book() -> PeerBook {
        var book = PeerBook()
        book.pairConfirmed(mini, role: .host, details: PeerDetails(computerName: "mini-1"), at: now)
        book.setEndpoint(mini, .bonjour(name: "mini-1"))
        book.pairConfirmed(vm, role: .host, details: PeerDetails(computerName: "vm-2"), at: now)
        book.setEndpoint(vm, .address(host: "10.0.0.20", port: 7868))
        _ = book.requestEnrolment(waiting, role: .host, details: PeerDetails(computerName: "new-mac"), at: now)
        return book
    }

    func exported(_ selected: [PeerFingerprint]) -> ConfigurationExport.Result {
        var inputs = ConfigurationExport.Inputs()
        inputs.hosts = book().peers
        var selection = ConfigurationExport.Selection()
        selection.hosts = Set(selected.map(\.hex))
        return ConfigurationExport.build(inputs, selection: selection)
    }

    @Test func onlyChosenTrustedHostsAreWrittenWithWhereAndWhichKey() throws {
        let result = exported([mini, vm, waiting])
        // A host still waiting for approval is not trusted, so it is not exported.
        #expect(result.file.hosts.map(\.name) == ["mini-1", "vm-2"])
        #expect(result.file.hosts[0].bonjourName == "mini-1" && result.file.hosts[0].fingerprint == mini.hex)
        #expect(result.file.hosts[1].address == "10.0.0.20" && result.file.hosts[1].port == 7868)
        #expect(result.omissions.contains { $0.subject == "hosts" })
    }

    @Test func theFileCarriesNoTrustOrKeyAndReadsBack() throws {
        let data = try exported([mini, vm]).file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        for word in ["status", "approved", "trusted", "PRIVATE", "certificate", "secret"] {
            #expect(!text.contains(word), "file mentions \(word)")
        }
        let back = try ConfigurationFile.parse(data)
        #expect(back.hosts == exported([mini, vm]).file.hosts)
    }

    @Test func aFileWithoutHostsIsUnchanged() throws {
        let data = try ConfigurationFile().encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("hosts"))
    }

    @Test func aBadHostEntryIsRefused() throws {
        func parse(_ host: String) throws {
            _ = try ConfigurationFile.parse(Data(#"{"version": 2, "hosts": [\#(host)]}"#.utf8))
        }
        #expect(throws: ConfigurationFileError.self) {
            try parse(#"{"name": "mini", "bonjourName": "mini", "fingerprint": "abc"}"#)
        }
        #expect(throws: ConfigurationFileError.self) {
            try parse(#"{"name": "mini", "address": "evil.host/path", "port": 7868, "fingerprint": "\#(mini.hex)"}"#)
        }
        #expect(throws: ConfigurationFileError.self) {
            try parse(#"{"name": "mini", "fingerprint": "\#(mini.hex)"}"#)
        }
        #expect(throws: ConfigurationFileError.self) {
            try parse(#"{"name": "mini", "bonjourName": "mini", "fingerprint": "\#(mini.hex)", "trusted": true}"#)
        }
    }

    @Test func importSkipsAHostAlreadyKnownAndAddsANewOne() throws {
        let file = exported([mini, vm]).file
        var existing = ConfigurationImport.Existing()
        existing.hosts = [mini.hex]
        let items = ConfigurationImport.items(file, existing: existing)
        let hostItems = items.filter { $0.kind == .host }
        #expect(hostItems.count == 2 && hostItems.allSatisfy { !$0.canRename && !$0.canReplace })
        let resolutions = ConfigurationImport.initialResolutions(items)
        #expect(ConfigurationImport.problems(items, resolutions: resolutions, existing: existing).isEmpty)
        let resolved = ConfigurationImport.resolve(file, resolutions: resolutions, existing: existing)
        #expect(resolved.hosts.map(\.fingerprint) == [vm.hex])
    }

    @Test func twoHostsWithOneNameAreTwoItems() throws {
        var file = ConfigurationFile()
        file.hosts = [HostSpec(name: "Mac mini", bonjourName: "Mac mini", fingerprint: mini.hex),
                      HostSpec(name: "Mac mini", bonjourName: "Mac mini (2)", fingerprint: vm.hex)]
        let items = ConfigurationImport.items(file, existing: .init())
        #expect(Set(items.map(\.id)).count == 2)
    }

    // MARK: Host categories (Q45)

    func categorised() -> (ConfigurationExport.Result, HostCategoryBook) {
        var categories = HostCategoryBook.starter
        let site = categories.categories[0], rack = categories.categories[1]
        categories.setValue("Doha", of: site.id, for: [mini.hex, "this-mac"])
        categories.setValue("R1", of: rack.id, for: [mini.hex])
        var inputs = ConfigurationExport.Inputs()
        inputs.hosts = book().peers
        inputs.hostCategories = categories
        var selection = ConfigurationExport.Selection()
        selection.hosts = [mini.hex, vm.hex]
        selection.hostCategories = true
        return (ConfigurationExport.build(inputs, selection: selection), categories)
    }

    @Test func categoriesTravelByNameWithTheHostsInTheFile() throws {
        let (result, _) = categorised()
        #expect(result.file.hostCategories == ["Site", "Rack", "VLAN"])
        let host = try #require(result.file.hosts.first { $0.fingerprint == mini.hex })
        #expect(host.categories == ["Site": "Doha", "Rack": "R1"])
        #expect(result.file.hosts.first { $0.fingerprint == vm.hex }?.categories == nil)
        // This Mac's own value stays behind, and the file says so.
        #expect(result.omissions.contains { $0.subject == "host categories" })
        let back = try ConfigurationFile.parse(try result.file.encoded())
        #expect(back == result.file)
    }

    @Test func categoriesAreLeftOutUnlessTicked() throws {
        var inputs = ConfigurationExport.Inputs()
        inputs.hosts = book().peers
        inputs.hostCategories = .starter
        var selection = ConfigurationExport.Selection()
        selection.hosts = [mini.hex]
        let file = ConfigurationExport.build(inputs, selection: selection).file
        #expect(file.hostCategories == nil)
        #expect(!String(decoding: try file.encoded(), as: UTF8.self).contains("ategories"))
    }

    @Test func importRefusesCategoriesItCannotTrust() throws {
        let host = #"{"name": "m", "bonjourName": "m", "fingerprint": "\#(mini.hex)""#
        let bad = [
            // A value in a category the file does not list.
            #"{"version": 2, "hostCategories": ["Site"], "hosts": [\#(host), "categories": {"Rack": "R1"}}]}"#,
            // The name Flotilla keeps for itself.
            #"{"version": 2, "hostCategories": ["Subnet"]}"#,
            // The same name twice.
            #"{"version": 2, "hostCategories": ["Rack", "rack"]}"#,
            // A value too long.
            #"{"version": 2, "hostCategories": ["Site"], "hosts": [\#(host), "categories": {"Site": "\#(String(repeating: "x", count: 61))"}}]}"#,
        ]
        for text in bad {
            #expect(throws: ConfigurationFileError.self) { _ = try ConfigurationFile.parse(Data(text.utf8)) }
        }
        let good = #"{"version": 2, "hostCategories": ["Site"], "hosts": [\#(host), "categories": {"Site": "Doha"}}]}"#
        #expect(try ConfigurationFile.parse(Data(good.utf8)).hosts.first?.categories == ["Site": "Doha"])
    }

    @Test func aSkippedHostTakesItsValuesWithIt() throws {
        let (result, _) = categorised()
        var existing = ConfigurationImport.Existing()
        existing.hosts = [mini.hex]
        let items = ConfigurationImport.items(result.file, existing: existing)
        let resolved = ConfigurationImport.resolve(result.file, resolutions: ConfigurationImport.initialResolutions(items),
                                                   existing: existing)
        #expect(resolved.hosts.map(\.fingerprint) == [vm.hex])
        #expect(resolved.hostCategories == ["Site", "Rack", "VLAN"])
    }
}
