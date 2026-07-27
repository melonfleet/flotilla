import Foundation

// The storage type for every setting. Deliberately a closed set of plist-compatible
// primitives: a setting has to survive a round trip through a macOS managed-preferences
// plist (`/Library/Managed Preferences/dev.melonfleet.Flotilla.plist`), a JSON export,
// and eventually a Wire message. Anything richer than this belongs in SwiftData, not
// in the settings registry.

public enum SettingValue: Sendable, Equatable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])

    /// The declared shape of a key, used to reject type-mismatched managed or
    /// imported values instead of silently coercing them.
    public var kind: SettingKind {
        switch self {
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .stringArray: .stringArray
        }
    }
}

public enum SettingKind: String, Codable, Sendable, CaseIterable {
    case bool, int, double, string, stringArray
}

// Encoded as the bare JSON value (`true`, `5`, `"auto"`, `["a"]`) rather than a
// tagged wrapper, so an exported settings file reads like a plist and can be pasted
// straight into a Jamf Custom Settings payload.
extension SettingValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Order matters: Bool before Int, Int before Double, so `true` never
        // becomes 1 and `5` never becomes 5.0.
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String].self) { self = .stringArray(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported setting value; expected Bool, Int, Double, String or [String]."
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .stringArray(let v): try c.encode(v)
        }
    }
}

// MARK: - Typed bridging

/// A Swift type that can be stored in the settings registry. Conformance is what
/// keeps `SettingsKey<T>` typed end to end: there is no `store.string(forKey:)`
/// anywhere, so a typo in a key name is a compile error rather than a silent default.
public protocol SettingRepresentable: Sendable, Equatable {
    init?(settingValue: SettingValue)
    var settingValue: SettingValue { get }
    /// Declared shape, used by the registry descriptor and by import validation.
    static var settingKind: SettingKind { get }
    /// Non-nil for enum-backed settings; drives pickers and managed-value validation.
    static var allowedRawValues: [String]? { get }
}

extension SettingRepresentable {
    public static var allowedRawValues: [String]? { nil }
}

extension Bool: SettingRepresentable {
    public init?(settingValue: SettingValue) {
        guard case .bool(let v) = settingValue else { return nil }
        self = v
    }
    public var settingValue: SettingValue { .bool(self) }
    public static var settingKind: SettingKind { .bool }
}

extension Int: SettingRepresentable {
    public init?(settingValue: SettingValue) {
        guard case .int(let v) = settingValue else { return nil }
        self = v
    }
    public var settingValue: SettingValue { .int(self) }
    public static var settingKind: SettingKind { .int }
}

extension Double: SettingRepresentable {
    public init?(settingValue: SettingValue) {
        // A plist/JSON `5` for a Double key is unambiguous, so widen it.
        switch settingValue {
        case .double(let v): self = v
        case .int(let v): self = Double(v)
        default: return nil
        }
    }
    public var settingValue: SettingValue { .double(self) }
    public static var settingKind: SettingKind { .double }
}

extension String: SettingRepresentable {
    public init?(settingValue: SettingValue) {
        guard case .string(let v) = settingValue else { return nil }
        self = v
    }
    public var settingValue: SettingValue { .string(self) }
    public static var settingKind: SettingKind { .string }
}

extension Array: SettingRepresentable where Element == String {
    public init?(settingValue: SettingValue) {
        guard case .stringArray(let v) = settingValue else { return nil }
        self = v
    }
    public var settingValue: SettingValue { .stringArray(self) }
    public static var settingKind: SettingKind { .stringArray }
}

/// String-backed enums get storage for free, and expose their cases so the UI can
/// build a picker from the registry instead of hardcoding a second copy of the list.
public protocol SettingEnum: SettingRepresentable, RawRepresentable, CaseIterable
where RawValue == String {}

extension SettingEnum {
    public init?(settingValue: SettingValue) {
        guard case .string(let v) = settingValue, let parsed = Self(rawValue: v) else { return nil }
        self = parsed
    }
    public var settingValue: SettingValue { .string(rawValue) }
    public static var settingKind: SettingKind { .string }
    public static var allowedRawValues: [String]? { allCases.map(\.rawValue) }
}
