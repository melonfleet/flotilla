import SwiftUI
import FlotillaCore

/// The one check every way of leaving a form goes through, other than its own Back.
///
/// Back has asked before discarding since `FormEditTracker` landed; the sidebar, the menu commands,
/// ⌘K and Quit did not, and each dropped a half-filled form without a word. They could not ask:
/// the form's state is `@State` in a section view, and none of those routes can see it. So the
/// form reports outwards — `FormHeader` marks itself here while it has unsaved changes and removes
/// itself when it goes — and each route calls `confirmLeaving` instead of navigating directly.
///
/// One question, asked in one place (`MainWindowView`), whichever route asked it. The decision
/// itself — dirty or not, which forms, what to say — is `UnsavedForms`, in `FlotillaCore`, tested.
///
/// **Routes, for whoever adds the next one:** the sidebar (`MainWindowView.navigate`), the app
/// menus (`FlotillaCommands.present`), the menu-bar menu (`MenuBarView.present`), ⌘K
/// (`CommandPalette`), the window bar's bell and gear, the runtime band's Settings…, Greta's
/// buttons, a click on a macOS notification, a `.flotilla` file opened from Finder, and Quit
/// (`AppDelegate.applicationShouldTerminate`). A new way of changing section that skips this
/// is the bug this type exists to stop.
///
/// **In-page links need nothing:** every `AppModel.request…` asks through `AppModel.present`, and
/// `pendingSection` cannot be set from outside `AppModel`. The raw one-shot flags a section reads
/// directly — `pendingRunPrefill` — are the exception: set one only inside `confirmLeaving`, as
/// Greta's "Open in Run Form" does.
@MainActor
@Observable
final class FormGuard {
    /// A question on screen: what it says, and what each answer does.
    struct Question: Identifiable {
        let id = UUID()
        let text: String
        let discard: () -> Void
        let keepEditing: () -> Void
    }

    private(set) var forms = UnsavedForms()
    /// The question being asked, if any. Read by `MainWindowView`'s dialog.
    private(set) var asking: Question?
    /// True while a Discard's navigation runs, so a route nested inside it — Greta's "Open in Run
    /// Form" sets a prefill and then changes section, both guarded — does not ask a second time
    /// about a form the user has just discarded but that has not yet left the screen.
    @ObservationIgnored private var discarding = false
    /// Requests that arrived while `asking` was on screen, oldest first; settled by its answer.
    @ObservationIgnored private var waiting: [(leave: () -> Void, keepEditing: () -> Void)] = []

    func mark(_ token: UUID, title: String, isDirty: Bool) {
        forms.mark(token, title: title, isDirty: isDirty)
    }

    func remove(_ token: UUID) {
        forms.remove(token)
    }

    /// Runs `leave` now if no form would lose anything; otherwise asks, and runs it only on Discard.
    ///
    /// Synchronous when clean, so a menu command's one-shot request still lands before the window
    /// it opens reads it. A request that arrives while a question is already showing — ⌘Q, a
    /// notification click, a file opened from Finder — waits behind it, and the one answer settles
    /// both: the question is about the same unsaved forms either way. Dropping it instead left
    /// Quit's `.terminateLater` with no reply, so AppKit waited for an answer that never came;
    /// replacing the open question would apply the answer to something the user did not ask about.
    func confirmLeaving(onKeepEditing: @escaping () -> Void = {},
                        _ leave: @escaping () -> Void) {
        guard !discarding, let text = forms.discardQuestion else { return leave() }
        guard asking == nil else {
            waiting.append((leave: leave, keepEditing: onKeepEditing))
            return
        }
        asking = Question(text: text, discard: leave, keepEditing: onKeepEditing)
    }

    func discard() {
        guard let question = asking else { return }
        let queued = waiting
        asking = nil
        waiting = []
        discarding = true
        defer { discarding = false }
        question.discard()
        queued.forEach { $0.leave() }
    }

    func keepEditing() {
        guard let question = asking else { return }
        let queued = waiting
        asking = nil
        waiting = []
        question.keepEditing()
        queued.forEach { $0.keepEditing() }
    }

    /// The dialog went away by some route other than its buttons. Treated as Keep Editing — losing
    /// work is never the default — but on the next turn, because SwiftUI may clear the presentation
    /// binding *before* running the button that dismissed it, and Discard must still win then.
    func dialogDismissed() {
        guard let id = asking?.id else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.asking?.id == id else { return }
            self.keepEditing()
        }
    }
}

extension View {
    /// Registers a form with the window's `FormGuard` while `isDirty`, and removes it when the view
    /// goes — which is how a saved form stops prompting: every form dismisses itself on save.
    ///
    /// `FormHeader` applies this, so every form with a header is covered without opting in. Use it
    /// directly only where a form's state outlives its header — `GroupFormView`, whose draft stays
    /// while a service editor replaces the group's screen.
    func guardsUnsavedChanges(title: String, isDirty: Bool) -> some View {
        modifier(UnsavedChangesRegistration(title: title, isDirty: isDirty))
    }
}

private struct UnsavedChangesRegistration: ViewModifier {
    let title: String
    let isDirty: Bool

    /// Optional: a header drawn outside the main window (a preview, a future sheet) has no guard
    /// to report to, and must not crash for it.
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear(perform: sync)
            .onChange(of: isDirty) { sync() }
            .onChange(of: title) { sync() }
            .onDisappear { formGuard?.remove(token) }
    }

    private func sync() {
        formGuard?.mark(token, title: title, isDirty: isDirty)
    }
}
