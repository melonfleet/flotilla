import Foundation
import Testing
@testable import FlotillaCore

@Suite("Version skew")
struct VersionSkewTests {
    @Test func readsTheShapesThatArrive() {
        #expect(SoftwareVersion("1.5.0") == SoftwareVersion(major: 1, minor: 5, patch: 0))
        #expect(SoftwareVersion("v1.4.1") == SoftwareVersion(major: 1, minor: 4, patch: 1))
        #expect(SoftwareVersion("0.0.0 (304)") == SoftwareVersion(major: 0, minor: 0, patch: 0, build: 304))
        #expect(SoftwareVersion("1.5.0-rc1") == SoftwareVersion(major: 1, minor: 5, patch: 0))
        #expect(SoftwareVersion("2") == SoftwareVersion(major: 2, minor: 0, patch: 0))
        #expect(SoftwareVersion("dev") == nil)
        #expect(SoftwareVersion("") == nil)
    }

    @Test func theLargestDifferingPartIsTheLevel() {
        #expect(VersionSkew(this: "1.5.0", other: "1.5.0")?.level == .same)
        #expect(VersionSkew(this: "1.5.0", other: "1.5.2")?.level == .patch)
        let older = VersionSkew(this: "1.5.0", other: "1.4.1")
        #expect(older?.level == .minor && older?.otherIsOlder == true && older?.mayRefuseCommands == true)
        #expect(VersionSkew(this: "1.5.0", other: "2.0.0")?.otherIsOlder == false)
        #expect(VersionSkew(this: "1.5.0", other: "2.0.0")?.level == .major)
        #expect(VersionSkew(this: "1.5.0", other: "1.5.2")?.mayRefuseCommands == false)
    }

    @Test func buildsCountOnlyWhenBothSidesHaveOne() {
        let builds = VersionSkew(this: "0.0.0 (310)", other: "0.0.0 (304)")
        #expect(builds?.level == .build && builds?.otherIsOlder == true)
        // An older Flotilla that sent no build number cannot be placed against ours.
        #expect(VersionSkew(this: "0.0.0 (310)", other: "0.0.0")?.level == .same)
    }

    @Test func anUnknownSideSaysNothing() {
        #expect(VersionSkew(this: nil, other: "1.5.0") == nil)
        #expect(VersionSkew(this: "1.5.0", other: "dev") == nil)
    }
}
