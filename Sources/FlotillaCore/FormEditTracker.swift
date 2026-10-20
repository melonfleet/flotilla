import Foundation

/// Whether a form has been edited since it opened.
///
/// Compares a signature of the fields against the one captured when the screen appeared, rather
/// than against hardcoded defaults. Two reasons: a prefilled Run sheet opens full and that is not
/// unsaved work of the user's, and the forms whose defaults come from Settings ▸ Resources have no
/// constant to compare against in the first place.
public struct FormEditTracker: Sendable {
    public init() {}
    private var opened: String?

    /// Call from `onAppear`. Idempotent — a re-appear must not re-baseline and quietly forget
    /// edits made before it.
    public mutating func open(_ signature: String) {
        if opened == nil { opened = signature }
    }

    public func isDirty(_ signature: String) -> Bool {
        guard let opened else { return false }
        return opened != signature
    }
}
