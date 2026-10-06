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
    /// A saved group of containers (Q21).
    ///
    /// Added rather than tagging groups under `.container`: a tag keys on kind **and** id, and a
    /// group called `shop` and a container called `shop` are different objects — the same
    /// collision `TagSubject` exists to prevent between a volume and a container. It earns its
    /// place in the feed too, because starting a group is an action Flotilla performs that no
    /// member's own events explain: four containers starting within a second of each other says
    /// *what* happened and not *why*.
    case group
    /// A local Kubernetes cluster (`container k8s`). Its own kind rather than `.machine`: a
    /// cluster *is* a VM, but so is every container, and the busy keys and the feed both need to
    /// tell "the machine named dev" from "the cluster named dev".
    case cluster
    /// The `container` runtime service itself — started, or found stopped. Not a resource, but
    /// it belongs in the same feed: it is the answer to "why was everything empty a minute ago",
    /// and an automatic action Flotilla takes on its own must leave a trace somewhere the user
    /// can find it.
    case runtime
    /// A registry in the Registries section: signed in to, signed out of, added or removed
    /// (5 October, when it became a section). Its own kind so its band shows its own events, and
    /// so a tag on the registry `ghcr.io` keys on the registry, not on an image. Registry sign-ins
    /// used to be filed under `.image`, which put them in the Images band, two screens from the
    /// list they were about.
    case registry
    /// A local DNS domain in the DNS section (6 October): created, deleted, or made the one
    /// containers are named under. Its own kind so the section's band shows its own events, and so
    /// a tag on the domain `flotilla` is not a tag on a container that happens to be called that.
    case dns
    /// A Mac in the Hosts section (6 October): tagged like any other row, and — once host mode
    /// lands — added, removed and deployed to. Its own kind so a tag on the host `studio` is not a
    /// tag on a container of that name. The runtime's own starts and stops stay `.runtime`.
    case host

    public var id: Self { self }
}
