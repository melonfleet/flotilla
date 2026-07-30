import Foundation

/// Pretty-prints arbitrary JSON text for the inspect tab's raw view (`FEATURES.md`: "Pretty
/// JSON + friendly summary"). Keys are sorted so the tab does not visually reshuffle between
/// refreshes just because the CLI happened to emit keys in a different order.
public enum JSONPrettyPrinter {
    /// Re-serialises `text` with sorted keys and indentation. A diagnostics view must never
    /// be the thing that crashes, so malformed input — not valid JSON, or valid JSON that
    /// round-trips through `JSONSerialization` into something no longer encodable, such as
    /// `NaN`/`Infinity` from a permissive parse — is returned unchanged rather than thrown.
    public static func prettyPrint(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
              ),
              let prettyText = String(data: pretty, encoding: .utf8)
        else {
            return text
        }
        return prettyText
    }
}
