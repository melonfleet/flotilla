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
/// in the Jamf key list — correct for "poll interval", wrong for "the four containers you run
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
        var repaired: [String: [String]] = [:]
        book = defaults.map { Self.read(from: $0, repaired: &repaired) } ?? GroupBook()
        unpublishedPorts = repaired
    }

    // MARK: Reading

    var groups: [ContainerGroup] { book.groups }

    /// Ports removed at load because they aren't port mappings (`127.0.0.1::80`, saved before the
    /// check existed), by member id, as they were written. Kept — and written back under
    /// `unpublishedPorts` — until the member's ports are edited or the owner keeps it without
    /// them, so the flag survives the next save instead of the removal quietly becoming permanent.
    /// The Containers list, the group's page and its form all show it, and Start won't create the
    /// member while it stands (Kyle, 20 October: it was a `lastError` nothing read).
    private(set) var unpublishedPorts: [String: [String]] = [:]

    /// The members of `group` still carrying a removed port, in listed order.
    func unpublished(in group: ContainerGroup) -> [(member: GroupMember, ports: [String])] {
        group.members.compactMap { member in
            unpublishedPorts[member.id].flatMap { $0.isEmpty ? nil : (member, $0) }
        }
    }

    /// Every group with such a member, for the Containers list's band.
    var groupsWithUnpublishedPorts: [ContainerGroup] {
        groups.filter { !unpublished(in: $0).isEmpty }
    }

    /// One sentence for a member's flag, the same on every screen that shows it.
    static func unpublishedSentence(_ member: String, _ ports: [String]) -> String {
        "\(member)'s port \(ports.joined(separator: ", ")) can't be published and was removed. Choose a host port, or keep it without one."
    }
    func group(_ id: String) -> ContainerGroup? { book.group(id) }
    func claimedNames(on host: HostRef) -> Set<String> { book.claimedNames(on: host) }

    func problem(withName name: String, excluding id: String? = nil) -> String? {
        book.problem(withName: name, excluding: id)
    }
    func problem(withMemberName name: String, excluding memberID: String? = nil,
                 on host: HostRef = .local) -> String? {
        book.problem(withMemberName: name, excluding: memberID, on: host)
    }
    func problem(withImage image: String) -> String? { book.problem(withImage: image) }

    // MARK: Writing

    /// The last refusal, for the forms that can provoke one from a text field.
    var lastError: String?

    @discardableResult
    func createGroup(name: String, network: String?, host: HostRef = .local) -> ContainerGroup? {
        do {
            let group = try book.createGroup(name: name, network: network, host: host)
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
        let before = book.group(draft.id)?.members ?? []
        try book.commit(draft)
        // A member whose ports were edited, or that is gone, has had its flag answered.
        for old in before where unpublishedPorts[old.id] != nil {
            let now = draft.members.first { $0.id == old.id }
            if now == nil || now?.ports != old.ports { unpublishedPorts[old.id] = nil }
        }
        persist()
    }

    /// The owner keeps these members without the removed ports: the flag goes, and so does the text.
    func keepWithoutUnpublishedPorts(_ memberIDs: Set<String>) {
        guard memberIDs.contains(where: { unpublishedPorts[$0] != nil }) else { return }
        for id in memberIDs { unpublishedPorts[id] = nil }
        persist()
    }

    func rename(_ groupID: String, to name: String) {
        do { try book.rename(groupID, to: name); persist() } catch { lastError = describe(error) }
    }

    func setNetwork(_ network: String?, on groupID: String) {
        do { try book.setNetwork(network, on: groupID); persist() } catch { lastError = describe(error) }
    }

    func deleteGroup(_ groupID: String) {
        for member in book.group(groupID)?.members ?? [] { unpublishedPorts[member.id] = nil }
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
        let old = book.group(groupID)?.members.first { $0.id == member.id }
        do {
            try book.updateMember(member, in: groupID)
            if old?.ports != member.ports { unpublishedPorts[member.id] = nil }
            persist()
            return true
        }
        catch { lastError = describe(error); return false }
    }

    func removeMember(_ memberID: String, from groupID: String) {
        book.removeMember(memberID, from: groupID)
        unpublishedPorts[memberID] = nil
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
        let unpublished = unpublishedPorts
        defaults.set(book.groups.map { Self.encode($0, unpublished: unpublished) }, forKey: Self.groupsKey)
    }

    private static func encode(_ group: ContainerGroup, unpublished: [String: [String]]) -> [String: Any] {
        var row: [String: Any] = [
            "id": group.id,
            "name": group.name,
            "members": group.members.map { encode($0, unpublished: unpublished[$0.id] ?? []) },
        ]
        if let network = group.network { row["network"] = network }
        if !group.notes.isEmpty { row["notes"] = group.notes }
        // The host's key, in full; absent for This Mac, so older groups read back unchanged.
        if case .peer(let fingerprint) = group.place { row["host"] = fingerprint.hex }
        return row
    }

    private static func encode(_ member: GroupMember, unpublished: [String]) -> [String: Any] {
        var row: [String: Any] = ["id": member.id, "name": member.name, "image": member.image]
        if !member.ports.isEmpty { row["ports"] = member.ports }
        if !member.env.isEmpty { row["env"] = member.env }
        if !member.volumes.isEmpty { row["volumes"] = member.volumes }
        if !member.command.isEmpty { row["command"] = member.command }
        if let cpus = member.cpus { row["cpus"] = cpus }
        if let memory = member.memory { row["memory"] = memory }
        if let readyPort = member.readyPort { row["readyPort"] = readyPort }
        // Names only — the values are in the Keychain (`KeychainSecrets`).
        if !member.secretEnv.isEmpty {
            row["secretEnv"] = member.secretEnv.map { ["name": $0.name, "secret": $0.secret] }
        }
        // Mount → owner, for a fresh volume's setup at Start; only the mounts it still has.
        let owners = member.requestedVolumeOwners
        if !owners.isEmpty {
            row["volumeOwners"] = owners.mapValues { ["uid": $0.uid, "gid": $0.gid] }
        }
        // What load removed and nobody has answered yet: the flag, and the text it was.
        if !unpublished.isEmpty { row["unpublishedPorts"] = unpublished }
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
    /// - Parameter repaired: member id → ports removed because they aren't port mappings. One saved
    ///   before the check existed (Dave, 19 October) could never start, but it is the user's service:
    ///   it is kept, the port is dropped, and the removal is flagged until answered — read back from
    ///   `unpublishedPorts` on later launches, so a save in between doesn't lose it.
    private static func read(from defaults: UserDefaults, repaired: inout [String: [String]]) -> GroupBook {
        let rows = defaults.array(forKey: groupsKey) as? [[String: Any]] ?? []
        var book = GroupBook()
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty,
                  let name = row["name"] as? String, !name.isEmpty
            else { continue }
            let network = (row["network"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A host key that doesn't parse is a damaged entry: skipped, not moved to This Mac,
            // where it would start containers the owner meant for another Mac.
            var host = HostRef.local
            if let raw = row["host"] {
                // Present but not a key — the wrong type, or text that doesn't parse — skips the
                // group: falling back to This Mac would run it against this Mac's containers
                // (Kyle, 12 October).
                guard let hex = raw as? String, let fingerprint = PeerFingerprint(hex: hex) else { continue }
                host = .peer(fingerprint)
            }
            guard let group = try? book.restoreGroup(id: id, name: name, network: network, host: host)
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
                    memory: raw["memory"] as? String,
                    readyPort: raw["readyPort"] as? Int,
                    secretEnv: (raw["secretEnv"] as? [[String: String]] ?? []).compactMap { entry in
                        guard let name = entry["name"], let secret = entry["secret"] else { return nil }
                        return SecretEnv(name: name, secret: secret)
                    },
                    volumeOwners: (raw["volumeOwners"] as? [String: [String: Int]] ?? [:]).compactMapValues { entry in
                        guard let uid = entry["uid"], let gid = entry["gid"] else { return nil }
                        let owner = VolumeOwner(uid: uid, gid: gid)
                        return owner.isValid ? owner : nil
                    })
                let flagged = raw["unpublishedPorts"] as? [String] ?? []
                do {
                    try book.addMember(member, to: group.id)
                    if !flagged.isEmpty { repaired[memberID] = flagged }
                } catch GroupBook.GroupError.invalidPort {
                    var kept = member
                    kept.ports = member.ports.filter { Allowlist.accepts($0, as: .portMapping) }
                    let dropped = member.ports.filter { !Allowlist.accepts($0, as: .portMapping) }
                    if (try? book.addMember(kept, to: group.id)) != nil { repaired[memberID] = flagged + dropped }
                } catch {}
            }
            book.setNotes(row["notes"] as? [String] ?? [], on: group.id)
        }
        return book
    }
}
