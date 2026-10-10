import Foundation
import Testing
@testable import FlotillaCore

@Suite struct EnergyAdviceTests {
    @Test func aDesktopSetUpForHostingIsAllGood() {
        let inputs = EnergyAdvice.Inputs(power: .init(sleepMinutes: 0, wakeOnNetwork: true, autoRestart: true),
                                          hasBattery: false, fileVault: false, autoLogin: true, launchesAtLogin: true)
        let items = EnergyAdvice.items(inputs)
        #expect(items.map(\.id) == ["sleep", "wake", "restart", "login"])
        #expect(items.allSatisfy { $0.state == .good })
        #expect(EnergyAdvice.restartWarning(inputs) == nil)
    }

    @Test func theCapturedLaptopSettingsAreReadAsALaptop() throws {
        // pmset -g from the development Mac (Fixtures/system): a laptop that never sleeps on AC.
        let url = try #require(Bundle.module.url(forResource: "pmset-g-macbook-ac", withExtension: "txt",
                                                 subdirectory: "Fixtures/system"))
        let power = SystemReport.PowerSettings.parse(try String(contentsOf: url, encoding: .utf8))
        let items = EnergyAdvice.items(.init(power: power, hasBattery: true, launchesAtLogin: false))
        #expect(!items.contains { $0.id == "restart" })     // no such setting on a laptop
        #expect(items.first { $0.id == "sleep" }?.guide == .batteryLaptop)
        #expect(items.first { $0.id == "login" }?.state == .recommended)
    }

    @Test func whatIsMissingIsUnknownNotGood() {
        let items = EnergyAdvice.items(.init())
        #expect(items.allSatisfy { $0.state == .unknown })
    }

    @Test func aSleepingDesktopIsRecommendedAndSaysWhen() {
        let items = EnergyAdvice.items(.init(power: .init(sleepMinutes: 10), hasBattery: false))
        let sleep = items.first { $0.id == "sleep" }
        #expect(sleep?.state == .recommended && sleep?.detail?.contains("10 min") == true)
    }

    @Test func fileVaultOrNoAutoLoginWarnsThatFlotillaWaitsForASignIn() {
        #expect(EnergyAdvice.restartWarning(.init(fileVault: true, autoLogin: true))?.guide == .fileVault)
        #expect(EnergyAdvice.restartWarning(.init(fileVault: false, autoLogin: false))?.guide == .autoLogin)
        #expect(EnergyAdvice.restartWarning(.init(fileVault: nil, autoLogin: nil)) == nil)
    }
}
