import Foundation

/// One service in a group: an image, the name its container will take, and the same run options
/// the Run form already collects.
///
/// ## Why this is not `ContainerSpec`
///
/// `Flotillafile.ContainerSpec` describes the same seven fields, and the overlap is deliberate
/// rather than accidental — `init(_ spec:)` and `spec` below convert between them, so the day
/// Flotillafile import is un-withheld it maps straight onto a group instead of growing a second
/// importer.
///
/// They stay separate types because they have different lifecycles. `ContainerSpec` is a *file
/// format*: immutable, version-pinned, and parsed from something a stranger may have sent, which
/// is why its parser refuses unknown keys outright. Adding `id` and `command` to it to suit a
/// form would be changing that format — and the format is withheld from this release precisely
/// because it is not settled. This type is the app's own editable record: it needs a stable `id`
/// so a rename does not detach a member from the row being edited, and a `command`, which the
/// file format does not carry.
///
/// **The name is required, and that is the load-bearing rule.** `container run` without `--name`
/// assigns a random id, so a group that let a member go unnamed could start it and then have no
/// way to find it again — Stop Group and the running/stopped badge both work by matching these
/// names against the live container list. An unnameable member is a member the group cannot
/// manage, which is worse than one it refuses to accept.
public struct GroupMember: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// The container's name, and the group's only handle on it once it is running.
    public var name: String
    /// `[registry[:port]/]name[:tag]`, exactly as the Run form takes it.
    public var image: String
    public var ports: [String]
    public var env: [String]
    public var volumes: [String]
    /// Overrides the image's own entrypoint arguments. Empty means "run what the image runs".
    public var command: [String]
    public var cpus: Int?
    public var memory: String?

    public init(id: String = UUID().uuidString, name: String, image: String,
                ports: [String] = [], env: [String] = [], volumes: [String] = [],
                command: [String] = [], cpus: Int? = nil, memory: String? = nil) {
        self.id = id
        self.name = name
        self.image = image
        self.ports = ports
        self.env = env
        self.volumes = volumes
        self.command = command
        self.cpus = cpus
        self.memory = memory
    }
}

/// A named set of containers that start and stop together.
///
/// ## What this is, and the line it does not cross
///
/// A group is a **remembered form submission**, not an orchestrator. Starting one issues the same
/// `container run` per member that the Run form issues for one container, in the order the
/// members are listed, through the same allowlist. It adds no new command to the boundary.
///
/// Deliberately absent, and each for its own reason:
///
/// - **No dependency graph and no health gating.** "Start the database, wait until it answers,
///   then start the app" needs a supervisor that keeps watching after the last command returns.
///   That supervisor is the thing `PLAN.md` rules out, and half of one — a fixed sleep, or a
///   readiness check that gives up — is worse than none, because it looks like it works.
/// - **No restart policy.** Same reason, plus `Q18`: Flotilla cannot currently observe that a
///   container failed, so a policy keyed on failure would be keyed on nothing.
/// - **No `docker-compose.yml` import.** A Compose file describes `depends_on`, health checks and
///   scaling, none of which a group honours. Reading one and silently dropping three quarters of
///   its meaning would be the overpromise this feature is trying not to make.
///
/// ## One network, at the group
///
/// Networks are mutually isolated — a container on `default` cannot reach one on a custom network
/// at all — so members spread across networks would be a group whose parts cannot talk. And
/// `--network` is creation-time only for every one of them. So the network is chosen once, for
/// the group, rather than per member.
///
/// ## Nothing about "running" is stored
///
/// There is no `isRunning` field here and there will not be one. The group's state is *derived*
/// from the live container list by `state(runningNames:existingNames:)` every time it is asked.
/// A stored flag would be wrong the moment somebody stopped a member from the Containers table,
/// from the menu bar, or from the CLI in another window.
public struct ContainerGroup: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public var name: String
    /// `--network` for every member. `nil` leaves it unset, and `container` picks `default`.
    public var network: String?
    /// Start order. The one thing ordering buys without a supervisor: a database listed first is
    /// *launched* first, which is not the same as being *ready* first, and the UI must not
    /// suggest otherwise.
    public var members: [GroupMember]

    public init(id: String = UUID().uuidString, name: String,
                network: String? = nil, members: [GroupMember] = []) {
        self.id = id
        self.name = name
        self.network = network
        self.members = members
    }

    public var memberNames: [String] { members.map(\.name) }
}

