import Foundation
import Testing
@testable import FlotillaCore

/// DECISIONS Q39: what the helper checks before it installs `container` as root — against what
/// `pkgutil` really printed (Fixtures/CAPTURED.md).
@Suite("container package")
struct ContainerPackageTests {
    func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func applesPackagePasses() throws {
        let signature = PackageSignatureReport.parse(try fixture("pkgutil-check-signature-container-1.5.0", "txt"))
        #expect(signature.signedForDistribution && signature.notarized)
        #expect(signature.signer == ContainerRuntime.appleInstallerSigner)
        let info = ComponentPackageInfo.parse(try fixture("container-1.5.0-PackageInfo", "xml"))
        #expect(info == ComponentPackageInfo(identifier: "com.apple.container-installer", version: "1.5.0", installLocation: "/usr/local"))
        #expect(ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: "1.5.0", installedVersion: nil) == nil)
        #expect(ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: "1.5.0", installedVersion: "1.4.1") == nil)
    }

    @Test func anUnsignedOrOtherTeamsPackageIsRefused() throws {
        let info = ComponentPackageInfo.parse(try fixture("container-1.5.0-PackageInfo", "xml"))
        for name in ["pkgutil-check-signature-unsigned", "pkgutil-check-signature-other-team"] {
            let signature = PackageSignatureReport.parse(try fixture(name, "txt"))
            #expect(ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: "1.5.0",
                                                  installedVersion: nil) != nil, "\(name) was accepted")
        }
    }

    @Test func theWrongVersionOrADowngradeIsRefused() throws {
        let signature = PackageSignatureReport.parse(try fixture("pkgutil-check-signature-container-1.5.0", "txt"))
        let info = ComponentPackageInfo.parse(try fixture("container-1.5.0-PackageInfo", "xml"))
        #expect(ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: "1.4.1", installedVersion: nil) != nil)
        #expect(ContainerPackageCheck.problem(signature: signature, info: info, requestedVersion: "1.5.0", installedVersion: "1.6.0") != nil)
    }

    @Test func theInstalledVersionIsReadFromTheReceipt() throws {
        #expect(ContainerPackageCheck.receiptVersion(try fixture("pkgutil-pkg-info-container-1.5.0", "txt")) == "1.5.0")
        #expect(ContainerPackageCheck.receiptVersion("No receipt for 'com.apple.container-installer' found at '/'.") == nil)
    }

    @Test func thePackageURLIsApplesAndOnlyForAVersion() {
        #expect(ContainerRuntime.packageURL(version: "1.5.0")?.absoluteString
                == "https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg")
        #expect(ContainerRuntime.packageURL(version: "../evil") == nil)
        #expect(ContainerRuntime.packageURL(version: "1.5.0-rc1") == nil)
    }

    @Test func anUpgradeIsAutomaticOnlyWithNothingRunning() {
        #expect(RuntimeSetup.plan(installed: nil, expected: "1.5.0", runningContainers: 3) == .install)
        #expect(RuntimeSetup.plan(installed: "1.5.0", expected: "1.5.0", runningContainers: 0) == .nothing)
        #expect(RuntimeSetup.plan(installed: "1.4.1", expected: "1.5.0", runningContainers: 0) == .upgrade(automatic: true))
        #expect(RuntimeSetup.plan(installed: "1.4.1", expected: "1.5.0", runningContainers: 2) == .upgrade(automatic: false))
        #expect(RuntimeSetup.plan(installed: "1.6.0", expected: "1.5.0", runningContainers: 0) == .newer)
    }
}
