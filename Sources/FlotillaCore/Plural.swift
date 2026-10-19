import Foundation

/// A count and the noun that follows it: "1 machine", "3 machines".
///
/// The app spelled this out by hand at every site, `n == 1 ? "" : "s"`, and the tooltip audit of
/// 19 October found four that had not bothered — "Start 1 machines", "Sign out of 1 registries",
/// "Show 1 containers", and a bare "Delete 3" with no noun at all. One spelling, in one place, with
/// the irregular plurals given rather than guessed.
public enum Plural {
    /// The noun for `count`: `singular` for exactly one, otherwise `plural`, or `singular + "s"`.
    public static func noun(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? singular + "s")
    }

    /// The count and its noun: "1 machine", "0 machines", "3 registries".
    public static func count(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count) \(noun(count, singular, plural))"
    }
}
