import Foundation

/// One in-flight action: *which* thing, and *what kind of* thing.
///
/// The kind is the point. Without it the key is a bare name, and `container` has five separate
/// name spaces — a volume, a container, an image, a network and a machine may all be called `web`
/// and be five unrelated objects. `TerminalSessionStore` hit this first and answered it with a
/// second instance; the busy set had four of the five sharing one `Set<String>`, so a slow
/// `container stop web` greyed out the delete button on volume `web`.
///
/// `.runtime` never appears here. It is not a resource and has no row with controls, so no key is
/// ever built for it — but it is the same enum the activity feed uses, and inventing a
/// resources-only twin would create exactly the second list of five kinds that drifts.
public struct BusyKey: Hashable, Sendable {
    public let kind: ActivityKind
    public let id: String

    public init(kind: ActivityKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// The ids with an action in flight, so the UI can disable their controls rather than letting an
/// impatient second click fire a duplicate stop.
///
/// ## Why this is a type, and why it is here
///
/// It replaces two stored properties on `AppModel` — a `Set<String>` shared by containers, images,
/// volumes and networks, and a separate `busyMachines` that machines kept precisely *because* the
/// shared one collided. That split was the bug in miniature: the collision was understood and
/// fixed for one of five kinds, and the other four went on sharing a namespace. One mechanism that
/// cannot collide beats two mechanisms where only one of them is safe, and it means the next kind
/// added inherits the fix rather than a coin flip about which set to reach for.
///
/// It lives in `FlotillaCore`, Foundation-only, for the reason `DeletePolicy` sets out: the app
/// target has **no test target**, so the assertion that a busy container does not read as a busy
/// volume would otherwise be untestable — and an invariant nobody can test is one that comes back.
///
/// Reads take the kind as an argument rather than exposing the underlying set, so a call site
/// cannot ask the unqualified question at all. That is the whole guarantee: `contains(id)` was
/// always answerable and always ambiguous.
public struct BusySet: Sendable, Equatable {
    private var keys: Set<BusyKey> = []

    public init() {}

    public func contains(_ id: String, kind: ActivityKind) -> Bool {
        keys.contains(BusyKey(kind: kind, id: id))
    }

    /// Whether *any* of `ids` is in flight for this kind — what a multi-selection action bar needs
    /// to know before offering a button that would act on all of them.
    public func containsAny(of ids: some Sequence<String>, kind: ActivityKind) -> Bool {
        ids.contains { contains($0, kind: kind) }
    }

    /// Idempotent, like `Set.insert`: marking something already marked is not an error, because
    /// the callers that guard with `contains` first and the callers that do not must behave the
    /// same way.
    public mutating func mark(_ id: String, kind: ActivityKind) {
        keys.insert(BusyKey(kind: kind, id: id))
    }

    public mutating func clear(_ id: String, kind: ActivityKind) {
        keys.remove(BusyKey(kind: kind, id: id))
    }

    /// For diagnostics and tests. Not a substitute for `contains(_:kind:)` — see the type's note
    /// about not exposing the underlying set.
    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
}
