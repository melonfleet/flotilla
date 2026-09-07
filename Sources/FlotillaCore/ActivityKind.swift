import Foundation

/// The kind of thing an event, or an in-flight action, belongs to.
///
/// Deliberately not derived from the model types: a volume that has been *deleted* still needs an
/// activity entry, and by then there is no `ContainerVolume` left to ask.
///
/// ## Why it lives in FlotillaCore
///
/// It began in the app target beside `ContainerEvent`, as the activity feed's own vocabulary. It
/// moved here when `BusySet` started keying on it, for the reason `DeletePolicy` gives: the app
/// target has **no test target**, so a decision that has to be tested cannot live there. Two
/// enumerations — one for the feed, one for the busy keys — would have been the alternative, and
/// two lists of the same five resources is how they drift apart.
///
/// What is presentation stays in the app target as an extension: `title`, `systemImage` and
/// `section` are how a kind is *drawn*, and the Foundation-only core has no business knowing SF
/// Symbol names or sidebar sections.
public enum ActivityKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case container, machine, image, volume, network
    /// The `container` runtime service itself — started, or found stopped. Not a resource, but
    /// it belongs in the same feed: it is the answer to "why was everything empty a minute ago",
    /// and an automatic action Flotilla takes on its own must leave a trace somewhere the user
    /// can find it.
    case runtime

    public var id: Self { self }
}
