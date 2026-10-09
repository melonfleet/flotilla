import Foundation

/// Every Flotilla setting on a Mac — its value, where the value comes from, and what it does — for a
/// host page's Settings tab (the owner, 9 October): a table, and the same values as a property list
/// in the shape a configuration profile would carry them.
///
/// Settings marked `isSensitive` (the trusted fingerprints) are listed without their value, so the
/// report can travel to an admin and be copied without carrying them.
public struct SettingsReport: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public let name: String
        /// Nil for a sensitive setting.
        public let value: SettingValue?
        public let source: SettingSource
        public let summary: String
        public var id: String { name }

        public init(name: String, value: SettingValue?, source: SettingSource, summary: String) {
            self.name = name; self.value = value; self.source = source; self.summary = summary
        }

        /// How the table shows the value.
        public var displayValue: String {
            guard let value else { return "not shown" }
            switch value {
            case .bool(let flag): return flag ? "true" : "false"
            case .int(let number): return String(number)
            case .double(let number): return String(number)
            case .string(let text): return text.isEmpty ? "\"\"" : text
            case .stringArray(let list): return list.isEmpty ? "[]" : list.joined(separator: ", ")
            }
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// This Mac's settings, in registry order.
    public static func make(_ store: SettingsStore) -> SettingsReport {
        let values = store.effectiveValues()
        return SettingsReport(entries: SettingsRegistry.all.map { descriptor in
            Entry(name: descriptor.name,
                  value: descriptor.isSensitive ? nil : values[descriptor.name],
                  source: store.source(ofKeyNamed: descriptor.name) ?? .builtIn,
                  summary: descriptor.summary)
        })
    }

    /// The values as an XML property list, keys sorted — sensitive settings left out.
    public func propertyListXML() -> String {
        var dictionary: [String: Any] = [:]
        for entry in entries { if let value = entry.value { dictionary[entry.name] = value.plistObject } }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
