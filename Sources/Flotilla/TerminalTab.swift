import SwiftUI
import AppKit
import SwiftTerm
import FlotillaCore

/// A real interactive shell inside a running container — the mockup's Terminal tab, and the
/// thing Docker Desktop's detail view has that ours did not.
///
/// **This is possible at all** because `container exec` takes `-i/--interactive` and
/// `-t/--tty`, which was checked against the live CLI rather than the docs: run under a PTY it
/// reports `/dev/pts/0` and emits real escape sequences. Run *without* one it fails with
/// "Operation not supported by device" — so the PTY is not optional, which is exactly what
/// `LocalProcessTerminalView` provides.
///
/// **It is allowed** only because the `ContainerCLI` behind it was built with
/// `ExecPolicy.interactiveShell`. The default allowlist refuses `exec <id> sh` outright, and
/// must keep refusing it: this same grammar becomes the Phase 2 wire boundary, where an
/// arbitrary `exec` from a remote peer is remote code execution on that Mac. On your own
/// machine it grants nothing you could not get by typing the command yourself.
struct TerminalTab: View {
    let model: AppModel
    let container: Container

    /// Started on demand rather than when the tab is built. Opening a container's detail view
    /// should not silently spawn a shell in it — you get a shell when you ask for one.
    @State private var session: Session?
    @State private var failure: String?

    private struct Session: Equatable {
        let argv: [String]
        /// Distinguishes one session from the next so SwiftUI rebuilds the terminal view on
        /// restart instead of reusing a dead one.
        let generation: Int
    }

    @State private var generation = 0

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label("Cannot open a shell", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { start() }
                }
            } else if !AppModel.isRunning(container) {
                // A stopped container has no namespace to exec into. Say that, rather than
                // offering a button that will fail — the CLI's own error here is
                // "container is not running", which is true but arrives too late to help.
                ContentUnavailableView {
                    Label("Container is not running", systemImage: "terminal")
                } description: {
                    Text("Start “\(container.id)” to open a shell inside it.")
                }
            } else if let session {
                TerminalSurface(argv: session.argv) { reason in
                    // The shell exited — normally because the user typed `exit`. Drop back to
                    // the idle state rather than leaving a frozen dead terminal on screen.
                    self.session = nil
                    if let reason { failure = reason }
                }
                .id(session.generation)
            } else {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: {
                    Text("Opens `sh` inside “\(container.id)” as root. "
                         + "Anything you run here affects the container, not this Mac.")
                } actions: {
                    Button("Open shell") { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A shell in one container must not appear in another's tab.
        .onChange(of: container.id) { _, _ in session = nil; failure = nil }
    }

    /// Builds the argv **through the allowlist** rather than assembling a command line here.
    ///
    /// It would be shorter to interpolate a string and hand it to a process. That is precisely
    /// the bypass `CLAUDE.md` forbids: every execution crosses `Allowlist`, so the shape of
    /// what runs is decided in one audited place and a mistake here cannot invent a new
    /// command. The validated argv is also what the CLI actually accepts — the separator
    /// handling for `exec` is a real trap, and this is the code that knows about it.
    private func start() {
        failure = nil
        do {
            // The policy comes from the CLI this model was built with, never a constant here.
            // A `ContainerCLI` pointed at a remote peer carries the strict default, and this
            // then refuses — which is the whole point of scoping it.
            let validated = try Allowlist.validated(
                ["exec", "-i", "-t", container.id, "--", Self.shell],
                execPolicy: model.cli.execPolicy
            )
            generation += 1
            session = Session(argv: validated.arguments, generation: generation)
        } catch {
            failure = "Flotilla would not permit that command: \(error)"
            model.record("Refused to open a shell in \(container.id): \(error)",
                         subsystem: "terminal")
        }
    }

    /// `sh`, not `bash`. Alpine and most minimal images have no bash, and a terminal that
    /// fails on the commonest base image is worse than one that offers a plainer shell.
    private static let shell = "sh"
}

/// Bridges SwiftTerm's `LocalProcessTerminalView` into SwiftUI.
///
/// `LocalProcessTerminalView` allocates the pseudo-terminal, spawns the process against it and
/// renders what comes back, which is the whole job — the alternative was writing a VT100
/// emulator, which is not a reasonable thing to hand-roll for a tab.
private struct TerminalSurface: NSViewRepresentable {
    /// Already validated by `Allowlist`. This view never builds a command.
    let argv: [String]
    let onExit: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator

        // The container binary is resolved the same way every other execution resolves it, so
        // a custom path in Settings applies here too rather than this one call site assuming
        // `container` is on PATH.
        let executable = Self.containerBinary
        view.startProcess(executable: executable,
                          args: Array(argv),
                          environment: nil,
                          execName: nil)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
    }

    /// Matches `LocalHost`'s resolution order. Hardcoding `/usr/local/bin/container` here
    /// would work on this Mac and break on one where the CLI lives elsewhere.
    private static var containerBinary: String {
        let candidates = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
    }

    /// `@MainActor` on the whole coordinator rather than hopping inside `processTerminated`.
    /// Hopping captured `self` across isolation domains, which Swift 6 correctly rejects as a
    /// race; the delegate only ever fires on the main thread anyway, so saying so is both
    /// truthful and simpler than smuggling a closure across.
    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: (String?) -> Void
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
