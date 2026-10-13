import Testing
@testable import FlotillaCore

@Suite struct DiscoveryPolicyTests {
    @Test func freshAdminWaitsUntilHostsIsOpened() {
        #expect(!DiscoveryPolicy.shouldBrowse(isAdmin: true, trustedHostCount: 0, userOpenedHosts: false))
        #expect(DiscoveryPolicy.shouldBrowse(isAdmin: true, trustedHostCount: 0, userOpenedHosts: true))
    }

    @Test func adminWithTrustedHostsBrowsesAtLaunch() {
        #expect(DiscoveryPolicy.shouldBrowse(isAdmin: true, trustedHostCount: 1, userOpenedHosts: false))
    }

    @Test func hostOnlyMacNeverBrowses() {
        #expect(!DiscoveryPolicy.shouldBrowse(isAdmin: false, trustedHostCount: 3, userOpenedHosts: true))
    }
}
