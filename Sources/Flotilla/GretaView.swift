import SwiftUI
import FlotillaCore

/// Greta's full page (DECISIONS Q52), from "Ask Greta" in the sidebar: chat history on the left,
/// the current chat on the right. ⌘G opens the same chat floating over any page (`GretaOverlay`).
struct GretaView: View {
    let model: AppModel
    let go: (Section) -> Void

    private var greta: Greta { model.greta }

    var body: some View {
        Group {
            if !model.gretaEnabled {
                ContentUnavailableView {
                    Label("Greta is off", systemImage: "sparkles")
                } description: {
                    Text("Greta answers questions about Flotilla and drafts containers for you to review, using Apple's on-device model. Nothing leaves this Mac.")
                } actions: {
                    Button("Turn On in Settings") { go(.settings) }.buttonStyle(.borderedProminent)
                }
            } else if let reason = greta.unavailableReason {
                ContentUnavailableView("Greta isn't available", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            } else {
                HStack(spacing: 0) {
                    history.frame(width: 230)
                    Divider()
                    GretaChatView(model: model, go: go, compact: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button { greta.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New chat")
                    .accessibilityLabel("New chat")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            List(selection: Binding(get: { greta.currentID }, set: { greta.currentID = $0 })) {
                ForEach(greta.conversations) { chat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).lineLimit(1)
                        Text(RelativeDate.relativeToNow(chat.messages.last?.date ?? chat.started))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(chat.id)
                    .contextMenu {
                        Button("Delete Chat", role: .destructive) { greta.delete(chat.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if greta.conversations.isEmpty {
                    Text("No chats yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One chat with Greta: the messages, newest at the bottom and scrolled into view, and the box to
/// ask or draft in. The full page and the floating panel share it.
struct GretaChatView: View {
    let model: AppModel
    let go: (Section) -> Void
    let compact: Bool
    var onOpenDraft: (() -> Void)? = nil

    @State private var text = ""
    @FocusState private var focused: Bool

    private var greta: Greta { model.greta }
    private var avatar: GretaAvatar { model.gretaAvatar }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if (greta.current?.messages ?? []).isEmpty { welcome }
                        ForEach(greta.current?.messages ?? []) { message in
                            bubble(message).id(message.id)
                        }
                        if greta.working {
                            HStack(spacing: 8) {
                                GretaAvatarView(style: avatar, size: 22)
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: compact ? .infinity : 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
                }
                .onChange(of: greta.current?.messages.count) { _, _ in
                    withAnimation { reader.scrollTo(greta.current?.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: greta.working) { _, working in
                    if working { withAnimation { reader.scrollTo("working", anchor: .bottom) } }
                }
                .onAppear { reader.scrollTo(greta.current?.messages.last?.id, anchor: .bottom) }
            }
            Divider()
            composer.padding(compact ? 10 : 14)
        }
        .onAppear { focused = true }
    }

    private var welcome: some View {
        HStack(alignment: .top, spacing: 10) {
            GretaAvatarView(style: avatar, size: compact ? 30 : 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi, I'm Greta.").font(.headline)
                Text("Ask me how something in Flotilla works, or switch to Draft a container and describe what you need. I run on this Mac, and I never run or change anything myself.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Binding(get: { greta.mode }, set: { greta.mode = $0 })) {
                ForEach(Greta.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(greta.mode == .ask ? "Ask about Flotilla…" : "Describe a container, e.g. Postgres 17 with its data kept",
                          text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(greta.working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(greta.mode == .ask ? "Ask" : "Draft")
                    .accessibilityLabel(greta.mode == .ask ? "Ask" : "Draft")
            }
        }
    }

    private func send() {
        let question = text
        text = ""
        Task { await greta.send(question, model: model) }
    }

    @ViewBuilder
    private func bubble(_ message: GretaMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        case .greta:
            HStack(alignment: .top, spacing: 8) {
                GretaAvatarView(style: avatar, size: 24)
                VStack(alignment: .leading, spacing: 8) {
                    if message.isProblem {
                        Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    } else {
                        Text(message.text).textSelection(.enabled)
                    }
                    if let draft = message.draft { draftCard(draft) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                Spacer(minLength: 24)
            }
        }
    }

    private func draftCard(_ draft: GretaDraftRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("Image", draft.image)
                row("Name", draft.name)
                if !draft.ports.isEmpty { row("Ports", draft.ports.joined(separator: ", ")) }
                if !draft.env.isEmpty { row("Env", draft.env.joined(separator: "\n")) }
                if !draft.volumes.isEmpty { row("Volumes", draft.volumes.joined(separator: ", ")) }
            }
            HStack {
                Text("Nothing runs until you press Run.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open in Run Form") {
                    model.pendingRunPrefill = draft.prefill
                    onOpenDraft?()
                    go(.containers)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}

/// ⌘G: Greta in a floating panel over whichever page is showing, so asking doesn't mean leaving it.
/// Her face at the top opens the full page, with this chat and the rest of the history.
struct GretaOverlay: View {
    let model: AppModel
    let go: (Section) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.greta.overlayShown = false; go(.greta) } label: {
                    HStack(spacing: 8) {
                        GretaAvatarView(style: model.gretaAvatar, size: 26)
                        Text("Greta").font(.headline)
                    }
                }
                .buttonStyle(.plain)
                .help("Open Greta's page, with your chat history")
                Spacer()
                Button { model.greta.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).help("New chat").accessibilityLabel("New chat")
                Button { model.greta.overlayShown = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close (⌘G)").accessibilityLabel("Close Greta")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let reason = model.greta.unavailableReason {
                Text(reason).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
            } else {
                GretaChatView(model: model, go: go, compact: true) { model.greta.overlayShown = false }
            }
        }
        .frame(width: 400, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .padding(16)
    }
}
