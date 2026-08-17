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
    let onBack: () -> Void
    /// Controls that belong to the whole form rather than to a field — the machine form's
    /// "Import Flotillafile…" is the only one so far.
    ///
    /// This slot is why the type is generic. Without it `MachineFormView` and `RunSheetView` each
    /// hand-rolled a header that was *nearly* this one, which is how the vertical padding came to
    /// differ three ways across the app: there were three copies of the number to keep in step
    /// and nobody kept them. One header, one number.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconActionButton(systemImage: "chevron.left", label: "Back", help: "Back",
                             action: onBack)
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension FormHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, onBack: @escaping () -> Void) {
        self.init(title: title, systemImage: systemImage, onBack: onBack,
                  trailing: { EmptyView() })
    }
}
