import Foundation

/// What a destructive action destroys, and how many of them.
public enum DeleteScope: Sendable, Equatable {
    /// One container, image, volume, network or machine.
    case single
    /// More than one, from a multi-selection.
    case bulk(count: Int)

    var isBulk: Bool {
        if case .bulk = self { return true }
        return false
    }
}

/// The single authority on whether a destructive action is confirmed first.
///
/// ## Why this exists at all
///
/// The 2026-08-20 audit found `confirmDestructiveActions` read in three places — Volumes, Networks
/// and Images — each with its own private copy of the same four-line `requestDelete`, and **not
/// read at all** by Containers or Machines. Worth being precise about the consequence, because it
/// is the opposite of how it first reads: those two screens confirm *unconditionally*. So nothing
/// was ever deleted without asking. The bug was that turning the setting off did nothing on two of
/// the five screens — a setting that lies about its own scope, which is the same family as the
/// Wave 2 findings, not a safety hole.
///
/// Five copies of a decision is four too many either way: the next screen to be added inherits
/// whichever copy happened to be nearby.
///
/// ## Why it lives in FlotillaCore
///
/// It is Foundation-only and pure, so `swift test` can cover it. The app target has **no test
/// target** — that is the standing reason the UI refactors are deferred — and a decision this
/// consequential should not be one of the untestable parts. The views keep their own dialog state
/// and wording, which is right: what differs per screen is the sentence, and what must not differ
/// is the rule.
public struct DeletePolicy: Sendable, Equatable {
    /// The user's `confirmDestructiveActions` preference. Applies to single deletes only.
    public let confirmsSingleDeletes: Bool

    public init(confirmsSingleDeletes: Bool) {
        self.confirmsSingleDeletes = confirmsSingleDeletes
    }

    /// Whether this action must be confirmed before it runs.
    ///
    /// **Bulk is always confirmed, and no setting can turn that off.** There used to be a
    /// `confirmBulkActions` preference; it had no consumer anywhere in the app, so the mandatory
    /// behaviour is what has always actually shipped. It was deleted rather than wired up, because
    /// its "off" position means *destroy several things at once without asking* — and a
    /// multi-selection is exactly where the gap between what you think is selected and what is
    /// selected does the damage. The Containers screen already documents that a filter change
    /// leaves rows selected that are no longer visible.
    public func requiresConfirmation(_ scope: DeleteScope) -> Bool {
        scope.isBulk ? true : confirmsSingleDeletes
    }
}
