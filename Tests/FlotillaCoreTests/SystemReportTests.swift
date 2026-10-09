import Foundation
import Testing
@testable import FlotillaCore

// Against real output captured on the development Mac (Fixtures/system/README.md).

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/system"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct SystemReportTests {
    @Test func pmsetSettingsAndWhatKeepsTheMacAwake() throws {
        let settings = SystemReport.PowerSettings.parse(try fixture("pmset-g-macbook-ac"))
        #expect(settings.sleepMinutes == 0)
        #expect(settings.displaySleepMinutes == 10)
        #expect(settings.diskSleepMinutes == 10)
        #expect(settings.powerNap == true)
        #expect(settings.wakeOnNetwork == true)
        #expect(settings.autoRestart == nil)        // a laptop prints none
        #expect(settings.sleepPreventedBy == ["Claude", "powerd"])
    }

    @Test func remoteLoginAndScreenSharingFromLaunchd() throws {
        let list = try fixture("launchctl-print-disabled-system")
        #expect(SystemReport.serviceEnabled(SystemReport.remoteLoginLabel, in: list) == false)
        #expect(SystemReport.serviceEnabled(SystemReport.screenSharingLabel, in: list) == false)
        #expect(SystemReport.serviceEnabled("dev.melonfleet.Flotilla.helper", in: list) == true)
        #expect(SystemReport.serviceEnabled("com.example.absent", in: list) == nil)
        // A label that is a prefix of another must not match it.
        #expect(SystemReport.serviceEnabled("dev.melonfleet.Flotilla", in: list) == nil)
    }

    @Test func firewallStateFromCapturedOutput() throws {
        #expect(SystemReport.firewallEnabled(try fixture("socketfilterfw-getglobalstate-on")) == true)
        #expect(SystemReport.firewallEnabled("") == nil)
    }
}
