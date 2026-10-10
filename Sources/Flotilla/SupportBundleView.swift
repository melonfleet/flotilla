import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlotillaCore

/// Assemble a support bundle, **show exactly what is in it**, and save it where the user
/// chooses.
///
/// `research/FEATURES.md`: *"Manifest preview, user-chosen path, no upload, no server-side
/// ID."* Each clause is load-bearing:
///
/// - **Manifest preview** is the whole feature. A bundle you cannot inspect is one people
///   either send blindly or never send at all, and both are worse than not offering it. Every
///   file is listed with its size and a plain description, and any file can be read in full
///   before it goes anywhere.
/// - **User-chosen path** — a save panel, not a fixed directory. Where it lands is theirs.
/// - **No upload.** Flotilla makes no network connections at all (see `AboutView`), and this
///   feature is the one most likely to tempt someone into adding one. It writes a file. That
///   is all it does.
struct SupportBundleView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var bundle: SupportBundle?
    @State private var failure: String?
    @State private var selected: SupportBundleFile?
    @State private var saved: URL?

    var body: some View {
        ModalCard(title: "Support Bundle", onClose: dismiss) {
            content.padding(20)
        }
        .frame(width: 620, height: 560)
        .task { generate() }
        .onAppear { model.formDidOpen() }
        .onDisappear { model.formDidClose() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            // A leak is a *refusal*, not a warning to click past. The builder throws rather
            // than scrubbing harder, so a redaction gap surfaces here instead of in an inbox.
            ContentUnavailableView {
                Label("Bundle withheld", systemImage: "exclamationmark.shield")
            } description: {
                Text(failure).fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button("Try Again") { generate() }
            }
        } else if let bundle {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing leaves this Mac until you save it, and nothing is uploaded. "
                     + "Read anything below before you send it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                manifest(bundle)

                if let selected {
                    preview(of: selected)
                }

                Spacer(minLength: 0)

                HStack {
                    if let saved {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([saved])
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    Button("Save…") { save(bundle) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ProgressView("Assembling…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The manifest: every file, its size, and what it actually is. Selecting a row shows its
    /// contents — "preview" that cannot be read is just a list of filenames.
    private func manifest(_ bundle: SupportBundle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bundle.files) { file in
                Button {
                    selected = (selected?.id == file.id) ? nil : file
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected?.id == file.id ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(.body, design: .monospaced))
                            Text(file.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(ByteCountFormatStyle(style: .file).format(Int64(file.byteCount)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show the contents of \(file.name)")
                Divider()
            }
        }
    }

    private func preview(of file: SupportBundleFile) -> some View {
        ScrollView {
            Text(String(decoding: file.contents, as: UTF8.self))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 200)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func generate() {
        failure = nil
        selected = nil
        do {
            bundle = try model.makeSupportBundle()
        } catch let leak as SupportBundleLeakError {
            // Name what was found and where, without reproducing it — an error message that
            // quotes the secret defeats the point.
            bundle = nil
            failure = "\(leak.description)\n\nThis is a bug in Flotilla's redaction, not "
                + "something you did. Nothing has been written."
        } catch {
            bundle = nil
            failure = String(describing: error)
        }
    }

    /// A save panel, so the destination is the user's choice. Written as a folder of plain
    /// files rather than an archive: every one is readable without unpacking anything, which
    /// is the same reason the manifest is shown at all.
    private func save(_ bundle: SupportBundle) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = bundle.manifest.suggestedName
        panel.canCreateDirectories = true
        panel.message = "Choose where to save the support bundle. Nothing is uploaded."

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            // `contentsByFileName` includes the manifest, which exists so a UI does not have
            // to remember it is a special case — and so a file can never be written without
            // appearing in what the user was shown.
            for (name, data) in bundle.contentsByFileName {
                try data.write(to: destination.appendingPathComponent(name))
            }
            saved = destination
        } catch {
            failure = "Couldn't write the bundle: \(error.localizedDescription)"
        }
    }
}
