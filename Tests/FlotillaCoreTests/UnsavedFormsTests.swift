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

// MARK: Add Service and Edit Service (Kyle, 17 October)

/// A service the user saved is gone from the guard; the group above it, changed by that Save, is
/// what still asks — and asks for the group alone.
@Test func savingAServiceLeavesTheGroupAsking() {
    var forms = UnsavedForms()
    let group = UUID(), service = UUID()
    forms.mark(group, title: "New Group", isDirty: false)
    forms.mark(service, title: "Add Service", isDirty: true)
    #expect(forms.discardQuestion == "Discard your changes to Add Service?")

    // Save: the service screen goes, and the group's draft now holds the new member.
    forms.remove(service)
    forms.mark(group, title: "New Group", isDirty: true)

    #expect(forms.discardQuestion == "Discard your changes to New Group?")
}

private let stored = GroupMember(name: "db", image: "postgres:16", ports: ["5432:5432"],
                                 env: ["A=1", "B=2"], volumes: ["data:/var/lib/postgresql/data"],
                                 command: ["sh", "-c", "echo hi"], cpus: 2, memory: "512M",
                                 readyPort: 5432,
                                 secretEnv: [SecretEnv(name: "POSTGRES_PASSWORD", secret: "db")])

/// The screen's fields as it fills them from a stored member — what an untouched Edit Service shows.
private func typed(_ member: GroupMember, _ change: (inout [String: String]) -> Void = { _ in },
                   secretEnv: [SecretEnv]? = nil) -> String {
    var fields = ["name": member.name, "image": member.image,
                  "ports": member.ports.joined(separator: "\n"), "env": member.env.joined(separator: "\n"),
                  "volumes": member.volumes.joined(separator: "\n"), "command": ShellWords.join(member.command),
                  "cpus": member.cpus.map(String.init) ?? "", "memory": member.memory ?? "",
                  "readyPort": member.readyPort.map(String.init) ?? ""]
    change(&fields)
    return GroupMember.editSignature(name: fields["name"]!, image: fields["image"]!, ports: fields["ports"]!,
                                     env: fields["env"]!, volumes: fields["volumes"]!,
                                     command: fields["command"]!, cpus: fields["cpus"]!,
                                     memory: fields["memory"]!, readyPort: fields["readyPort"]!,
                                     secretEnv: secretEnv ?? member.secretEnv)
}

/// An Edit Service opened and left alone is clean: the screen's baseline and the stored member agree.
@Test func anUntouchedServiceMatchesItsStoredSignature() {
    #expect(typed(stored) == stored.editSignature)
}

/// Every field the service screen edits counts as an edit — the header used to say `false` for all.
@Test(arguments: ["name", "image", "ports", "env", "volumes", "command", "cpus", "memory", "readyPort"])
func everyServiceFieldMakesItDirty(_ field: String) {
    #expect(typed(stored) { $0[field, default: ""] += "x" } != stored.editSignature)
}

@Test func theServicesKeychainVariablesAreInItsSignature() {
    #expect(typed(stored, secretEnv: []) != stored.editSignature)
}

/// A command that does not split yet is still an edit — the parsed member would read it as none.
@Test func aHalfTypedCommandIsAnEdit() {
    let blank = GroupMember(name: "db", image: "postgres:16")
    #expect(typed(blank) { $0["command"] = "sh -c 'echo" } != blank.editSignature)
}

/// Moving a line from one field to the next is an edit, though every character is still there.
@Test func fieldBoundariesCannotCollide() {
    #expect(UnsavedForms.signature(["a\nb", "c"]) != UnsavedForms.signature(["a", "b\nc"]))
    #expect(UnsavedForms.signature(["ab", ""]) != UnsavedForms.signature(["a", "b"]))
}

/// The group compares every member field: a service saved with only its environment changed leaves
/// the group with something to lose.
@Test func aMembersEnvironmentIsPartOfTheGroupsSignature() {
    var changed = stored
    changed.env.append("C=3")
    #expect(changed.editSignature != stored.editSignature)
}

/// Back on Add Service names the service alone, though the group under it is dirty too.
@Test func aNestedFormsQuestionNamesOnlyThatForm() {
    var forms = UnsavedForms()
    let group = UUID(), service = UUID()
    forms.mark(group, title: "New Group", isDirty: true)
    forms.mark(service, title: "Add Service", isDirty: true)
    #expect(forms.discardQuestion(for: service) == "Discard your changes to Add Service?")
    #expect(forms.discardQuestion(for: group) == "Discard your changes to New Group?")
    #expect(forms.discardQuestion == "Discard your changes to New Group and Add Service?")
}

/// A clean or unknown form has nothing to lose, so Back and Cancel leave at once.
@Test func aCleanOrUnknownFormAsksNothing() {
    var forms = UnsavedForms()
    let token = UUID()
    #expect(forms.discardQuestion(for: token) == nil)
    forms.mark(token, title: "New Volume", isDirty: true)
    forms.mark(token, title: "New Volume", isDirty: false)
    #expect(forms.discardQuestion(for: token) == nil)
}

/// A dirty sibling does not make a clean form ask.
@Test func anotherFormsEditsDoNotMakeThisOneAsk() {
    var forms = UnsavedForms()
    forms.mark(UUID(), title: "New Group", isDirty: true)
    #expect(forms.discardQuestion(for: UUID()) == nil)
}
