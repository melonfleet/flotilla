import SwiftUI

/// The house shape for a dialog you acknowledge: a title, a divider, the content, and the
/// dialog's own buttons (Done, Close, Cancel). Progress is not one of them any more: jobs report
/// in the Tasks drawer (Q63). There is no drawn close control: the red
/// circle it used to carry duplicated the dialog's own button and looked out of place
/// (Kamal, 19 October 2026). Esc still closes it, through `closesOnEscape`, unless the dialog's
/// own Cancel button already answers Esc.
struct ModalCard<Content: View>: View {
    let title: String
    let onClose: () -> Void
    /// Off when the content has its own `.cancelAction` button, so Esc has exactly one owner.
    var closesOnEscape = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            content
        }
        .background {
            // Esc, without a visible control: the dialog's own buttons are the way out.
            if closesOnEscape {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}
