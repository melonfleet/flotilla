import Foundation
import Testing
@testable import FlotillaCore

/// DECISIONS Q38: updating the fleet from the admin Mac.
@Suite("Fleet updates")
struct FleetUpdateTests {
    @Test func theBuildNumberIsReadFromAReportedVersion() {
        #expect(FleetUpdate.build(of: "0.0.0 (312)") == 312)
        #expect(FleetUpdate.build(of: "1.2.0 ( 400 )") == 400)
        #expect(FleetUpdate.build(of: "dev") == nil)
        #expect(FleetUpdate.build(of: nil) == nil)
    }

    @Test func aHostIsNeverUpdatedBackwards() {
        #expect(FleetUpdate.standing(host: 312, admin: 320) == .behind(312))
        #expect(FleetUpdate.standing(host: 320, admin: 320) == .current)
        #expect(FleetUpdate.standing(host: 330, admin: 320) == .ahead(330))
        #expect(FleetUpdate.standing(host: nil, admin: 320) == .unknown)
    }

    @Test func theRollingOrderSkipsWhatCannotOrShouldNotUpdate() {
        let hosts = [
            FleetUpdate.Candidate(id: "a", name: "studio", build: 310, connected: true, canReceive: true),
            FleetUpdate.Candidate(id: "b", name: "mini", build: 300, connected: false, canReceive: true),
            FleetUpdate.Candidate(id: "c", name: "vm", build: 305, connected: true, canReceive: false),
            FleetUpdate.Candidate(id: "d", name: "lab", build: 311, connected: true, canReceive: true, failedBuild: 320),
            FleetUpdate.Candidate(id: "e", name: "edge", build: 320, connected: true, canReceive: true),
        ]
        #expect(FleetUpdate.next(hosts, admin: 320)?.id == "a")
        // A failure on an older admin build does not block the next one.
        var retried = hosts
        retried[0].build = 320
        #expect(FleetUpdate.next(retried, admin: 321)?.id == "d")
        #expect(FleetUpdate.next(retried.filter { $0.id == "e" }, admin: 320) == nil)
    }

    @Test func anUpdateNeedsVersionSix() {
        #expect(WireMessage.UploadPurpose.appUpdate.minimumVersion == 6)
        #expect(WireMessage.UploadPurpose.imageLoad.minimumVersion == 2)
    }
}
