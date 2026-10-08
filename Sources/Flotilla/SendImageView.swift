import SwiftUI
import FlotillaCore

/// Send to Hosts (PLAN.md Phase D, D2): one of This Mac's images, saved here once and loaded on the
/// hosts you tick. For images only This Mac can reach — a private registry it is signed in to, or
/// one built here. A public image is quicker pulled by each host itself (Pull to, in New Image).
///
/// Each host says what a send would do before anything runs. A host that already has this exact
/// image, is not answering, or runs a `container` too old to load archives safely cannot be ticked.
struct SendImageView: View {
    let model: AppModel
    let image: ContainerImage
    let dismiss: () -> Void

    @State private var chosen: Set<HostRef> = []
    @State private var seeded = false

    private var platform: String? { ImageTransfer.platform(for: image) }

    /// Ticked and still sendable — a host that has since stopped answering is dropped, not tried.
    private var targets: [HostRef] {
        model.trustedHostRefs.filter { chosen.contains($0) && model.sendState(of: image, to: $0).sendable }
    }

    var body: some View {
        VStack(spacing: 0) {
            FormHeader(title: "Send \u{201C}\(ContainerImage.shortReference(image.reference))\u{201D} to Hosts",
                       systemImage: "paperplane", hasUnsavedChanges: false, onBack: dismiss)
            Divider()
            FormScaffold {
                form
            } preview: {
                rail
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Fresh image lists from every host first, so "already has it" is current.
            await model.hostMode.refreshLiveStatus(force: true)
            if !seeded {
                // Only hosts that lack it: replacing a host's own copy of this name is ticked by hand.
                chosen = Set(model.trustedHostRefs.filter {
                    let state = model.sendState(of: image, to: $0)
                    return state.sendable && !state.warning
                })
                seeded = true
            }
        }
    }

    // MARK: Form

    private var summary: String {
        let size = image.displaySize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        guard let platform else {
            return "This image has no linux/arm64 or linux/amd64 variant, so no host could run it."
        }
        return "The \(platform) variant" + (size.map { ", about \($0)" } ?? "")
            + ". This Mac saves it once and each host loads it itself; no registry sign-in leaves this Mac."
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            FormSectionHeader(title: image.reference, note: summary)

            VStack(alignment: .leading, spacing: 8) {
                FormSectionHeader(title: "Hosts",
                                  note: "A public image is quicker pulled by each host itself — use Pull to in New Image. "
                                      + "A dropped transfer starts again from the beginning.")
                if model.trustedHostRefs.isEmpty {
                    Text("No host is paired yet. Add one in Hosts.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HostChecklist(model: model, hosts: model.trustedHostRefs, selection: $chosen,
                                  isSelectable: { platform != nil && model.sendState(of: image, to: $0).sendable },
                                  state: { host in
                                      let state = model.sendState(of: image, to: host)
                                      return (state.text, state.warning)
                                  },
                                  stateTitle: "A send would")
                }
                ContainerSkewNote(model: model, hosts: targets)
            }
        }
    }

    // MARK: Rail and footer

    /// What runs where — This Mac's save once, then each host's load, which the host builds itself
    /// for a file of its own choosing. Built by the same function that runs the save.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command preview", systemImage: "chevron.right.square")
                .font(.caption).foregroundStyle(Theme.info)
            if targets.isEmpty || platform == nil {
                Text("Choose a host to see what will run.")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("On This Mac, once:").font(.caption).foregroundStyle(.secondary)
                commandText((["container"] + ContainerCLI.saveImageArguments(
                    image.reference, platform: platform ?? "", archive: "<archive>")).joined(separator: " "))
                Text("Then on \(targets.count) host\(targets.count == 1 ? "" : "s"), once it has arrived and its digest matches:")
                    .font(.caption).foregroundStyle(.secondary)
                commandText("container image load --input <archive>")
            }
        }
    }

    private func commandText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(targets.count == 1 ? "Send to 1 Host" : "Send to \(targets.count) Hosts") {
                let hosts = targets
                let image = image
                dismiss()
                Task { await model.sendImage(image, to: hosts) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(targets.isEmpty || platform == nil)
        }
        .padding(12)
    }
}
