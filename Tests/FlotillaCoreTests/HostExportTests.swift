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
}
