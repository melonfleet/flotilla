import Foundation
import Testing
@testable import FlotillaCore

/// The decision behind every way of leaving a form other than Back: the sidebar, menu commands,
/// ⌘K and Quit. Here rather than in the app for the reason `BusySetTests` gives.

@Test func aCleanFormDoesNotAsk() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "New Volume", isDirty: false)

    #expect(!forms.isDirty)
    #expect(forms.discardQuestion == nil)
}

@Test func aDirtyFormAsksByItsTitle() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "New Group", isDirty: true)

    #expect(forms.isDirty)
    #expect(forms.discardQuestion == "Discard your changes to New Group?")
}

/// Saving dismisses the form, and its disappearance removes it: a saved form never prompts.
@Test func aRemovedFormNoLongerAsks() {
    var forms = UnsavedForms()
    let token = UUID()
    forms.mark(token, title: "Run Container", isDirty: true)
    forms.remove(token)

    #expect(!forms.isDirty)
    #expect(forms.discardQuestion == nil)
}

/// Typing a change and then undoing it by hand leaves nothing to lose.
@Test func aFormMarkedCleanAgainIsForgotten() {
    var forms = UnsavedForms()
    let token = UUID()
    forms.mark(token, title: "New Machine", isDirty: true)
    forms.mark(token, title: "New Machine", isDirty: false)

    #expect(!forms.isDirty)
}

/// Removing what was never marked — every clean form's disappearance — is a no-op, and does not
/// disturb a dirty form beside it.
@Test func removingAnUnknownTokenLeavesOthersAlone() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "New Network", isDirty: true)
    forms.remove(UUID())

    #expect(forms.titles == ["New Network"])
}

/// One form marked twice is one form, and its title follows the latest mark — a DNS form's title is
/// the name being typed.
@Test func remarkingUpdatesTheTitleInPlace() {
    var forms = UnsavedForms()
    let token = UUID()
    forms.mark(token, title: "New Domain", isDirty: true)
    forms.mark(token, title: "web.test", isDirty: true)

    #expect(forms.titles == ["web.test"])
}

/// A group's own registration and its header's share a title while the group is on screen; the
/// question names it once.
@Test func sharedTitlesAreNamedOnce() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "Edit Group", isDirty: true)
    forms.mark(UUID(), title: "Edit Group", isDirty: true)

    #expect(forms.discardQuestion == "Discard your changes to Edit Group?")
}

@Test func severalFormsAreListedInOrder() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "New Group", isDirty: true)
    forms.mark(UUID(), title: "Add Service", isDirty: true)
    forms.mark(UUID(), title: "Run Container", isDirty: true)

    #expect(forms.discardQuestion == "Discard your changes to New Group, Add Service and Run Container?")
}

/// Removing one of two leaves the other asking — the group still holds edits after its service
/// editor closes.
@Test func removingOneOfTwoKeepsTheOther() {
    var forms = UnsavedForms()
    let group = UUID(), service = UUID()
    forms.mark(group, title: "New Group", isDirty: true)
    forms.mark(service, title: "Add Service", isDirty: true)
    forms.remove(service)

    #expect(forms.discardQuestion == "Discard your changes to New Group?")
}
