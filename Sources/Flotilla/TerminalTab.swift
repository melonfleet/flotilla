import SwiftUI
import AppKit
import SwiftTerm
import FlotillaCore

/// One shell. Identity is a `UUID` rather than the ordinal, because the ordinal is a *label*
/// that can be reused once a shell closes and must never be what a view keys off.
struct TerminalSession: Identifiable, Hashable {
    let id: UUID
    /// 1-based, and the smallest number not currently in use for this container — so closing
    /// Shell 1 of two leaves Shell 2 alone and the next new shell becomes Shell 1 again,
    /// rather than climbing to Shell 3 forever.
    let ordinal: Int
    /// A name the user gave this shell. `nil` means "still the default", which is why this is
    /// optional rather than a pre-filled string: a renamed shell must not silently revert to
    /// "Shell 2" if the ordinals shuffle underneath it.
    var name: String?

    var title: String { name ?? "Shell \(ordinal)" }
}

/// Live shell sessions, owned **outside** the view hierarchy and keyed by container.
///
/// This exists because of a real bug the owner found: switching to another tab and back gave you a
/// fresh shell. It looked like the screen had been cleared; it was worse than that. Leaving the
/// tab destroyed `TerminalTab`, which released the terminal view, which killed the process — so
/// a half-finished command, an open editor and every line of scrollback went with it, and
/// coming back silently started a *different* shell in the same container.
///
/// Holding the `LocalProcessTerminalView` here means the PTY, the process and the scrollback
/// outlive any view that happens to be showing them. The view is re-parented into whatever host
/// is on screen; nothing is recreated. The selected shell is stored here too, for the same
/// reason — coming back to the tab should return you to the shell you were using.
///
/// Sessions end **on purpose only**: you close one, the shell exits, the container stops, or
/// the app quits. No amount of navigating around the app ends one, which was the whole point.
@MainActor
@Observable
final class TerminalSessionStore {

    /// Per container, in the order they were opened. Observable because the tab strip is drawn
    /// from it; the `NSView`s themselves are not observable and SwiftUI has no business
    /// diffing them, so they are kept out of the observed surface entirely.
    private(set) var sessions: [String: [TerminalSession]] = [:]
    /// Which shell each container is currently showing.
    private(set) var selected: [String: UUID] = [:]

    @ObservationIgnored private var views: [UUID: ContainerTerminalView] = [:]
    @ObservationIgnored private var delegates: [UUID: SessionDelegate] = [:]

    func sessions(for containerID: String) -> [TerminalSession] { sessions[containerID] ?? [] }
    func view(for session: TerminalSession) -> ContainerTerminalView? { views[session.id] }

    /// The shell currently on screen for this container, if any.
    func current(for containerID: String) -> TerminalSession? {
        let open = sessions(for: containerID)
        guard let id = selected[containerID] else { return open.first }
        return open.first { $0.id == id } ?? open.first
    }

    func select(_ session: TerminalSession, in containerID: String) {
        selected[containerID] = session.id
    }

