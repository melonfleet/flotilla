import SwiftUI
import FlotillaCore

/// The last step of pairing by code, on both Macs at once: the same four words, and the other
/// Mac's details, for the owner to compare. Pairing completes only when both owners say they match
/// — the words, not the code, are what show there is no machine in the middle.
struct PairingWordsSheet: View {
    let prompt: HostModeController.WordsPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.role == .host ? "Check the words on the other Mac" : "An admin Mac wants to pair")
                    .font(.title3.weight(.semibold))
                Text("Pair only if the other Mac shows exactly these words, in this order.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(Array(prompt.words.enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity)

            if prompt.role == .admin {
                Label("Pairing gives this admin Mac full control of this Mac’s containers, including their "
                      + "settings, environment variables and file paths. Pair only with your own admin Mac.",
                      systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .lineLimit(4)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Mac", prompt.peer.computerName)
                row("Model", prompt.peer.model)
                row("Serial", prompt.peer.serialNumber)
                row("macOS", prompt.peer.macOSVersion)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("They Don’t Match") { prompt.reply(false) }
                    .keyboardShortcut(.cancelAction)
                Button("They Match") { prompt.reply(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
