import AppKit
import SwiftUI

/// Back, icon, title, and the form's actions — the top bar of an embedded form screen.
///
/// **The actions are one cluster, top right** (Q65, Kamal, 19 October): ⋯ for the form's rare
/// extras, ✕ to close, and the commit as ▶ or ✓ — `FormActions`, drawn by this header and nothing
/// else. The slot takes a `FormActions` *value*, not a view, so no form can put a button of its own
/// in its header: the cluster has the same kinds of button in the same order on every form. Q64 had
/// put the actions here, as words that changed from form to form; there is still no bottom row,
/// because the Tasks drawer rises over the bottom of the page.
///
/// Forms stopped being modals on 9 August (the owner's call). `CLAUDE.md` used to record the
/// opposite rule — "a form is a question you answer and dismiss, a place is navigable" — and
/// that reasoning was sound right up until Machines grew an embedded detail with its own Back
/// button and tab strip. At that point a floating card with a red × was the only surface in the
/// app you left a different way, and consistency beat the taxonomy.
///
/// It also removed two real costs: every modal carried a hand-picked frame (560×680, 560×660,
/// 440 wide) that content had to be trimmed to fit, and the dim-plus-`allowsHitTesting` dance in
/// `MainWindowView` existed only to serve them.
///
/// Back and ✕ ask about unsaved changes through `FormGuard`, the same dialog every other route
/// uses, and both leave through `onBack`: every form's Cancel and Back already did the same thing.
///
/// **In a split's page there is no Back** (Q58): a form shown as a row's page — a registry, a
/// domain, a group, a host — has its list beside it, so the header carries the list's ↑ ↓ and the
/// expand button instead, and leaving is choosing another row (which asks through the same guard).
/// The form's ✕ still closes it. Every other form is full width and keeps Back.
///
/// Deliberately the same shape as the detail headers in `ContainersView` and `MachinesView`, so
/// leaving a form and leaving a detail are the same gesture in the same place.
struct FormHeader: View {
    let title: String
    let systemImage: String
    var logo: Data? = nil
    /// Whether leaving now would lose something.
    ///
    /// Required rather than defaulted to `false`: a form that forgets to say would lose the guard
    /// silently, and "a setting that drives nothing is worse than a missing one" is a lesson this
    /// project has already paid for. Every screen with a `FormHeader` is a form, so every one of
    /// them has an answer.
    ///
    /// It also answers for every *other* way out — the sidebar, menu commands, ⌘K and Quit — by
    /// registering with the window's `FormGuard`, so no form has to wire those up itself.
    let hasUnsavedChanges: Bool
    let onBack: () -> Void
    /// "2 of 3" — where a run of forms is, beside the title.
    var progress: String? = nil
    /// Pass the form's own token when something else on the form must ask about the same
    /// registration — Run's and a stack's Skip; a form with nothing else leaves it nil.
    var token: UUID? = nil
    /// The cluster: ⋯, ✕ and the commit (Q65). Data rather than a view builder — the reason this
    /// type is no longer generic. Its old `trailing` slot took any view, which is how every form
    /// came to draw its own words there.
    var actions = FormActions()

    @State private var ownToken = UUID()
    @Environment(FormGuard.self) private var formGuard: FormGuard?

    init(title: String, systemImage: String, logo: Data? = nil, hasUnsavedChanges: Bool,
         onBack: @escaping () -> Void, progress: String? = nil, token: UUID? = nil,
         actions: FormActions = FormActions()) {
        self.title = title
        self.systemImage = systemImage
        self.logo = logo
        self.hasUnsavedChanges = hasUnsavedChanges
        self.onBack = onBack
        self.progress = progress
        self.token = token
        self.actions = actions
    }

    private var guardToken: UUID { token ?? ownToken }

    var body: some View {
        PageHeader(title: title, systemImage: systemImage, logo: logo, progress: progress,
                   guardToken: guardToken, onBack: onBack) {
            FormActionCluster(actions: actions) {
                // ✕ asks the same question as Back, about this form alone.
                if let formGuard { formGuard.confirmLeaving(form: guardToken, onBack) } else { onBack() }
            }
        }
        .guardsUnsavedChanges(title: title, isDirty: hasUnsavedChanges, token: guardToken)
    }
}

/// A form's actions, as data (Q65, Kamal, 19 October): what its ⋯ menu holds, what its commit
/// does, and whether it is working. `FormHeader` draws them — always ⋯, ✕, then the commit, left to
/// right — so a form says *what* and never *how*.
///
/// **The commit is one of two glyphs**, chosen by what it does: ▶ (`play.fill`) when it starts a
/// job that then shows in Tasks — Run, Pull, Create a volume, Send to 3 Hosts — and ✓ (`checkmark`)
/// when it keeps changes here — a group, a registry, a tag. Its words moved to its tooltip and its
/// VoiceOver label, unchanged: "Push to 3 Hosts", "Sign In and Add". Return is the commit and
/// Escape is ✕, on every form.
struct FormActions {
    /// The commit, rightmost and filled with the accent.
    struct Commit {
        enum Effect {
            /// Starts a job that shows in Tasks.
            case startsJob
            /// Keeps changes: a definition saved, a registry added, a host paired.
            case keepsChanges

            var systemImage: String {
                switch self {
                case .startsJob: "play.fill"
                case .keepsChanges: "checkmark"
                }
            }
        }

        let effect: Effect
        /// Exactly what the button used to say. The tooltip and the spoken label.
        let label: String
        /// The same validation as before: disabled exactly when the old button was.
        var isDisabled = false
        /// Appended to the tooltip: why it cannot be pressed now, or what pressing it leads to.
        var reason: String? = nil
        let action: () -> Void

