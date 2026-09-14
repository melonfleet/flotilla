import SwiftUI
import OSLog
import FlotillaCore

/// The app's live `GroupBook`, persisted to the preference domain.
///
/// The same split as `TagStore`: `GroupBook` holds every rule and is Foundation-only so the test
/// target pins them on Linux; this class adds SwiftUI observation and storage and nothing else.
///
/// ## Why not `SettingsStore`
///
/// A group is the user's *content*, the same argument `TagStore` makes at length. `SettingsStore`
/// owns a closed registry where every key is declared once, carries a managed policy and appears
/// in the Jamf key list — correct for "poll interval", wrong for "the four containers Kamal runs
/// together". An admin pushing a group list over somebody's own groups is not a capability worth
/// building.
///
/// Written plist-native by the same rule: readable with `defaults read`, not a JSON blob.
///
/// ```
/// defaults read dev.melonfleet.Flotilla containerGroups
/// ```
///
/// **No starter groups.** Unlike tags, there is nothing sensible to seed — a starter tag palette
/// is useful before you have named anything, but a starter group would be a guess at what
/// somebody runs, and deleting four invented groups is worse than starting with none.
@MainActor
@Observable
final class GroupStore {

    /// Carries no group names, member names or images — a member name is a container name and an
    /// image reference can name a private registry. Records that a read or write failed, never
    /// what was in it. The same rule `TagStore.log` and `SettingsPersistence.log` follow.
    @ObservationIgnored
    private let log = Logger(subsystem: SettingsPersistence.domain, category: "groups")

    private(set) var book: GroupBook

    @ObservationIgnored
    private let defaults: UserDefaults?

    static let groupsKey = "containerGroups"

    init(defaults: UserDefaults? = TagStore.standardDefaults()) {
        self.defaults = defaults
        book = defaults.map(Self.read(from:)) ?? GroupBook()
    }

    // MARK: Reading

    var groups: [ContainerGroup] { book.groups }
    func group(_ id: String) -> ContainerGroup? { book.group(id) }
    var claimedNames: Set<String> { book.claimedNames }

    func problem(withName name: String, excluding id: String? = nil) -> String? {
        book.problem(withName: name, excluding: id)
    }
    func problem(withMemberName name: String, excluding memberID: String? = nil) -> String? {
        book.problem(withMemberName: name, excluding: memberID)
    }
    func problem(withImage image: String) -> String? { book.problem(withImage: image) }

    // MARK: Writing

    /// The last refusal, for the forms that can provoke one from a text field.
    var lastError: String?

    @discardableResult
    func createGroup(name: String, network: String?) -> ContainerGroup? {
        do {
            let group = try book.createGroup(name: name, network: network)
            persist()
            return group
        } catch {
            lastError = describe(error)
            return nil
        }
    }

    /// Commits a form's draft — the whole group, members and all, in one write.
    ///
    /// Throws rather than swallowing into `lastError`: the form shows a refusal in its own footer
    /// beside the Save button that caused it, which is where you are looking.
    func commit(_ draft: ContainerGroup) throws {
        try book.commit(draft)
        persist()
    }

    func rename(_ groupID: String, to name: String) {
        do { try book.rename(groupID, to: name); persist() } catch { lastError = describe(error) }
    }

    func setNetwork(_ network: String?, on groupID: String) {
        do { try book.setNetwork(network, on: groupID); persist() } catch { lastError = describe(error) }
    }

    func deleteGroup(_ groupID: String) {
        book.deleteGroup(groupID)
        persist()
    }

    @discardableResult
    func addMember(_ member: GroupMember, to groupID: String) -> Bool {
        do { try book.addMember(member, to: groupID); persist(); return true }
        catch { lastError = describe(error); return false }
    }

    @discardableResult
    func updateMember(_ member: GroupMember, in groupID: String) -> Bool {
        do { try book.updateMember(member, in: groupID); persist(); return true }
        catch { lastError = describe(error); return false }
    }

    func removeMember(_ memberID: String, from groupID: String) {
        book.removeMember(memberID, from: groupID)
        persist()
    }

    func moveMember(_ memberID: String, in groupID: String, to destination: Int) {
        book.moveMember(memberID, in: groupID, to: destination)
        persist()
    }

    private func describe(_ error: Error) -> String {
        (error as? GroupBook.GroupError)?.description ?? String(describing: error)
    }

    // MARK: Storage

    /// An array of dictionaries, each holding an array of dictionaries. Both are plist-native, so
    /// `defaults read` prints the whole thing legibly and `PlistBuddy` can edit it.
    ///
    /// Optional values are **absent** rather than written as a sentinel: an unset `cpus` means
    /// "let the CLI apply its own default", and writing `0` would mean something else.
    private func persist() {
        guard let defaults else { return }
        defaults.set(book.groups.map(Self.encode(_:)), forKey: Self.groupsKey)
    }

    private static func encode(_ group: ContainerGroup) -> [String: Any] {
        var row: [String: Any] = [
            "id": group.id,
            "name": group.name,
            "members": group.members.map(encode(_:)),
        ]
        if let network = group.network { row["network"] = network }
        return row
    }

    private static func encode(_ member: GroupMember) -> [String: Any] {
        var row: [String: Any] = ["id": member.id, "name": member.name, "image": member.image]
        if !member.ports.isEmpty { row["ports"] = member.ports }
        if !member.env.isEmpty { row["env"] = member.env }
        if !member.volumes.isEmpty { row["volumes"] = member.volumes }
        if !member.command.isEmpty { row["command"] = member.command }
        if let cpus = member.cpus { row["cpus"] = cpus }
        if let memory = member.memory { row["memory"] = memory }
        return row
    }

    /// A malformed entry is **skipped, not defaulted** — the same rule `TagStore.read` follows.
    /// The plist is hand-editable, so this is a real input: a member with no name is one the
    /// group could start and never stop again, and a group that quietly dropped it would be
    /// worse than one that is simply shorter.
    ///
    /// Rebuilt through `GroupBook`'s own mutators rather than by assigning the array directly, so
    /// a hand-edited plist that gives two groups the same `db` is refused on read by the rule
    /// that would have refused it in the form.
    private static func read(from defaults: UserDefaults) -> GroupBook {
        let rows = defaults.array(forKey: groupsKey) as? [[String: Any]] ?? []
        var book = GroupBook()
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let name = row["name"] as? String, !name.isEmpty
            else { continue }
            let network = (row["network"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let group = try? book.restoreGroup(id: id, name: name, network: network)
            else { continue }
            for raw in row["members"] as? [[String: Any]] ?? [] {
                guard let memberID = raw["id"] as? String, !memberID.isEmpty,
                      let memberName = raw["name"] as? String,
                      let image = raw["image"] as? String
                else { continue }
                let member = GroupMember(
                    id: memberID, name: memberName, image: image,
                    ports: raw["ports"] as? [String] ?? [],
                    env: raw["env"] as? [String] ?? [],
                    volumes: raw["volumes"] as? [String] ?? [],
                    command: raw["command"] as? [String] ?? [],
                    cpus: raw["cpus"] as? Int,
                    memory: raw["memory"] as? String)
                try? book.addMember(member, to: group.id)
            }
        }
        return book
    }
}
