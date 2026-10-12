import SwiftUI
import FlotillaCore

/// Greta's page (DECISIONS Q52), reached from her face in the window bar: ask a question about
/// Flotilla, or have her draft a container that opens in the Run form for you to review.
struct GretaView: View {
    let model: AppModel
    let go: (Section) -> Void

    private var greta: Greta { model.greta }
    private var enabled: Bool { model.settingsStore[SettingsKeys.gretaEnabled] }
    private var avatar: GretaAvatar { model.settingsStore[SettingsKeys.gretaAvatar] }

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !enabled {
                ContentUnavailableView {
                    Label("Greta is off", systemImage: "sparkles")
                } description: {
                    Text("Greta answers questions about Flotilla and drafts containers for you to review, using Apple's on-device model. Nothing leaves this Mac.")
                } actions: {
                    Button("Turn On in Settings") { go(.settings) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let reason = greta.unavailableReason {
                ContentUnavailableView("Greta isn't available", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        composer
                        if greta.working {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Greta is thinking…").foregroundStyle(.secondary) }
                        }
                        if let problem = greta.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        }
                        if let answer = greta.answer { answerCard(answer) }
                        if let draft = greta.draft { draftCard(draft) }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fieldFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            GretaAvatarView(style: avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Greta").font(.title2.weight(.semibold))
                Text("Runs on this Mac with Apple's on-device model. She reads and drafts; she never runs or changes anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { greta.mode }, set: { greta.mode = $0 })) {
                ForEach(Greta.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(greta.mode == .ask ? "Ask about Flotilla — e.g. how do I keep a container running?"
                                             : "Describe a container — e.g. Postgres 17 with its data kept",
                          text: Binding(get: { greta.question }, set: { greta.question = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit { send() }
                Button(greta.mode == .ask ? "Ask" : "Draft") { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(greta.working || greta.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func send() {
        Task { await greta.send(model: model) }
    }

    private func answerCard(_ answer: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            GretaAvatarView(style: avatar, size: 26)
            Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    private func draftCard(_ draft: RunPrefill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GretaAvatarView(style: avatar, size: 26)
                Text("A container draft").font(.headline)
            }
            if let note = greta.draftNote { Text(note).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Image", draft.image)
                row("Name", draft.name)
                if !draft.ports.isEmpty { row("Ports", draft.ports.joined(separator: ", ")) }
                if !draft.env.isEmpty { row("Environment", draft.env.joined(separator: "\n")) }
                if !draft.volumes.isEmpty { row("Volumes", draft.volumes.joined(separator: ", ")) }
            }
            HStack {
                Text("Nothing runs until you press Run in the form.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open in Run Form") {
                    model.pendingRunPrefill = draft
                    go(.containers)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}