        static func startsJob(_ label: String, isDisabled: Bool = false, reason: String? = nil,
                              action: @escaping () -> Void) -> Commit {
            Commit(effect: .startsJob, label: label, isDisabled: isDisabled, reason: reason, action: action)
        }

        static func keepsChanges(_ label: String, isDisabled: Bool = false, reason: String? = nil,
                                 action: @escaping () -> Void) -> Commit {
            Commit(effect: .keepsChanges, label: label, isDisabled: isDisabled, reason: reason, action: action)
        }

        var help: String { reason.map { "\(label) — \($0)" } ?? label }
    }

    /// An item in ⋯: a form's rare extra — Delete…, Save to File…, Skip.
    struct Extra {
        let title: String
        var role: ButtonRole? = nil
        var isDisabled = false
        var help: String? = nil
        let action: () -> Void

        init(_ title: String, role: ButtonRole? = nil, isDisabled: Bool = false, help: String? = nil,
             action: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.isDisabled = isDisabled
            self.help = help
            self.action = action
        }
    }

    /// Nil on a form with nothing to commit — a domain being looked at, a registry that cannot sign
    /// in: it shows ✕ alone.
    var commit: Commit? = nil
    /// ⋯ appears only when there is something in it.
    var more: [Extra] = []
    /// A spinner in the cluster, where a form used to put one beside its buttons.
    var isWorking = false
    var workingHelp = "Working…"

    init(_ commit: Commit? = nil, more: [Extra] = [], isWorking: Bool = false,
         workingHelp: String = "Working…") {
        self.commit = commit
        self.more = more
        self.isWorking = isWorking
        self.workingHelp = workingHelp
    }
}

/// The cluster itself: the glass every header's actions sit in (`ActionCluster`), with
/// `IconActionButton`'s sizes, help and labels.
private struct FormActionCluster: View {
    let actions: FormActions
    let close: () -> Void

    var body: some View {
        ActionCluster {
            if actions.isWorking {
                // `IconActionButton`'s busy spinner, in its 18pt box.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .help(actions.workingHelp)
                    .accessibilityLabel(actions.workingHelp)
            }
            if !actions.more.isEmpty {
                ToolbarIconMenu(systemImage: "ellipsis", label: "More actions") {
                    ForEach(Array(actions.more.enumerated()), id: \.offset) { _, extra in
                        Button(extra.title, role: extra.role, action: extra.action)
                            .disabled(extra.isDisabled)
                            .help(ifAny: extra.help)
                    }
                }
            }
            IconActionButton(systemImage: "xmark", label: "Close", help: "Close (Esc)", action: close)
                .keyboardShortcut(.cancelAction)
            if let commit = actions.commit {
                Button(action: commit.action) {
                    Image(systemName: commit.effect.systemImage)
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(FormCommitButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(commit.isDisabled)
                .help(commit.help)
                .accessibilityLabel(commit.label)
            }
        }
    }
}

/// The commit's fill: the accent behind a white glyph, at `IconActionButtonStyle`'s padding, corner
/// and press scale, so it is the same size as ✕ beside it and reads as the one to press.
private struct FormCommitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.75))
                .padding(3)
                .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                            in: RoundedRectangle(cornerRadius: 5))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .contentShape(.rect)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
        }
    }
}

/// The header layout under `FormHeader`: Back, icon, title, then whatever the page puts at the
/// right, and in a split the list's actions and stepper.
///
/// **Forms do not use this; they use `FormHeader`.** It exists for the one page that is not a form
/// and has a header of the same shape — a host's page, whose Refresh and row actions are not a
/// form's commit. `Scripts/check-form-bounds.sh` allows it there and in this file only.
struct PageHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var logo: Data? = nil
    /// A small pill after the title — "This Mac" on this Mac's own page.
    var titleBadge: String? = nil
    /// System artwork drawn at 32pt in place of the symbol — a host page's Mac model.
    var leadingImage: NSImage? = nil
    var progress: String? = nil
    /// The registration Back asks about; nil for a page with none.
    var guardToken: UUID? = nil
    let onBack: () -> Void
    /// One header, one number: `MachineFormView` and `RunSheetView` each once hand-rolled a header
    /// that was *nearly* this one, which is how the vertical padding came to differ three ways.
    @ViewBuilder var trailing: Trailing

    @State private var ownToken = UUID()
    @Environment(FormGuard.self) private var formGuard: FormGuard?
    @Environment(\.paneLayout) private var paneLayout
    @Environment(\.paneHeaderActions) private var paneActions

    var body: some View {
        HStack(spacing: 10) {
            if paneLayout == nil {
                IconActionButton(systemImage: "chevron.left", label: "Back", help: "Back") {
                    // Through the guard, which asks the one discard question for this form alone.
                    if let formGuard { formGuard.confirmLeaving(form: guardToken ?? ownToken, onBack) } else { onBack() }
                }
            }
            if let leadingImage {
                Image(nsImage: leadingImage).resizable().scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            } else if let logo {
                SuggestionLogo(data: logo, category: nil, size: 32)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            if titleBadge != nil { ThisMacPill() }
            if let progress {
                Text(progress).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            // The row's own actions, then the page's, then the stepper: a form's ✓ or ▶ sits
            // closest to the right edge that the list's navigation leaves it.
            if paneLayout != nil, let paneActions { ActionCluster { paneActions.content } }
            trailing
            if paneLayout != nil { DetailStepper() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}


/// A line under a form's header — why its commit is disabled, an error from the last attempt, what
/// the commit will do — shown only while there is something to say (Q64). These sat beside the
/// buttons in the bottom row; with the buttons in the header, the words come directly under it,
/// still next to what they explain, and the header keeps to controls.
struct FormBand<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            content
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(2)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        Divider()
    }
}
