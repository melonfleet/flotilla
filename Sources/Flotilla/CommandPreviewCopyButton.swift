import AppKit
import SwiftUI

/// `FEATURES.md` requires a copy affordance wherever a command preview teaches the CLI or
/// supplies an audit string. One control keeps its clipboard behavior and feedback identical.
struct CommandPreviewCopyButton: View {
    let command: String
    let help: String

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .controlSize(.small)
        .help(help)
        // The tick must describe the command currently on screen, not the previous edit.
        .onChange(of: command) { copied = false }
    }
}
