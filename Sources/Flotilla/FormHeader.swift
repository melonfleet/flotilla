import AppKit
import SwiftUI

/// Back, icon, title, and the form's actions — the top bar of an embedded form screen.
///
/// **The actions are here, top right** (Q64, Kamal, 19 October): secondary buttons, Cancel
/// (`FormCancelButton`), then the commit (`FormPrimaryButton`), in `trailing`. There is no bottom
/// row: the Tasks drawer rises over the bottom of the page and covered it.
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
/// Back asks about unsaved changes through `FormGuard`, the same dialog every other route uses.
///
/// **In a split's page there is no Back** (Q58): a form shown as a row's page — a registry, a
/// domain, a group, a host — has its list beside it, so the header carries the list's ↑ ↓ and the
/// expand button instead, and leaving is choosing another row (which asks through the same guard).
/// The form's own Cancel or Done still closes it. Every other form is full width and keeps Back.
///
/// Deliberately the same shape as the detail headers in `ContainersView` and `MachinesView`, so
/// leaving a form and leaving a detail are the same gesture in the same place.
struct FormHeader<Trailing: View>: View {
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
    /// A small pill after the title — "This Mac" on this Mac's own page.
    var titleBadge: String? = nil
    /// System artwork drawn at 32pt in place of the symbol — a host page's Mac model.
    var leadingImage: NSImage? = nil
    /// Pass the form's own token when its Cancel button must ask about the same registration
    /// (`FormCancelButton`); a form with no Cancel leaves it nil.
    var token: UUID? = nil
    /// Controls that belong to the whole form rather than to a field: its actions (Cancel and the
    /// commit, Q64) and anything beside them, such as Group's "Save to File…".
    ///
    /// This slot is why the type is generic. Without it `MachineFormView` and `RunSheetView` each
    /// hand-rolled a header that was *nearly* this one, which is how the vertical padding came to
    /// differ three ways across the app: there were three copies of the number to keep in step
    /// and nobody kept them. One header, one number.
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
                    if let formGuard { formGuard.confirmLeaving(form: token ?? ownToken, onBack) } else { onBack() }
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
            Spacer()
            trailing
            if paneLayout != nil {
                if let paneActions { ActionCluster { paneActions.content } }
                DetailStepper()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .guardsUnsavedChanges(title: title, isDirty: hasUnsavedChanges, token: token ?? ownToken)
    }
}

/// Whether a form has been edited since it opened.
///
/// Compares a signature of the fields against the one captured when the screen appeared, rather
/// than against hardcoded defaults. Two reasons: a prefilled Run sheet opens full and that is not
/// unsaved work of the user's, and the forms whose defaults come from Settings ▸ Resources have no
/// constant to compare against in the first place.
struct FormEditTracker {
    private var opened: String?

    /// Call from `onAppear`. Idempotent — a re-appear must not re-baseline and quietly forget
    /// edits made before it.
    mutating func open(_ signature: String) {
        if opened == nil { opened = signature }
    }

    func isDirty(_ signature: String) -> Bool {
        guard let opened else { return false }
        return opened != signature
    }
}

extension FormHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, logo: Data? = nil, hasUnsavedChanges: Bool,
         onBack: @escaping () -> Void, token: UUID? = nil) {
        self.init(title: title, systemImage: systemImage, logo: logo,
                  hasUnsavedChanges: hasUnsavedChanges,
                  onBack: onBack, token: token, trailing: { EmptyView() })
    }
}

/// A form's commit — Save, Pull, Build, Run, Create — at the top right of its `FormHeader`, after
/// Cancel (Q64, Kamal, 19 October).
///
/// Forms committed from a bottom-right row until the Tasks drawer rose over it: starting a second
/// pull meant minimising the drawer to find the button. In the header it is always on screen,
/// whatever overlays the bottom of the page, and every form commits from the same place.
/// `Scripts/check-form-bounds.sh` holds the line: a screen with a `FormHeader` declares no
/// `.defaultAction` of its own and no footer.
struct FormPrimaryButton: View {
    let title: String
    var isDisabled = false
    var help: String? = nil
    let action: () -> Void

    init(_ title: String, isDisabled: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isDisabled)
            .help(help ?? "")
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