/// How much of a group is up, derived fresh from the live container list.
public enum GroupState: Sendable, Equatable, Hashable {
    /// No members yet. A group in this state cannot be started, and the UI disables Start rather
    /// than offering a button that would issue nothing.
    case empty
    /// No member exists on this Mac at all.
    case notCreated
    /// Every member exists and none is running.
    case stopped
    /// Some running, some not — including the case where a member was never created.
    case partial(running: Int, of: Int)
    /// Every member is running.
    case running
}

extension ContainerGroup {
    /// Derives the group's state by matching member names against what the host actually has.
    ///
    /// Foundation-only and pure, so the table badge, the Start/Stop enablement and the tests all
    /// read the same rule rather than three views of it.
    public func state(runningNames: Set<String>, existingNames: Set<String>) -> GroupState {
        guard !members.isEmpty else { return .empty }
        let names = memberNames
        let running = names.filter(runningNames.contains).count
        let existing = names.filter(existingNames.contains).count
        if running == names.count { return .running }
        if running > 0 { return .partial(running: running, of: names.count) }
        if existing == 0 { return .notCreated }
        return existing == names.count ? .stopped : .partial(running: 0, of: names.count)
    }
}

/// Every group the user has, and the rules about what may go in one.
///
/// The same split as `TagBook`: the rules live here, Foundation-only, so the test target pins
/// them on Linux; the app layer adds observation and storage and nothing else.
public struct GroupBook: Sendable, Equatable {
    public private(set) var groups: [ContainerGroup]

    public init(groups: [ContainerGroup] = []) { self.groups = groups }

    public enum GroupError: Error, Equatable, CustomStringConvertible {
        case emptyName
        case duplicateName(String)
        case unknownGroup
        case emptyMemberName
        case invalidMemberName(String)
        /// A container name is global on this Mac, so the clash is reported across the whole
        /// book, not just within one group — two groups each owning a `db` could never both run.
        case duplicateMemberName(String, inGroup: String)
        case emptyImage
        case invalidImage(String)

        public var description: String {
            switch self {
            case .emptyName:
                "A group needs a name."
            case .duplicateName(let name):
                "A group called “\(name)” already exists."
            case .unknownGroup:
                "That group no longer exists."
            case .emptyMemberName:
                "Each service needs a container name — it is how the group stops what it started."
            case .invalidMemberName(let name):
                "“\(name)” cannot be a container name. \(ValueShape.identifier.rule)"
            case .duplicateMemberName(let name, let group):
                "“\(name)” is already used by the group “\(group)”. Container names are shared across this Mac, so two of them cannot run at once."
            case .emptyImage:
                "Each service needs an image."
            case .invalidImage(let image):
                "“\(image)” is not a valid image reference. \(ValueShape.imageReference.rule)"
            }
        }
    }

    // MARK: Reading

    public func group(_ id: String) -> ContainerGroup? { groups.first { $0.id == id } }

    /// Every container name the book has spoken for, so a caller can tell at a glance whether a
    /// name typed into the Run form is about to collide with a group.
    public var claimedNames: Set<String> {
        Set(groups.flatMap(\.memberNames))
    }

    // MARK: Group names

