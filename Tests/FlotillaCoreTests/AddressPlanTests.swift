import Foundation
import Testing
@testable import FlotillaCore

@Suite("Address plan")
struct AddressPlanTests {
    @Test func readsAndWritesBlocks() {
        #expect(IPv4Block("10.240.16.0/20")?.description == "10.240.16.0/20")
        // Host bits are cleared, so an address with a prefix names its block.
        #expect(IPv4Block("192.168.65.4/24")?.description == "192.168.65.0/24")
        #expect(IPv4Block("10.0.0.1")?.prefix == 32)
        #expect(IPv4Block("10.0.0/24") == nil)
        #expect(IPv4Block("10.0.0.256/24") == nil)
        #expect(IPv4Block("10.0.0.0/33") == nil)
        #expect(IPv4Block("010.0.0.0/8") == nil)
        #expect(IPv4Block.prefix(ofMask: "255.255.240.0") == 20)
        #expect(IPv4Block.prefix(ofMask: "255.0.255.0") == nil)
    }

    @Test func overlapIsExact() {
        let block = IPv4Block("10.240.16.0/20")!
        #expect(block.overlaps(IPv4Block("10.240.31.0/24")!))
        #expect(!block.overlaps(IPv4Block("10.240.32.0/24")!))
        #expect(block.overlaps(IPv4Block("10.0.0.0/8")!))
        #expect(block.contains(IPv4Block("10.240.20.0/24")!))
    }

    @Test func eachMacGetsItsOwnBlockAndKeepsIt() {
        let first = AddressPlan.assign(["local", "mini"], existing: [:], avoid: [])
        #expect(first["local"]?.description == "10.240.0.0/20")
        #expect(first["mini"]?.description == "10.240.16.0/20")
        // A third Mac joins: the first two keep theirs.
        let second = AddressPlan.assign(["local", "mini", "vm"], existing: first, avoid: [])
        #expect(second["local"] == first["local"] && second["mini"] == first["mini"])
        #expect(second["vm"]?.description == "10.240.32.0/20")
    }

    @Test func aRangeInUseIsSkipped() {
        // This Mac's office LAN sits in the first block; a VPN covers the next.
        let plan = AddressPlan.assign(["local"], existing: [:],
                                      avoid: [IPv4Block("10.240.3.0/24")!, IPv4Block("10.240.16.0/21")!])
        #expect(plan["local"]?.description == "10.240.32.0/20")
    }

    @Test func aRemovedMacGivesItsBlockBack() {
        let plan = AddressPlan.assign(["local"], existing: ["local": IPv4Block("10.240.0.0/20")!,
                                                           "gone": IPv4Block("10.240.16.0/20")!], avoid: [])
        #expect(plan.keys.sorted() == ["local"])
    }

    @Test func networksTakeTheFirstFreeSlash24() {
        let block = IPv4Block("10.240.16.0/20")!
        #expect(AddressPlan.subnet(in: block, used: [])?.description == "10.240.16.0/24")
        #expect(AddressPlan.subnet(in: block, used: [IPv4Block("10.240.16.0/24")!,
                                                     IPv4Block("10.240.17.0/24")!])?.description == "10.240.18.0/24")
        let full = (0..<16).map { block.subblock($0, prefix: 24)! }
        #expect(AddressPlan.subnet(in: block, used: full) == nil)
    }
}
