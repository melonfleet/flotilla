import Foundation
import Testing
@testable import FlotillaCore

// MARK: - Group names

@Test func aGroupNeedsAName() {
    var book = GroupBook()
    #expect(throws: GroupBook.GroupError.emptyName) { try book.createGroup(name: "   ") }
    #expect(book.groups.isEmpty)
}

@Test func groupNamesAreTrimmedAndUniquePerName() throws {
    var book = GroupBook()
    let made = try book.createGroup(name: "  Shop  ")
    #expect(made.name == "Shop")
    #expect(throws: GroupBook.GroupError.duplicateName("shop")) { try book.createGroup(name: "shop") }
}

@Test func renamingAGroupDoesNotCollideWithItself() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    try book.rename(group.id, to: "SHOP")
    #expect(book.group(group.id)?.name == "SHOP")
}

/// The id is minted once so a rename keeps the group's members, the same reason `Tag.id` is not
/// its name.
@Test func renamingAGroupKeepsItsMembers() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    try book.addMember(GroupMember(name: "db", image: "postgres:16"), to: group.id)
    try book.rename(group.id, to: "Storefront")
    #expect(book.group(group.id)?.members.map(\.name) == ["db"])
}

// MARK: - Members

@Test func aMemberMustBeNamedBecauseTheGroupStopsWhatItStarted() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    #expect(throws: GroupBook.GroupError.emptyMemberName) {
        try book.addMember(GroupMember(name: "", image: "redis:7"), to: group.id)
    }
}

@Test func aMemberNameMustBeAValidContainerIdentifier() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    #expect(throws: GroupBook.GroupError.invalidMemberName("my db")) {
        try book.addMember(GroupMember(name: "my db", image: "redis:7"), to: group.id)
    }
}

@Test func aMemberNeedsAValidImage() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    #expect(throws: GroupBook.GroupError.emptyImage) {
        try book.addMember(GroupMember(name: "db", image: " "), to: group.id)
    }
    #expect(throws: GroupBook.GroupError.invalidImage("not a ref")) {
        try book.addMember(GroupMember(name: "db", image: "not a ref"), to: group.id)
    }
}

/// The rule that is easy to get wrong: container names are global on the Mac, so two *different*
/// groups cannot both own a `db`. Scoping uniqueness to one group would let the user build two
/// groups that can never both be running and find out at `container run` time.
@Test func memberNamesAreUniqueAcrossTheWholeBookNotJustOneGroup() throws {
    var book = GroupBook()
    let shop = try book.createGroup(name: "Shop")
    let blog = try book.createGroup(name: "Blog")
    try book.addMember(GroupMember(name: "db", image: "postgres:16"), to: shop.id)
    #expect(throws: GroupBook.GroupError.duplicateMemberName("db", inGroup: "Shop")) {
        try book.addMember(GroupMember(name: "DB", image: "mysql:8"), to: blog.id)
    }
}

@Test func editingAMemberDoesNotReportItAsAClashWithItself() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    let member = try book.addMember(GroupMember(name: "db", image: "postgres:16"), to: group.id)
    var edited = member
    edited.image = "postgres:17"
    try book.updateMember(edited, in: group.id)
    #expect(book.group(group.id)?.members.first?.image == "postgres:17")
}

@Test func membersKeepTheOrderTheyWereAddedIn() throws {
    var book = GroupBook()
    let group = try book.createGroup(name: "Shop")
    for name in ["db", "cache", "api", "web"] {
        try book.addMember(GroupMember(name: name, image: "alpine:3.22"), to: group.id)
    }
    #expect(book.group(group.id)?.memberNames == ["db", "cache", "api", "web"])
    let api = try #require(book.group(group.id)?.members.first { $0.name == "api" })
    book.moveMember(api.id, in: group.id, to: 0)
    #expect(book.group(group.id)?.memberNames == ["api", "db", "cache", "web"])
}