    /// Why a group name would be refused, or `nil` if it is fine. Same shape as
    /// `TagBook.problem(withName:excluding:)`: the form asks before it submits, so a refusal is
    /// shown while you are typing rather than after you press Save.
    public func problem(withName raw: String, excluding id: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return GroupError.emptyName.description }
        if groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return GroupError.duplicateName(name).description
        }
        return nil
    }

    /// Why a member's container name would be refused, or `nil`. `excluding` is the member's own
    /// id, so editing a member does not report it as a clash with itself.
    public func problem(withMemberName raw: String, excluding memberID: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return GroupError.emptyMemberName.description }
        guard Allowlist.accepts(name, as: .identifier) else {
            return GroupError.invalidMemberName(name).description
        }
        for group in groups {
            for member in group.members
            where member.id != memberID && member.name.caseInsensitiveCompare(name) == .orderedSame {
                // `member.name`, not what was just typed. Names compare case-insensitively
                // because container names do, so typing `DB` can clash with an existing `db` —
                // and a message that said “DB is already used” would send the user looking for
                // a `DB` that is not there.
                return GroupError.duplicateMemberName(member.name, inGroup: group.name).description
            }
        }
        return nil
    }

    /// The same question, asked by a form about a group that is **not in the book yet**.
    ///
    /// A form must not write until Save, so while you are building a group its members exist only
    /// in the draft. Validating against the book alone would miss a clash between two services in
    /// the group you are typing; validating against the book *including* the stored copy of the
    /// group you are editing would report every unchanged member as a clash with itself. So the
    /// caller passes both halves: which stored group to ignore, and what the draft currently
    /// holds.
    ///
    /// - Parameters:
    ///   - memberID: the member being edited, excluded from the clash check so it does not
    ///     collide with itself.
    ///   - groupID: the stored group this draft replaces, or `nil` when the group is new.
    ///   - draftMembers: the draft's members, including the one being edited.
    public func draftProblem(withMemberName raw: String, excluding memberID: String?,
                             editing groupID: String?,
                             draftMembers: [GroupMember]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return GroupError.emptyMemberName.description }
        guard Allowlist.accepts(name, as: .identifier) else {
            return GroupError.invalidMemberName(name).description
        }
        for group in groups where group.id != groupID {
            for member in group.members
            where member.name.caseInsensitiveCompare(name) == .orderedSame {
                return GroupError.duplicateMemberName(member.name, inGroup: group.name).description
            }
        }
        for member in draftMembers
        where member.id != memberID && member.name.caseInsensitiveCompare(name) == .orderedSame {
            // Within the draft there is no other group to name, so the message says where it is.
            return "“\(member.name)” is already a service in this group."
        }
        return nil
    }

    /// Why an image reference would be refused, or `nil`.
    public func problem(withImage raw: String) -> String? {
        let image = raw.trimmingCharacters(in: .whitespaces)
        if image.isEmpty { return GroupError.emptyImage.description }
        guard Allowlist.accepts(image, as: .imageReference) else {
            return GroupError.invalidImage(image).description
        }
        return nil
    }

    // MARK: Writing

    @discardableResult
    public mutating func createGroup(name rawName: String, network: String? = nil) throws -> ContainerGroup {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GroupError.emptyName }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw GroupError.duplicateName(name) }
        let group = ContainerGroup(name: name, network: network)
        groups.append(group)
        return group
    }

    /// Puts a group back with the id it was stored under — the path storage uses on launch.
    ///
    /// Deliberately not `createGroup`, which mints a fresh id. A group whose id changed every
    /// launch would break anything that remembers one: the selected row, a detail screen, a
    /// window restored into a group that no longer answers to that name.
    ///
    /// Validated exactly as `createGroup` is, because a hand-edited plist is an input like any
    /// other. Members are added afterwards through `addMember`, which keeps *their* ids too.
    @discardableResult
    public mutating func restoreGroup(id: String, name rawName: String,
                                      network: String?) throws -> ContainerGroup {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GroupError.emptyName }
        guard !groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw GroupError.duplicateName(name) }
        // A duplicated id is a corrupt store, not a name clash, but it has the same cure: keep
        // the first and drop the second, rather than ending up with two rows that cannot be
        // told apart.
        guard !groups.contains(where: { $0.id == id }) else { throw GroupError.duplicateName(name) }
        let group = ContainerGroup(id: id, name: name, network: network)
        groups.append(group)
        return group
    }

    public mutating func rename(_ id: String, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GroupError.emptyName }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw GroupError.unknownGroup }
        guard !groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw GroupError.duplicateName(name) }
        groups[index].name = name
    }

    public mutating func setNetwork(_ network: String?, on id: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw GroupError.unknownGroup }
        groups[index].network = network?.isEmpty == true ? nil : network
    }

    /// Commits a form's draft: replaces the stored group of the same id, or adds it if new.
    ///
    /// One call rather than delete-then-add at the call site, so a rejected draft cannot leave
    /// the book with the old group already gone.
    public mutating func commit(_ draft: ContainerGroup) throws {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GroupError.emptyName }
        guard !groups.contains(where: { $0.id != draft.id
                                        && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { throw GroupError.duplicateName(name) }

        var candidate = self
        candidate.groups.removeAll { $0.id == draft.id }
        try candidate.restoreGroup(id: draft.id, name: name, network: draft.network)
        for member in draft.members {
            try candidate.addMember(member, to: draft.id)
        }
        // Only now does the real book change: a draft that fails validation half way through
        // leaves the stored group exactly as it was.
        self = candidate
    }

    public mutating func deleteGroup(_ id: String) {
        groups.removeAll { $0.id == id }
    }

    /// Adds a service to a group, validating the name and image the same way the form does.
    ///
    /// Validation lives here rather than only in the view because the plist is hand-editable and
    /// a group is started from more than one place.
    @discardableResult
    public mutating func addMember(_ member: GroupMember, to groupID: String) throws -> GroupMember {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { throw GroupError.unknownGroup }
        var checked = member
        checked.name = member.name.trimmingCharacters(in: .whitespaces)
        checked.image = member.image.trimmingCharacters(in: .whitespaces)
        try validate(checked, excluding: nil)
        groups[index].members.append(checked)
        return checked
    }

    public mutating func updateMember(_ member: GroupMember, in groupID: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { throw GroupError.unknownGroup }
        guard let slot = groups[index].members.firstIndex(where: { $0.id == member.id })
        else { throw GroupError.unknownGroup }
        var checked = member
        checked.name = member.name.trimmingCharacters(in: .whitespaces)
        checked.image = member.image.trimmingCharacters(in: .whitespaces)
        try validate(checked, excluding: member.id)
        groups[index].members[slot] = checked
    }

    public mutating func removeMember(_ memberID: String, from groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].members.removeAll { $0.id == memberID }
    }

    /// Moves a member within its group's start order.
    public mutating func moveMember(_ memberID: String, in groupID: String, to destination: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              let from = groups[index].members.firstIndex(where: { $0.id == memberID }),
              destination >= 0, destination < groups[index].members.count
        else { return }
        let member = groups[index].members.remove(at: from)
        groups[index].members.insert(member, at: destination)
    }

    private func validate(_ member: GroupMember, excluding memberID: String?) throws {
        guard !member.name.isEmpty else { throw GroupError.emptyMemberName }
        guard Allowlist.accepts(member.name, as: .identifier)
        else { throw GroupError.invalidMemberName(member.name) }
        for group in groups {
            for existing in group.members
            where existing.id != memberID
                && existing.name.caseInsensitiveCompare(member.name) == .orderedSame {
                // The existing spelling, for the reason given in `problem(withMemberName:)`.
                throw GroupError.duplicateMemberName(existing.name, inGroup: group.name)
            }
        }
        guard !member.image.isEmpty else { throw GroupError.emptyImage }
        guard Allowlist.accepts(member.image, as: .imageReference)
        else { throw GroupError.invalidImage(member.image) }
    }
}