    /// Renames a shell. An empty or whitespace-only name clears back to the default rather
    /// than leaving an unlabelled chip you cannot tell from its neighbour.
    func rename(_ session: TerminalSession, in containerID: String, to name: String) {
        guard let index = sessions[containerID]?.firstIndex(where: { $0.id == session.id })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[containerID]?[index].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Opens an **additional** shell and selects it.
    @discardableResult
    func open(containerID: String, executable: String, argv: [String],
              onExit: @escaping (String?) -> Void) -> TerminalSession {
        let session = TerminalSession(id: UUID(), ordinal: nextOrdinal(for: containerID), name: nil)

        let view = ContainerTerminalView(frame: .zero)
        let delegate = SessionDelegate { [weak self] reason in
            // The shell ended by itself — `exit`, or it could not start. Drop it so the strip
            // stops offering a dead black rectangle.
            self?.forget(session, in: containerID)
            onExit(reason)
        }
        view.processDelegate = delegate

        views[session.id] = view
        delegates[session.id] = delegate
        sessions[containerID, default: []].append(session)
        selected[containerID] = session.id

        view.startProcess(executable: executable, args: argv, environment: nil, execName: nil)
        return session
    }

    /// Ends one shell deliberately.
    func close(_ session: TerminalSession, in containerID: String) {
        views[session.id]?.terminate()
        forget(session, in: containerID)
    }

    /// Ends every shell in a container — when it stops, or is deleted.
    func closeAll(for containerID: String) {
        for session in sessions(for: containerID) { close(session, in: containerID) }
    }

    /// Ends everything. A shell is a live process; quitting must not leave orphans behind.
    func closeEverything() {
        for containerID in sessions.keys { closeAll(for: containerID) }
    }

    /// Smallest unused label, so numbering stays tidy across opens and closes.
    private func nextOrdinal(for containerID: String) -> Int {
        let taken = Set(sessions(for: containerID).map(\.ordinal))
        var candidate = 1
        while taken.contains(candidate) { candidate += 1 }
        return candidate
    }

    /// Drops our references without terminating; used when the process is already gone.
    private func forget(_ session: TerminalSession, in containerID: String) {
        views[session.id]?.removeFromSuperview()
        views[session.id] = nil
        delegates[session.id] = nil
        sessions[containerID]?.removeAll { $0.id == session.id }
        if sessions[containerID]?.isEmpty == true { sessions[containerID] = nil }
        // Move the selection somewhere real rather than leaving it pointing at a dead shell.
        if selected[containerID] == session.id {
            selected[containerID] = sessions(for: containerID).last?.id
        }
    }

    /// Retained by the store rather than by a SwiftUI coordinator, for the same reason the
    /// view is: a coordinator dies with its representable, and this has to outlive it.
    @MainActor
    private final class SessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
        private let onExit: (String?) -> Void
        init(onExit: @escaping (String?) -> Void) { self.onExit = onExit }

        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            // A clean `exit` is not an error and must not be reported as one; a non-zero code
            // usually means the shell could not start at all, which is worth surfacing.
            let reason: String? = switch exitCode {
            case nil, 0: nil
            case let code?: "The shell exited with status \(code)."
            }
            MainActor.assumeIsolated { onExit(reason) }
        }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

/// The terminal, with a right-click menu.
///
/// Selecting text with the mouse already worked — SwiftTerm handles that — but right-clicking
/// did nothing at all, so there was no discoverable way to copy what you had selected, and no
/// way to paste at all short of guessing at ⌘V. That is a shell you cannot get output out of,
/// which for a debugging tool is most of the point.
///
/// The items target the responder chain rather than this object, so SwiftTerm's own
/// `copy(_:)`, `paste(_:)` and `selectAll(_:)` handle them — including its
/// `validateUserInterfaceItem`, which greys out Copy when nothing is selected instead of
/// offering an action that would silently do nothing.
final class ContainerTerminalView: LocalProcessTerminalView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // `NSText`/`NSResponder` selectors rather than hand-built ones, so a typo is a
        // compile error instead of a menu item that silently does nothing.
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        // Left at nil so each item walks the responder chain to whichever terminal is focused,
        // rather than being wired to one instance that may not be the one clicked.
        for item in menu.items { item.target = nil }
        return menu
    }
}

/// A real interactive shell inside a running container — the mockup's Terminal tab, and the
/// thing Docker Desktop's detail view has that ours did not.
///
/// **This is possible at all** because `container exec` takes `-i/--interactive` and
/// `-t/--tty`, which was checked against the live CLI rather than the docs: run under a PTY it
/// reports `/dev/pts/0` and emits real escape sequences. Run *without* one it fails with
/// "Operation not supported by device", so the PTY is not optional, which is exactly what
/// `LocalProcessTerminalView` provides.
///
/// **It is allowed** only because the `ContainerCLI` behind it was built with
/// `ExecPolicy.interactiveShell`. The default allowlist refuses `exec <id> sh` outright and
/// must keep refusing it: that grammar becomes the Phase 2 wire boundary, where an arbitrary
/// `exec` from a remote peer is remote code execution on that Mac. On your own machine it
/// grants nothing you could not get by typing the command yourself.
///
/// Sessions live in `TerminalSessionStore`, not here — see the note there.
struct TerminalTab: View {
    let model: AppModel
    let container: Container

    /// Only the *error* is view state. Which shells exist and which one is showing belong to
    /// the store, so both survive this view being destroyed and rebuilt.
    @State private var failure: String?

    /// The shell being renamed, and the text being typed. An alert rather than inline editing:
    /// the chips are small, and a text field that appears inside one is fiddly to hit and
    /// easy to lose focus from.
    @State private var renaming: TerminalSession?
    @State private var draftName = ""

    private var open: [TerminalSession] { model.terminals.sessions(for: container.id) }

