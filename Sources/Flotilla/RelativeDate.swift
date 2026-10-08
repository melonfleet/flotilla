import Foundation

/// Parsing and display for the ISO-8601 date **strings** the `container` CLI returns.
///
/// `FlotillaCore` deliberately keeps these as strings — it decodes what the CLI actually sends
/// and does not invent a `Date` the payload does not contain — so every screen that wants to
/// show one has to parse it. Three of them had grown their own copy, and the copies had
/// drifted: the containers table showed "2 days ago", the cards showed "Created 2 days ago",
/// and the volumes list showed a raw `2026-07-30T23:18:31Z`.
///
/// The raw form is the one to be rid of. Age is the question you actually ask of a volume or a
/// container; a timestamp makes you do the subtraction yourself, and truncated in a narrow
/// column it wastes every character on the parts that never vary. The exact value stays
/// available as a tooltip, which is what `absolute` is for.
enum RelativeDate {

    /// Both spellings the CLI emits. `container` is inconsistent about fractional seconds
    /// between subcommands, and a parser that handles only one silently returns nil for the
    /// other — which renders as an em dash and looks like missing data rather than a bug.
    /// Built per call rather than cached in a `static let`. `ISO8601DateFormatter` is not
    /// `Sendable`, so a shared instance is a data race the compiler rightly refuses; these are
    /// cheap and this is display code on the main actor, not a hot loop.
    static func parse(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let strict = ISO8601DateFormatter()
        if let date = strict.date(from: iso) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)
    }

    /// "2 days ago", or an em dash when there is nothing to show.
    ///
    /// An em dash rather than an empty string, so "this has no date" and "this cell failed to
    /// render" do not look the same — the same rule the Ports column follows.
    static func relative(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    /// `prefix` + the relative age, e.g. `Created 2 days ago`. Falls back to a bare dash so a
    /// missing date never renders as a dangling label like "Created —".
    static func relative(_ iso: String?, prefix: String) -> String {
        guard let date = parse(iso) else { return "—" }
        return "\(prefix) \(date.formatted(.relative(presentation: .named)))"
    }

    /// The full timestamp, for tooltips. Falls back to the raw string when it cannot be
    /// parsed: showing what the CLI said beats showing nothing when the two disagree.
    /// A `Date` we already hold, not an ISO string from the CLI — the activity strip's events
    /// are stamped in-process.
    static func relativeToNow(_ date: Date) -> String {
        // Built per call, not `static let`: `RelativeDateTimeFormatter` is not `Sendable`, the
        // same reason the ISO formatters here are built per call.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Wall-clock time only. The strip shows today's changes, so a full date would be noise on
    /// every row for information that never varies.
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func absolute(_ iso: String?) -> String {
        guard let iso else { return "Unknown" }
        guard let date = parse(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
