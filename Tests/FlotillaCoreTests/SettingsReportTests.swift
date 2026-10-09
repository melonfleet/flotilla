import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SettingsReportTests {
    @Test func everySettingWithItsSourceAndNoSensitiveValue() throws {
        let store = SettingsStore()
        try store.set(42, for: SettingsKeys.pollIntervalSeconds)
        let report = SettingsReport.make(store)
        #expect(report.entries.count == SettingsRegistry.all.count)
        let poll = try #require(report.entries.first { $0.name == SettingsKeys.pollIntervalSeconds.name })
        #expect(poll.value == .int(42) && poll.source == .user && poll.displayValue == "42")
        let builtIn = try #require(report.entries.first { $0.name == SettingsKeys.statsPollIntervalSeconds.name })
        #expect(builtIn.source == .builtIn)
        for sensitive in SettingsRegistry.all where sensitive.isSensitive {
            let entry = try #require(report.entries.first { $0.name == sensitive.name })
            #expect(entry.value == nil && entry.displayValue == "not shown")
        }
    }

    @Test func propertyListCarriesValuesAndLeavesOutSensitiveOnes() throws {
        let store = SettingsStore()
        try store.set(42, for: SettingsKeys.pollIntervalSeconds)
        let report = SettingsReport.make(store)
        let xml = report.propertyListXML()
        #expect(xml.contains("<key>pollIntervalSeconds</key>"))
        #expect(xml.contains("<integer>42</integer>"))
        let parsed = try #require(try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
        for sensitive in SettingsRegistry.all where sensitive.isSensitive { #expect(parsed[sensitive.name] == nil) }
        // It survives the trip to the admin.
        let decoded = try JSONDecoder().decode(SettingsReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }
}
