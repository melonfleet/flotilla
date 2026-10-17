import SwiftUI

/// Back, icon, title — the top bar of an embedded form screen.
///
/// Forms stopped being modals on 9 August (the owner's call). `CLAUDE.md` used to record the
/// opposite rule — "a form is a question you answer and dismiss, a place is navigable" — and
/// that reasoning was sound right up until Machines grew an embedded detail with its own Back
/// button and tab strip. At that point a floating card with a red × was the only surface in the
/// app you left a different way, and consistency beat the taxonomy.
///
/// It also removed two real costs: every modal carried a hand-picked frame (560×680, 560×660,
/// 440 wide) that content had to be trimmed to fit, and the dim-plus-`allowsHitTesting` dance in
/// `MainWindowView` existed only to serve them.
///
/// Back asks about unsaved changes through `FormGuard`, the same dialog every other route uses.
///
/// **In a split's page there is no Back** (Q58): a form shown as a row's page — a registry, a
/// domain, a group, a host — has its list beside it, so the header carries the list's ↑ ↓ and the
/// expand button instead, and leaving is choosing another row (which asks through the same guard).
/// The form's own Cancel or Done still closes it. Every other form is full width and keeps Back.
///
/// Deliberately the same shape as the detail headers in `ContainersView` and `MachinesView`, so
/// leaving a form and leaving a detail are the same gesture in the same place.
struct FormHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    /// Whether leaving now would lose something.
    ///
    /// Required rather than defaulted to `false`: a form that forgets to say would lose the guard
    /// silently, and "a setting that drives nothing is worse than a missing one" is a lesson this
    /// project has already paid for. Every screen with a `FormHeader` is a form, so every one of
    /// them has an answer.
    ///
    /// It also answers for every *other* way out — the sidebar, menu commands, ⌘K and Quit — by
    /// registering with the window's `FormGuard`, so no form has to wire those up itself.
    let hasUnsavedChanges: Bool
    let onBack: () -> Void
    /// A small pill after the title — "This Mac" on this Mac's own page.
    var titleBadge: String? = nil
    /// Pass the form's own token when its Cancel button must ask about the same registration
    /// (`FormCancelButton`); a form with no Cancel leaves it nil.
    var token: UUID? = nil
    /// Controls that belong to the whole form rather than to a field — the machine form's
    /// "Import Flotillafile…" is the only one so far.
    ///
    /// This slot is why the type is generic. Without it `MachineFormView` and `RunSheetView` each
    /// hand-rolled a header that was *nearly* this one, which is how the vertical padding came to
    /// differ three ways across the app: there were three copies of the number to keep in step
    /// and nobody kept them. One header, one number.
    @ViewBuilder var trailing: Trailing

    @State private var ownToken = UUID()
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    @Environment(\.paneLayout) private var paneLayout

    var body: some View {
        HStack(spacing: 10) {
            if paneLayout == nil {
                IconActionButton(systemImage: "chevron.left", label: "Back", help: "Back") {
                    // Through the guard, which asks the one discard question for this form alone.
                    if let formGuard { formGuard.confirmLeaving(form: token ?? ownToken, onBack) } else { onBack() }
                }
            }
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            if titleBadge != nil { ThisMacPill() }
            Spacer()
            trailing
            if paneLayout != nil { DetailStepper() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .guardsUnsavedChanges(title: title, isDirty: hasUnsavedChanges, token: token ?? ownToken)
    }
}

/// Whether a form has been edited since it opened.
///
/// Compares a signature of the fields against the one captured when the screen appeared, rather
/// than against hardcoded defaults. Two reasons: a prefilled Run sheet opens full and that is not
/// unsaved work of the user's, and the forms whose defaults come from Settings ▸ Resources have no
/// constant to compare against in the first place.
struct FormEditTracker {
    private var opened: String?

    /// Call from `onAppear`. Idempotent — a re-appear must not re-baseline and quietly forget
    /// edits made before it.
    mutating func open(_ signature: String) {
        if opened == nil { opened = signature }
    }

    func isDirty(_ signature: String) -> Bool {
        guard let opened else { return false }
        return opened != signature
    }
}

extension FormHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, hasUnsavedChanges: Bool,
         onBack: @escaping () -> Void, token: UUID? = nil) {
        self.init(title: title, systemImage: systemImage, hasUnsavedChanges: hasUnsavedChanges,
                  onBack: onBack, token: token, trailing: { EmptyView() })
    }
}
