import SwiftUI
import FlotillaCore

/// Greta's local history uses the same rows, selection and split as the fleet sections.
struct GretaView: View {
    let model: AppModel
    let go: (Section) -> Void

    @State private var selection: Set<UUID> = []
    @State private var pane = PaneState()
    @State private var search = ""
    @State private var archived = false
    @State private var deleting: Set<UUID> = []
    @State private var confirmingDelete = false
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var showingRename = false

    private var greta: Greta { model.greta }
    private var chats: [GretaConversation] {
        greta.orderedConversations.filter {
            $0.isArchived == archived && (search.isEmpty || $0.title.localizedStandardContains(search)
                || $0.messages.contains { $0.text.localizedStandardContains(search) })
        }
    }
    private var existingIDs: Set<UUID> { Set(greta.conversations.map(\.id)) }
    private var selectedChats: [GretaConversation] {
        greta.orderedConversations.filter { selection.contains($0.id) }
    }
    private var shownChat: GretaConversation? { selection.count == 1 ? selectedChats.first : nil }

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
            } else {
                // History remains available even when the on-device model cannot answer.
                SplitPanes(list: "greta", pane: pane, showing: shownChat?.id, clearing: { selection = [] }) {
                    history
                } detail: {
                    page
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .selection($selection, confinedTo: Set(chats.map(\.id)), showing: existingIDs)
        .onAppear { selection = greta.currentID.map { [$0] } ?? [] }
        .onChange(of: selection) { _, ids in
            greta.currentID = ids.count == 1 ? ids.first : nil
        }
        .onChange(of: greta.currentID) { _, id in
            if let id, selection != [id] { selection = [id] }
        }
        .confirmationDialog("Delete \(deleting.count == 1 ? "conversation" : "conversations")?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for id in deleting { greta.delete(id) }
                deleting = []
            }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: {
            Text("This permanently deletes the selected chat history from this Mac.")
        }
        .alert("Rename Conversation", isPresented: $showingRename) {
            TextField("Title", text: $newTitle).accessibilityLabel("Conversation title")
            Button("Save") { if let renaming { greta.rename(renaming, title: newTitle) } }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var history: some View {
        VStack(spacing: 0) {
            SectionToolbar(search: $search, searchPrompt: "Search conversations", matches: chats.count) {
                PaneModeButton()
                SelectAllCheckbox(selection: $selection, ids: chats.map(\.id), noun: "conversations")
                Picker("Conversations", selection: $archived) {
                    Text("Active").tag(false)
                    Text("Archived").tag(true)
                }
                .pickerStyle(.menu).fixedSize()
            } trailing: {
                ToolbarIconButton(systemImage: "square.and.pencil", label: "New conversation") {
                    archived = false
                    search = ""
                    greta.newConversation()
                    if let id = greta.currentID { selection = [id] }
                    pane.reveal()
                }
            }
            if selection.count > 1 {
                BulkActionBar(title: "\(selection.count) selected") { bulkActions(for: selection).labelStyle(.iconOnly) }
            }
            Divider()
            SelectionRevealingList(selection: selection) {
                List(chats, selection: $selection) { chat in
                    conversationRow(chat).listRowInsets(EdgeInsets())
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    rowContextMenu(for: ids)
                } primaryAction: { ids in
                    if ids.count == 1 { selection = ids; pane.reveal() }
                }
                .overlay {
                    if chats.isEmpty {
                        Text(search.isEmpty ? "No \(archived ? "archived" : "active") conversations" : "No matching conversations")
                            .font(.caption).foregroundStyle(.secondary).padding()
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func conversationRow(_ chat: GretaConversation) -> some View {
        let preview = chat.messages.last?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages yet"
        return ResourceRow(
            title: chat.title,
            trailingText: (chat.isPinned ? "📌 " : "") + RelativeDate.relativeToNow(chat.lastActivity),
            detail: preview,
            selected: selection.contains(chat.id),
            check: RowCheck(chat.id, in: $selection),
            summary: "\(chat.title), \(chat.isPinned ? "pinned, " : "")\(preview)",
            leading: { RowLeadingMark { RowKindGlyph(systemImage: "bubble.left.and.bubble.right") } },
            chips: { EmptyView() },
            actions: { overflow(for: chat) })
    }

    private func overflow(for chat: GretaConversation) -> some View {
        Menu {
            menu(for: chat)
        } label: { RowOverflowLabel() }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More actions for \(chat.title)")
        .accessibilityLabel("More actions for \(chat.title)")
    }

    @ViewBuilder
    private func menu(for chat: GretaConversation) -> some View {
        Button(chat.isPinned ? "Unpin" : "Pin") { greta.pin([chat.id], pinned: !chat.isPinned) }
        Button("Rename…") { renaming = chat.id; newTitle = chat.title; showingRename = true }
        Button("Duplicate") { greta.duplicate(chat.id) }
        Button(chat.isArchived ? "Unarchive" : "Archive") { greta.archive([chat.id], archived: !chat.isArchived) }
        Divider()
        Button("Delete…", role: .destructive) { requestDelete([chat.id]) }
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let chat = greta.conversations.first(where: { ids.contains($0.id) }) {
            menu(for: chat)
        } else if ids.count > 1 {
            bulkActions(for: ids)
        }
    }

    @ViewBuilder
    private func bulkActions(for ids: Set<UUID>) -> some View {
        Button { greta.pin(ids, pinned: true) } label: { Label("Pin", systemImage: "pin") }
            .help("Pin selected conversations")
        Button { greta.archive(ids, archived: !archived) } label: {
            Label(archived ? "Unarchive" : "Archive", systemImage: "archivebox")
        }
        .help(archived ? "Unarchive selected conversations" : "Archive selected conversations")
        Button(role: .destructive) { requestDelete(ids) } label: { Label("Delete…", systemImage: "trash") }
            .help("Delete selected conversations")
    }

    private func requestDelete(_ ids: Set<UUID>) {
        deleting = ids
        confirmingDelete = true
    }

    @ViewBuilder
    private var page: some View {
        if let chat = shownChat {
            VStack(spacing: 0) {
                HStack {
                    Text(chat.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    overflow(for: chat)
                    DetailStepper()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                GretaChatView(model: model, go: go, compact: false)
                    .id(chat.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paneStep("conversation", "conversations", order: chats.map(\.id), current: chat.id) {
                selection = [$0]
                pane.reveal()
            }
        } else if selection.count > 1 {
            SelectionSummaryPane(title: "\(selection.count) conversations selected", systemImage: "bubble.left.and.bubble.right",
                                 names: selectedChats.map(\.title)) { bulkActions(for: selection).labelStyle(.iconOnly) }
        } else {
            PaneEmptyState(title: "Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                           description: greta.unavailableReason ?? "Select a conversation or start a new one to ask Greta.")
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
    @State private var composerPaneWidth: CGFloat = 360
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var greta: Greta { model.greta }
    private var dictation: GretaDictation { model.greta.dictation }
    private var avatar: GretaAvatar { model.gretaAvatar }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let reason = greta.unavailableReason {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
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
            composer
                .frame(width: min(720, composerPaneWidth * 0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 10 : 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composerPaneWidth = $0 }
        .onAppear {
            focused = true
            dictation.attach(.init(read: { text }, write: { text = $0 }))
        }
        .onDisappear { dictation.detach() }
        .onChange(of: text) { _, new in dictation.textChanged(to: new) }
        // The microphone is only on while this window is the one being used.
        .onChange(of: activeState) { _, new in if new != .key { dictation.stop(finalize: false) } }
    }

    /// Tips by example (the owner, 12 October): one box, and these show what to put in it.
    static let examples = [
        "What can Flotilla do?",
        "How do I keep a container running if it crashes?",
        "Draft Postgres with its data kept",
        "Why does a host say it isn't answering?",
    ]

    private var welcome: some View {
        HStack(alignment: .top, spacing: 10) {
            GretaAvatarView(style: avatar, size: compact ? 30 : 40)
            VStack(alignment: .leading, spacing: 8) {
                Text("Hi, I'm Greta.").font(.headline)
                Text("Ask me how something in Flotilla works, or tell me what you want to run and I'll draft it for the Run form. I work on this Mac, and I never run or change anything myself.")
                    .foregroundStyle(.secondary)
                Text("Try:").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.examples, id: \.self) { example in
                        Button(example) { text = example; send() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            dictationNotice
            composerField
        }
    }

    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Greta…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .accessibilityLabel("Message to Greta")
                .onSubmit(send)
                .padding(.vertical, 5)
            micButton
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(greta.working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
                .accessibilityLabel("Send")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
        .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.hairline))
        // Esc stops listening (and only that: with the mic off it goes on to whatever it did before).
        .onKeyPress(.escape) {
            guard dictation.isListening else { return .ignored }
            dictation.stop(finalize: true)
            return .handled
        }
    }

    /// Messages-style: beside Send. Listening is `mic.fill` in the accent colour, pulsing unless
    /// Reduce Motion is on. Unavailable (the language isn't offered on-device) it is disabled and
    /// says so.
    private var micButton: some View {
        let listening = dictation.isListening
        let unsupported = dictation.state == .unsupported
        let busy: Bool = { if case .downloading = dictation.state { return true } else { return false } }()
        return Button { dictation.toggle() } label: {
            Image(systemName: listening ? "mic.fill" : "mic")
                .font(.title3)
                .foregroundStyle(listening ? Color.accentColor : Color.secondary)
                .symbolEffect(.pulse, isActive: listening && !reduceMotion)
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.borderless)
        .disabled(unsupported || busy)
        .help(unsupported
              ? "Dictation isn't available in \(dictation.languageName) on this Mac. Speech is only recognised on this Mac."
              : listening ? "Stop dictating (⇧⌘D)" : "Dictate (⇧⌘D). Speech is recognised on this Mac.")
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
    }

    /// One line above the field for whatever dictation needs said or asked: the model download,
    /// a refused microphone, or why it stopped.
    @ViewBuilder
    private var dictationNotice: some View {
        switch dictation.state {
        case .needsModel:
            noticeRow("macOS needs to download speech recognition for \(dictation.languageName) from Apple, once. Your speech stays on this Mac.",
                      systemImage: "arrow.down.circle") {
                Button("Not Now") { dictation.dismissModelPrompt() }.controlSize(.small)
                Button("Download") { dictation.download() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .downloading(let fraction):
            noticeRow("Downloading speech recognition for \(dictation.languageName)…", systemImage: "arrow.down.circle") {
                if let fraction { ProgressView(value: fraction).frame(width: 80) } else { ProgressView().controlSize(.small) }
            }
        case .denied:
            noticeRow("Flotilla can't use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone.",
                      systemImage: "mic.slash") {
                Button("Open Microphone Settings") { NSWorkspace.shared.open(GretaDictation.microphoneSettingsURL) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        default:
            if let note = dictation.message {
                noticeRow(note, systemImage: "info.circle") {
                    Button("Dismiss") { dictation.dismissMessage() }.controlSize(.small)
                }
            }
        }
    }

    private func noticeRow<Actions: View>(_ text: String, systemImage: String,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 6)
    }

    private func send() {
        let question = text
        dictation.stop(finalize: false)        // Send ends dictation; nothing lands in the cleared field
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
                    if message.opensStacks == true {
                        Button("Open Suggestions") {
                            // Asked before the request: Containers consumes it the moment it is set.
                            model.formGuard.confirmLeaving {
                                onOpenDraft?()
                                model.requestSuggestions(.containers)
                            }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
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
                    // Asked before the prefill, which a Run form already on screen would take.
                    model.formGuard.confirmLeaving {
                        model.pendingRunPrefill = draft.prefill
                        onOpenDraft?()
                        go(.containers)
                    }
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
                // Plainly, as well as through her face: the full page, with the history.
                Button { model.greta.overlayShown = false; go(.greta) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless).help("Open full chat").accessibilityLabel("Open full chat")
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
