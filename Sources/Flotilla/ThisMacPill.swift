import SwiftUI

/// "This Mac", small, beside this Mac's own name wherever Macs are listed (the owner, 9 October):
/// the lists name every Mac by its computer name, this one included, and the pill says which one
/// you are sitting at. Sentences keep saying "This Mac".
struct ThisMacPill: View {
    var body: some View {
        Text("This Mac")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("this Mac")
    }
}