extension GroupMember {
    /// The run options this member submits, which is the whole of what a group adds to `run`.
    ///
    /// `detach` is **forced true and is not a field**: members start one after another, and a
    /// member that held the foreground would stop the rest of the group from ever starting.
    ///
    /// `rm` is **forced false, also not a field**. A group is stopped and started again; a member
    /// that removed itself on exit would take its container — and the name the group tracks it
    /// by — with it, so the next Start would be creating something new rather than starting
    /// something back up.
    public func runOptions(network: String?) -> ContainerCLI.RunOptions {
        ContainerCLI.RunOptions(name: name, ports: ports, env: env, volumes: volumes,
                                detach: true, rm: false, cpus: cpus, memory: memory,
                                network: network)
    }
}

extension GroupMember {
    /// Reads a Flotillafile `containers` entry as a group member.
    ///
    /// The file format has no `command`, so it comes across empty — the image runs its own
    /// entrypoint, which is what an absent key means there.
    public init(_ spec: ContainerSpec) {
        self.init(name: spec.name, image: spec.image, ports: spec.ports, env: spec.env,
                  volumes: spec.volumes, command: [], cpus: spec.cpus, memory: spec.memory)
    }

    /// The Flotillafile form of this member, for a future export.
    ///
    /// Lossy in exactly one direction and the caller must know it: `command` has nowhere to go
    /// in the current format. A group that overrides an entrypoint cannot be written out
    /// faithfully until the format carries one, which is one more reason it is not settled.
    public var spec: ContainerSpec {
        ContainerSpec(name: name, image: image, ports: ports, env: env, volumes: volumes,
                      cpus: cpus, memory: memory)
    }

    /// Whether `spec` would lose something. The UI uses this to say so rather than exporting
    /// quietly and handing back a file that starts a different container.
    public var isFullyRepresentableAsSpec: Bool { command.isEmpty }
}
