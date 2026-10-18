import Foundation
import Testing
@testable import FlotillaCore

@Suite struct HostGroupingTests {
    @Test func starterHasTheOwnersThreeAndSuggestionsSkipThem() {
        let book = HostCategoryBook.starter
        #expect(book.categories.map(\.name) == ["Site", "Rack", "VLAN"])
        #expect(!book.unusedSuggestions.contains("Rack") && book.unusedSuggestions.contains("Building"))
    }

    @Test func namesAreCheckedAndSubnetIsReserved() throws {
        var book = HostCategoryBook.starter
        #expect(book.problem(withName: "  ") != nil)
        #expect(book.problem(withName: "rack") != nil)
        #expect(book.problem(withName: "subnet") != nil)
        #expect(book.problem(withName: String(repeating: "x", count: 41)) != nil)
        let room = book.addCategory(named: " Room ")
        #expect(room?.name == "Room")
        let again = book.addCategory(named: "room")
        #expect(again == nil)
        let rack = try #require(book.categories.first { $0.name == "Rack" })
        let ownName = book.rename(rack.id, to: "rack")       // its own name, other case
        let taken = book.rename(rack.id, to: "Site")
        #expect(ownName && !taken)
    }

    @Test func valuesSurviveARenameAndGoWithTheirCategory() throws {
        var book = HostCategoryBook.starter
        let rack = try #require(book.categories.first { $0.name == "Rack" })
        book.setValue(" R1 ", of: rack.id, for: ["a", "b"])
        book.setValue("R2", of: rack.id, for: ["c"])
        #expect(book.value(of: rack.id, for: "a") == "R1")
        #expect(book.values(in: rack.id) == ["R1", "R2"])
        _ = book.rename(rack.id, to: "Cabinet")
        #expect(book.value(of: rack.id, for: "b") == "R1")
        book.renameValue("R1", to: "Rack 1", in: rack.id)
        #expect(book.values(in: rack.id) == ["R2", "Rack 1"])
        book.setValue("", of: rack.id, for: ["c"])
        #expect(book.value(of: rack.id, for: "c") == nil && book.values["c"] == nil)
        book.removeCategory(rack.id)
        #expect(book.values.isEmpty)
    }

    @Test func aValueForAnUnknownCategoryIsIgnored() {
        var book = HostCategoryBook.starter
        book.setValue("x", of: "nope", for: ["a"])
        #expect(book.values.isEmpty)
    }

    @Test func forgettingAHostDropsItsValues() throws {
        var book = HostCategoryBook.starter
        let site = try #require(book.categories.first)
        book.setValue("Doha", of: site.id, for: ["a", "b"])
        book.forgetHost("a")
        #expect(book.value(of: site.id, for: "a") == nil && book.value(of: site.id, for: "b") == "Doha")
    }

    @Test func movingCategories() {
        var book = HostCategoryBook.starter
        book.moveCategories(fromOffsets: [2], toOffset: 0)
        #expect(book.categories.map(\.name) == ["VLAN", "Site", "Rack"])
        book.moveCategories(fromOffsets: [0], toOffset: 3)
        #expect(book.categories.map(\.name) == ["Site", "Rack", "VLAN"])
    }

    @Test func bucketsSortNamedGroupsNaturallyAndPutNoValueLast() {
        let values = ["a": "R10", "b": "R2", "c": nil, "d": "R2"] as [String: String?]
        let buckets = HostGrouping.buckets(["a", "b", "c", "d"]) { values[$0] ?? nil }
        #expect(buckets.map(\.value) == ["R2", "R10", nil])
        #expect(buckets[0].hosts == ["b", "d"])
    }

    @Test func storageKeyRoundTrips() {
        for grouping in [HostGrouping.none, .subnet, .category("abc-1")] {
            #expect(HostGrouping(storageKey: grouping.storageKey) == grouping)
        }
        #expect(HostGrouping(storageKey: "garbage") == HostGrouping.none)
    }

    @Test func subnets() {
        #expect(HostGrouping.subnet(of: "10.20.4.17") == "10.20.4.0/24")
        #expect(HostGrouping.subnet(of: "10.20.5.17", prefix: 23) == "10.20.4.0/23")
        #expect(HostGrouping.subnet(ofCIDR: "192.168.1.9/16") == "192.168.0.0/16")
        #expect(HostGrouping.subnet(of: "fe80::1") == nil)
        #expect(HostGrouping.subnet(of: "300.1.1.1") == nil)
        #expect(HostGrouping.contains("10.20.4.0/23", "10.20.5.200"))
        #expect(!HostGrouping.contains("10.20.4.0/24", "10.20.5.200"))
        #expect(HostGrouping.prefixLength(ofMask: "255.255.254.0") == 23)
        #expect(HostGrouping.prefixLength(ofMask: "255.0.255.0") == nil)
    }

    @Test func bookRoundTripsThroughPropertyList() throws {
        var book = HostCategoryBook.starter
        book.setValue("Doha", of: book.categories[0].id, for: ["this-mac"])
        let data = try PropertyListEncoder().encode(book)
        #expect(try PropertyListDecoder().decode(HostCategoryBook.self, from: data) == book)
    }
}

@Suite struct HostCategorySymbolTests {
    @Test func oldBookWithoutSymbolsStillDecodes() throws {
        let data = Data(#"{"categories":[{"id":"site","name":"Site"},{"id":"custom","name":"Team"}],"values":{"host":{"site":"Doha"}}}"#.utf8)
        let book = try JSONDecoder().decode(HostCategoryBook.self, from: data)
        #expect(book.categories[0].symbol == nil)
        #expect(book.categories[0].resolvedSymbol == "building.2")
        #expect(book.categories[1].resolvedSymbol == HostCategory.defaultSymbol)
        #expect(book.value(of: "site", for: "host") == "Doha")
    }

    @Test func unknownSymbolFallsBackOnLoad() throws {
        let data = Data(#"{"id":"custom","name":"Team","symbol":"not.a.real.symbol"}"#.utf8)
        let category = try JSONDecoder().decode(HostCategory.self, from: data)
        #expect(category.symbol == HostCategory.defaultSymbol)
        #expect(category.resolvedSymbol == HostCategory.defaultSymbol)
    }

    @Test func defaultAndChosenSymbolsPersist() throws {
        var book = HostCategoryBook()
        let added = book.addCategory(named: "Team")
        let category = try #require(added)
        #expect(category.symbol == nil)
        #expect(category.resolvedSymbol == HostCategory.defaultSymbol)
        book.setSymbol("cloud", for: category.id)
        let data = try PropertyListEncoder().encode(book)
        let loaded = try PropertyListDecoder().decode(HostCategoryBook.self, from: data)
        #expect(loaded.categories[0].symbol == "cloud")
        #expect(loaded.categories[0].resolvedSymbol == "cloud")
        #expect(HostCategory(name: "sItE", symbol: "cloud").resolvedSymbol == "building.2")
        #expect(HostCategory(name: "Team", symbol: "bad").resolvedSymbol == HostCategory.defaultSymbol)
        for name in HostCategoryBook.suggestions + [HostCategoryBook.subnetName] {
            #expect(HostCategory.builtInSymbol(for: name) != nil)
        }
    }
}

#if canImport(AppKit)
import AppKit

extension HostCategorySymbolTests {
    @Test func everyOfferedAndBuiltInSymbolExists() {
        let symbols = Set(HostCategory.symbols + Array(HostCategory.builtInSymbols.values) + [HostCategory.defaultSymbol])
        #expect(HostCategory.symbols.count == 24)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing SF Symbol: \(symbol)")
        }
    }
}
#endif
