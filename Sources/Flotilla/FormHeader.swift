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
struct FormHeader: View {
    let title: String
    let systemImage: String
    let onBack: () -> Void

    init(title: String, systemImage: String, onBack: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .help("Back")
                .accessibilityLabel("Back")
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
