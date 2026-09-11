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
    let hasUnsavedChanges: Bool
    let onBack: () -> Void
    /// Controls that belong to the whole form rather than to a field — the machine form's
    /// "Import Flotillafile…" is the only one so far.
    ///
    /// This slot is why the type is generic. Without it `MachineFormView` and `RunSheetView` each
    /// hand-rolled a header that was *nearly* this one, which is how the vertical padding came to
    /// differ three ways across the app: there were three copies of the number to keep in step
    /// and nobody kept them. One header, one number.
    @ViewBuilder var trailing: Trailing

    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back", help: "Back") {
                if hasUnsavedChanges { confirmingDiscard = true } else { onBack() }
            }
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Only on the way out, and only when there is something to lose. A form you opened and
        // did not touch closes on one click, as it always did.
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: onBack)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This form has changes that have not been saved. Leaving now loses them.")
        }
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
         onBack: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, hasUnsavedChanges: hasUnsavedChanges,
                  onBack: onBack, trailing: { EmptyView() })
    }
}