    var body: some View {
        Group {
            if !AppModel.isRunning(container) {
                // A stopped container has no namespace to exec into. Say so, rather than
                // offering a button that will fail — the CLI's own error here is "container is
                // not running", which is true but arrives too late to help.
                ContentUnavailableView {
                    Label("Container is not running", systemImage: "terminal")
                } description: {
                    Text("Start “\(container.id)” to open a shell inside it.")
                }
            } else if let current = model.terminals.current(for: container.id) {
                VStack(spacing: 0) {
                    shellStrip(current: current)
                    Divider()
                    TerminalSurface(store: model.terminals, session: current)
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Cannot open a shell", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { openShell() }
                }
            } else {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: {
                    Text("Opens `sh` inside “\(container.id)” as root. "
                         + "Anything you run here affects the container, not this Mac.")
                } actions: {
                    Button("Open shell") { openShell() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A shell cannot outlive the thing it is inside. Ending them here also stops a stopped
        // container keeping dead `container exec` processes attached to it.
        .onChange(of: AppModel.isRunning(container)) { _, running in
            if !running { model.terminals.closeAll(for: container.id) }
        }
        .alert("Rename shell", isPresented: Binding(get: { renaming != nil },
                                                    set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let session = renaming {
                    model.terminals.rename(session, in: container.id, to: draftName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to go back to the default name.")
        }
    }

    private func beginRenaming(_ session: TerminalSession) {
        draftName = session.name ?? ""
        renaming = session
    }

    /// Several shells per container, so you can leave something running in one and work in
    /// another — Terminal.app's model, and what the owner asked for.
    ///
    /// Each chip closes individually. That control is not optional now that sessions persist:
    /// without it the only way to end a shell would be to type `exit` into it, and a session
    /// you have forgotten about is a process you cannot see.
    private func shellStrip(current: TerminalSession) -> some View {
        HStack(spacing: 4) {
            ForEach(open) { session in
                let isCurrent = session.id == current.id
                HStack(spacing: 5) {
                    Circle().fill(Theme.online).frame(width: 5, height: 5)
                    Text(session.title).font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    Button {
                        model.terminals.close(session, in: container.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close \(session.title)")
                    .accessibilityLabel("Close \(session.title)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isCurrent ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.secondary))
                .background(isCurrent ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(.rect)
                .onTapGesture { model.terminals.select(session, in: container.id) }
                // Right-click to rename, which is where people look for it, plus double-click
                // as the other habit Terminal.app trains.
                .contextMenu {
                    Button("Rename…") { beginRenaming(session) }
                    if session.name != nil {
                        Button("Reset name") {
                            model.terminals.rename(session, in: container.id, to: "")
                        }
                    }
                    Divider()
                    Button("Close \(session.title)") {
                        model.terminals.close(session, in: container.id)
                    }
                }
                .onTapGesture(count: 2) { beginRenaming(session) }
                .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            }

            Button { openShell() } label: {
                Image(systemName: "plus").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Open another shell in \(container.id)")
            .accessibilityLabel("New shell")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Builds the argv **through the allowlist** rather than assembling a command line here.
    ///
    /// It would be shorter to interpolate a string and hand it to a process. That is precisely
    /// the bypass `CLAUDE.md` forbids: every execution crosses `Allowlist`, so the shape of
    /// what runs is decided in one audited place and a mistake here cannot invent a new
    /// command. The validated argv is also what the CLI actually accepts — the separator
    /// handling for `exec` is a real trap, and this is the code that knows about it.
    private func openShell() {
        failure = nil
        do {
            // The policy comes from the CLI this model was built with, never a constant here.
            // A `ContainerCLI` pointed at a remote peer carries the strict default, and this
            // then refuses — which is the whole point of scoping it.
            let validated = try Allowlist.validated(
                ["exec", "-i", "-t", container.id, "--", Self.shell],
                execPolicy: model.cli.execPolicy
            )
            model.terminals.open(containerID: container.id,
                                 executable: Self.containerBinary,
                                 argv: validated.arguments) { reason in
                if let reason { failure = reason }
            }
        } catch {
            failure = "Flotilla would not permit that command: \(error)"
            model.record("Refused to open a shell in \(container.id): \(error)",
                         subsystem: "terminal")
        }
    }

    /// `sh`, not `bash`. Alpine and most minimal images have no bash, and a terminal that
    /// fails on the commonest base image is worse than one that offers a plainer shell.
    private static let shell = "sh"

    /// Matches `LocalHost`'s resolution order. Hardcoding `/usr/local/bin/container` here
    /// would work on this Mac and break on one where the CLI lives elsewhere.
    private static var containerBinary: String {
        let candidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
    }
}

/// Puts the store's long-lived terminal view on screen.
///
/// The representable owns only a plain host view; the terminal is **re-parented** into it and
/// stays owned by the store. That indirection is the fix: handing SwiftUI the terminal
/// directly makes SwiftUI's teardown the session's teardown, which is the bug this replaces.
private struct TerminalSurface: NSViewRepresentable {
    let store: TerminalSessionStore
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let host = NSView(frame: .zero)
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        attach(to: host)
    }

    private func attach(to host: NSView) {
        guard let terminal = store.view(for: session) else { return }
        // Clear whatever shell was showing here before, without touching its process — it is
        // still owned by the store and will be re-parented when its own chip is selected.
        for existing in host.subviews where existing !== terminal { existing.removeFromSuperview() }
        guard terminal.superview !== host else { return }
        terminal.removeFromSuperview()
        terminal.frame = host.bounds
        terminal.autoresizingMask = [.width, .height]
        host.addSubview(terminal)
        // Typing should reach the shell as soon as it is showing, without a click first.
        DispatchQueue.main.async { host.window?.makeFirstResponder(terminal) }
    }
}