@Test func deletingAGroupReleasesTheNamesItClaimed() throws {
    var book = GroupBook()
    let shop = try book.createGroup(name: "Shop")
    try book.addMember(GroupMember(name: "db", image: "postgres:16"), to: shop.id)
    #expect(book.claimedNames == ["db"])
    book.deleteGroup(shop.id)
    #expect(book.claimedNames.isEmpty)
    let blog = try book.createGroup(name: "Blog")
    #expect(throws: Never.self) {
        try book.addMember(GroupMember(name: "db", image: "mysql:8"), to: blog.id)
    }
}

// MARK: - Derived state

@Test func anEmptyGroupIsEmptyRatherThanStopped() {
    let group = ContainerGroup(name: "Shop")
    #expect(group.state(runningNames: [], existingNames: []) == .empty)
}

@Test func stateIsDerivedFromTheLiveHostNotFromAnythingStored() {
    let group = ContainerGroup(name: "Shop", members: [
        GroupMember(name: "db", image: "postgres:16"),
        GroupMember(name: "web", image: "nginx:alpine"),
    ])
    #expect(group.state(runningNames: ["db", "web"], existingNames: ["db", "web"]) == .running)
    #expect(group.state(runningNames: [], existingNames: ["db", "web"]) == .stopped)
    #expect(group.state(runningNames: ["db"], existingNames: ["db", "web"]) == .partial(running: 1, of: 2))
    #expect(group.state(runningNames: [], existingNames: []) == .notCreated)
}

/// Half-created is not "stopped": Start and Stop mean different things when one member has never
/// been run, and a badge that said "stopped" would hide that.
@Test func aPartlyCreatedGroupIsPartialNotStopped() {
    let group = ContainerGroup(name: "Shop", members: [
        GroupMember(name: "db", image: "postgres:16"),
        GroupMember(name: "web", image: "nginx:alpine"),
    ])
    #expect(group.state(runningNames: [], existingNames: ["db"]) == .partial(running: 0, of: 2))
}

// MARK: - What a member submits

@Test func aMemberAlwaysDetachesAndNeverRemovesItself() {
    let member = GroupMember(name: "db", image: "postgres:16", ports: ["5432:5432"])
    let options = member.runOptions(network: "shopnet")
    #expect(options.detach)
    #expect(!options.rm)
    #expect(options.name == "db")
    #expect(options.network == "shopnet")
    #expect(options.ports == ["5432:5432"])
}

@Test func aGroupWithNoNetworkLeavesTheFlagUnset() {
    let member = GroupMember(name: "db", image: "postgres:16")
    #expect(member.runOptions(network: nil).network == nil)
}

// MARK: - The Flotillafile bridge

@Test func aFlotillafileContainerEntryReadsAsAMember() {
    let spec = ContainerSpec(name: "web", image: "docker.io/library/nginx:latest",
                             ports: ["8080:80"], env: ["DEBUG=1"], volumes: ["data:/var/lib"],
                             cpus: 2, memory: "512M")
    let member = GroupMember(spec)
    #expect(member.name == "web")
    #expect(member.image == "docker.io/library/nginx:latest")
    #expect(member.ports == ["8080:80"])
    #expect(member.env == ["DEBUG=1"])
    #expect(member.volumes == ["data:/var/lib"])
    #expect(member.cpus == 2)
    #expect(member.memory == "512M")
    // The format carries no command, and an absent key there means "run the image's own".
    #expect(member.command.isEmpty)
}

@Test func aMemberRoundTripsThroughTheFileFormatUnlessItOverridesTheCommand() {
    let plain = GroupMember(name: "web", image: "nginx:alpine", ports: ["8080:80"])
    #expect(plain.isFullyRepresentableAsSpec)
    #expect(GroupMember(plain.spec).spec == plain.spec)

    let overriding = GroupMember(name: "api", image: "python:3.12", command: ["python", "-m", "app"])
    #expect(!overriding.isFullyRepresentableAsSpec)
    #expect(GroupMember(overriding.spec).command.isEmpty)
}
