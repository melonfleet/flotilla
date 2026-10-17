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
    /// A request that arrived while `asking` was on screen, and the question it would have asked.
    private struct Waiting {
        let text: String
        let leave: () -> Void
        let keepEditing: () -> Void
        /// Puts the request through again, scoped as it was first made.
        let askAgain: () -> Void
    }
    /// Requests that arrived while `asking` was on screen, oldest first.
    @ObservationIgnored private var waiting: [Waiting] = []

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
    /// notification click, a file opened from Finder — waits behind it. Keep Editing settles it;
    /// Discard settles it only if it would have asked the same question (see `discard`). Dropping it instead left
    /// Quit's `.terminateLater` with no reply, so AppKit waited for an answer that never came;
    /// replacing the open question would apply the answer to something the user did not ask about.
    func confirmLeaving(onKeepEditing: @escaping () -> Void = {},
                        _ leave: @escaping () -> Void) {
        confirm(question: forms.discardQuestion, onKeepEditing: onKeepEditing, leave,
                askAgain: { [weak self] in self?.confirmLeaving(onKeepEditing: onKeepEditing, leave) })
    }

    /// The same, for leaving **one** form — Back or Cancel — which loses only that form's edits.
    ///
    /// Add Service inside New Group is the case that needs it: the group's draft stays on screen,
    /// so the question names the service alone and a clean service leaves at once even while the
    /// group is dirty. Same dialog, same queueing, same Discard rules as every other route.
    func confirmLeaving(form token: UUID, onKeepEditing: @escaping () -> Void = {},
                        _ leave: @escaping () -> Void) {
        confirm(question: forms.discardQuestion(for: token), onKeepEditing: onKeepEditing, leave,
                askAgain: { [weak self] in self?.confirmLeaving(form: token, onKeepEditing: onKeepEditing, leave) })
    }

    private func confirm(question text: String?, onKeepEditing: @escaping () -> Void,
                         _ leave: @escaping () -> Void, askAgain: @escaping () -> Void) {
        guard !discarding, let text else { return leave() }
        guard asking == nil else {
            waiting.append(Waiting(text: text, leave: leave, keepEditing: onKeepEditing, askAgain: askAgain))
            return
        }
        asking = Question(text: text, discard: leave, keepEditing: onKeepEditing)
    }

    /// Discard settles only the waiting requests that would have asked **the same question**. One
    /// that would have named more — Quit behind Back on Add Service, which loses the group too —
    /// asks again on the next turn, after the discarded form has left and unregistered, so an
    /// answer about one form never discards another the user wasn't asked about.
    func discard() {
        guard let question = asking else { return }
        let queued = waiting
        asking = nil
        waiting = []
        let answered = queued.filter { $0.text == question.text }
        let unasked = queued.filter { $0.text != question.text }
        discarding = true
        question.discard()
        answered.forEach { $0.leave() }
        discarding = false
        guard !unasked.isEmpty else { return }
        DispatchQueue.main.async { unasked.forEach { $0.askAgain() } }
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
    /// `id` is the question that dialog showed, never the current one: a late dismissal of an
    /// answered question must not cancel the one asked after it — Quit re-asked behind Back
    /// would otherwise be refused without the user answering it.
    func dialogDismissed(_ id: UUID) {
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
    ///
    /// Pass `token` when something else on the form — its Cancel button — must ask about this same
    /// registration (`FormCancelButton`); otherwise the registration keeps a token of its own.
    func guardsUnsavedChanges(title: String, isDirty: Bool, token: UUID? = nil) -> some View {
        modifier(UnsavedChangesRegistration(title: title, isDirty: isDirty, suppliedToken: token))
    }
}

private struct UnsavedChangesRegistration: ViewModifier {
    let title: String
    let isDirty: Bool
    let suppliedToken: UUID?

    /// Optional: a header drawn outside the main window (a preview, a future sheet) has no guard
    /// to report to, and must not crash for it.
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    @State private var ownToken = UUID()
    private var token: UUID { suppliedToken ?? ownToken }

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

/// A form's **Cancel**: asks the same question as Back, and only when that form has changes.
///
/// Cancel used to close a changed form without a word while Back beside it asked. Give the form's
/// `FormHeader` the same `token` (`@State private var formToken = UUID()` on the form) and the two
/// answer for one registration. The button is also the form's Escape (`.cancelAction`), so every form
/// cancels the same way and a changed one asks first; callers must not add the shortcut again.
struct FormCancelButton: View {
    let token: UUID
    var title = "Cancel"
    let action: () -> Void

    @Environment(FormGuard.self) private var formGuard: FormGuard?

    var body: some View {
        Button(title) {
            if let formGuard { formGuard.confirmLeaving(form: token, action) } else { action() }
        }
        .keyboardShortcut(.cancelAction)
    }
}
