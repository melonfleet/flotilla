import Foundation
import Testing
@testable import FlotillaCore

// The merged Containers list (to-do item 4, 2026-10-05): groups and containers in one list, a
// grouped container shown only inside its group, and a kind filter that can collapse it back.
//
// The containers here are the first **captured** container from `containers.json`, with only its
// name and state changed. Fixtures are captured, never written; renaming a real record keeps every
// other field the CLI really emits.

private func captured() throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "containers", withExtension: "json",
                                             subdirectory: "Fixtures"))
    let all = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    return try #require(all.first)
}

private func container(_ name: String, running: Bool) throws -> Container {
    var record = try captured()
    record["id"] = name
    var configuration = try #require(record["configuration"] as? [String: Any])
    configuration["id"] = name
    record["configuration"] = configuration
    var status = try #require(record["status"] as? [String: Any])
    status["state"] = running ? "running" : "stopped"
    record["status"] = status
    let data = try JSONSerialization.data(withJSONObject: record)
    return try JSONDecoder.flotilla.decode(Container.self, from: data)
}

/// A WordPress-shaped group: db and site exist, cache was never started.
private func shop() -> ContainerGroup {
    ContainerGroup(name: "Shop", members: [
        GroupMember(name: "shop-db", image: "mysql:8"),
        GroupMember(name: "shop-web", image: "wordpress:6"),
        GroupMember(name: "shop-cache", image: "redis:7"),
    ])
}

private func names(_ items: [ContainerListing.Item]) -> [String] {
    items.map { item in
        switch item {
        case .container(let c): c.id
        case .group(let g, let members, _): "\(g.name)[\(members.map(\.member.name).joined(separator: ","))]"
        }
    }
}

@Test func aGroupedContainerAppearsOnlyInsideItsGroup() throws {
    let containers = [try container("shop-db", running: true),
                      try container("shop-web", running: false),
                      try container("scratch", running: true)]
    let items = ContainerListing.items(containers: containers, groups: [shop()], kind: .all, state: .all)
    // `scratch` is standalone; the two Shop containers appear only under Shop, never at top level.
    #expect(names(items) == ["scratch", "Shop[shop-db,shop-web,shop-cache]"])
}

@Test func aMemberWithNoContainerYetStillAppearsWithNoContainer() throws {
    let items = ContainerListing.items(containers: [try container("shop-db", running: true)],
                                       groups: [shop()], kind: .all, state: .all)
    guard case .group(_, let members, _) = try #require(items.first) else { Issue.record("not a group"); return }
    #expect(members.first { $0.member.name == "shop-cache" }?.container == nil)
    #expect(members.first { $0.member.name == "shop-db" }?.container?.id == "shop-db")
}

@Test func theContainersKindListsEveryContainerFlatIncludingMembers() throws {
    let containers = [try container("shop-db", running: true), try container("scratch", running: false)]
    let items = ContainerListing.items(containers: containers, groups: [shop()], kind: .containers, state: .all)
    // Exactly what the Containers screen showed before groups joined it.
    #expect(names(items) == ["shop-db", "scratch"])
}

@Test func theGroupsKindListsOnlyGroups() throws {
    let items = ContainerListing.items(containers: [try container("scratch", running: true)],
                                       groups: [shop(), ContainerGroup(name: "Empty")],
                                       kind: .groups, state: .all)
    #expect(names(items) == ["Shop[shop-db,shop-web,shop-cache]", "Empty[]"])
}

@Test func aPartlyRunningGroupIsBothRunningAndStopped() throws {
    let containers = [try container("shop-db", running: true), try container("shop-web", running: false)]
    let running = ContainerListing.items(containers: containers, groups: [shop()], kind: .all, state: .running)
    let stopped = ContainerListing.items(containers: containers, groups: [shop()], kind: .all, state: .stopped)
    // Under Running it opens onto its running member; under Stopped onto the rest, including the
    // never-created cache, which is the thing you would go looking for to start.
    #expect(names(running) == ["Shop[shop-db]"])
    #expect(names(stopped) == ["Shop[shop-web,shop-cache]"])
}

@Test func aFullyRunningGroupIsHiddenUnderStopped() throws {
    let group = ContainerGroup(name: "Pair", members: [GroupMember(name: "a", image: "x:1"),
                                                      GroupMember(name: "b", image: "x:1")])
    let containers = [try container("a", running: true), try container("b", running: true)]
    #expect(ContainerListing.items(containers: containers, groups: [group], kind: .all, state: .stopped).isEmpty)
    #expect(names(ContainerListing.items(containers: containers, groups: [group], kind: .all, state: .running))
            == ["Pair[a,b]"])
}

@Test func aSearchThatMatchesAMemberShowsTheGroupOpenOnThatMember() throws {
    let containers = [try container("shop-db", running: true), try container("shop-web", running: true)]
    let items = ContainerListing.items(
        containers: containers, groups: [shop()], kind: .all, state: .all,
        containerMatches: { $0.id.contains("web") },
        groupMatches: { $0.name.lowercased().contains("web") },
        memberMatches: { $0.name.contains("web") })
    guard case .group(let group, let members, let expand) = try #require(items.first) else {
        Issue.record("expected the group"); return
    }
    #expect(group.name == "Shop")
    #expect(members.map(\.member.name) == ["shop-web"])
    #expect(expand)
}

@Test func aSearchThatMatchesTheGroupKeepsAllItsMembersAndDoesNotForceItOpen() throws {
    let items = ContainerListing.items(
        containers: [try container("shop-db", running: true)], groups: [shop()], kind: .all, state: .all,
        containerMatches: { _ in false },
        groupMatches: { $0.name == "Shop" },
        memberMatches: { _ in false })
    guard case .group(_, let members, let expand) = try #require(items.first) else {
        Issue.record("expected the group"); return
    }
    #expect(members.count == 3)
    #expect(!expand)
}

@Test func aNeverCreatedMemberIsFoundByTheNameItWillBeCreatedWith() throws {
    let items = ContainerListing.items(
        containers: [], groups: [shop()], kind: .all, state: .all,
        containerMatches: { _ in false },
        groupMatches: { _ in false },
        memberMatches: { $0.name == "shop-cache" })
    #expect(names(items) == ["Shop[shop-cache]"])
}

@Test func aSearchMatchingNothingInAGroupDropsIt() throws {
    let items = ContainerListing.items(
        containers: [try container("scratch", running: true)], groups: [shop()], kind: .all, state: .all,
        containerMatches: { $0.id == "scratch" },
        groupMatches: { _ in false },
        memberMatches: { _ in false })
    #expect(names(items) == ["scratch"])
}
