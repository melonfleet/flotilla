import Foundation
import Testing
@testable import FlotillaCore

@Suite("Group members from picks")
struct GroupMembersTests {
    private func entry(_ id: String, image: String, ports: [String] = [], env: [String] = [],
                       secrets: [String] = [], volumes: [LibraryVolume] = []) -> LibraryEntry {
        LibraryEntry(id: id, title: id, summary: "", categories: ["Databases"], kind: .container,
                     tested: .init(date: "2026-10-12", macs: 1),
                     container: LibraryContainer(image: image, name: id, ports: ports, env: env,
                                                 secretEnv: secrets, volumes: volumes))
    }

    private func pick(_ entry: LibraryEntry) -> GroupMembers.Pick { GroupMembers.Pick(entry: entry)! }

    private let postgres = LibraryVolume(suffix: "data", path: "/var/lib/postgresql/data")

    @Test("a stack's volumes are the shared mapping's, name for name")
    func stackUsesTheSharedMapping() throws {
        let wordpress = StackSuggestion.catalogue.first { $0.id == "wordpress" }!
        let plan = try StackPlanner.plan(wordpress, choices: StackChoices(name: "blog", webPorts: ["site": 8082]),
                                         wiring: .names(domain: "flotilla"), usedHostPorts: [])
        for (service, member) in zip(wordpress.services, plan.group.members) {
            let built = GroupMembers.member(named: member.name, image: service.image, ports: member.ports,
                                            env: member.env, secretEnv: service.secretEnv,
                                            volumes: service.volumes, command: service.command,
                                            readyPort: service.readyPort)
            #expect(built.member.name == member.name && built.member.image == member.image)
            #expect(built.member.ports == member.ports && built.member.env == member.env)
            #expect(built.member.volumes == member.volumes && built.member.command == member.command)
            #expect(built.member.readyPort == member.readyPort && built.member.secretEnv == member.secretEnv)
            #expect(built.volumeNames == service.volumes.map { StackPlanner.volumeName("blog", service.role, $0) })
        }
        #expect(plan.volumes == plan.group.members.flatMap { $0.volumes.map { String($0.split(separator: ":")[0]) } })
    }

    @Test("ready port, secrets and volumes pass through the shared function")
    func sharedFunction() {
        let built = GroupMembers.member(
            named: "shop-db", image: "postgres:18", ports: ["127.0.0.1:5433:5432"], env: ["A=1"],
            secretEnv: [SecretEnv(name: "POSTGRES_PASSWORD", secret: "db-password")],
            volumes: [StackVolume(suffix: "data", path: "/data")], command: ["-c", "x"], readyPort: 5432)
        #expect(built.member.volumes == ["shop-db-data:/data"])
        #expect(built.volumeNames == ["shop-db-data"])
        #expect(built.member.readyPort == 5432)
        #expect(built.member.secretEnv == [SecretEnv(name: "POSTGRES_PASSWORD", secret: "db-password")])
        #expect(built.member.command == ["-c", "x"])
    }

    @Test("names are unique against the group, the Mac and each other")
    func uniqueNames() {
        let existing = [GroupMember(name: "nginx", image: "nginx")]
        let nginx = entry("nginx", image: "docker.io/library/nginx:1.27")
        let made = GroupMembers.members(for: [pick(nginx), pick(nginx), pick(nginx)], existing: existing,
                                        takenNames: ["nginx-2"])
        #expect(made.map(\.name) == ["nginx-3", "nginx-4", "nginx-5"])
        // Compared the way the group form compares them: ignoring case.
        let upper = GroupMembers.members(for: [pick(nginx)], existing: [GroupMember(name: "NGINX", image: "x")])
        #expect(upper.map(\.name) == ["nginx-2"])
    }

    @Test("host ports avoid existing members, the Mac, and earlier picks")
    func portClashes() {
        let a = entry("grafana", image: "grafana:1", ports: ["3000:3000"])
        let b = entry("metabase", image: "metabase:1", ports: ["3000:3000"])
        let existing = [GroupMember(name: "web", image: "x", ports: ["127.0.0.1:3000:80"])]
        let made = GroupMembers.members(for: [pick(a), pick(b)], existing: existing,
                                        usedHostPorts: [3001], isPortFree: { $0 != 3002 })
        #expect(made[0].ports == ["127.0.0.1:3003:3000"])
        #expect(made[1].ports == ["127.0.0.1:3004:3000"])
        let ports = made.flatMap(\.ports).compactMap(StackPlanner.hostPort(fromPublishSpec:)) + [3000]
        #expect(Set(ports).count == ports.count)
    }

    @Test("secrets are the entry's variables, one Keychain name per member")
    func secrets() {
        let db = entry("postgres", image: "postgres:18", secrets: ["POSTGRES_PASSWORD"])
        let made = GroupMembers.members(for: [pick(db), pick(db)], existing: [])
        #expect(made[0].secretEnv == [SecretEnv(name: "POSTGRES_PASSWORD", secret: "postgres-postgres-password")])
        #expect(made[1].secretEnv == [SecretEnv(name: "POSTGRES_PASSWORD", secret: "postgres-2-postgres-password")])
        #expect(made.allSatisfy { GroupSecrets.problem(with: $0) == nil })
        #expect(made.allSatisfy { $0.env.isEmpty })
    }

    @Test("volumes follow the member's name, and a name whose volume exists moves on")
    func volumes() {
        let db = entry("postgres", image: "postgres:18", volumes: [postgres])
        let made = GroupMembers.members(for: [pick(db), pick(db)], existing: [],
                                        takenVolumes: ["postgres-data"])
        #expect(made.map(\.name) == ["postgres-2", "postgres-3"])
        #expect(made[0].volumes == ["postgres-2-data:/var/lib/postgresql/data"])
        #expect(made[1].volumes == ["postgres-3-data:/var/lib/postgresql/data"])
        // Volumes already in the group's draft count as taken too.
        let again = GroupMembers.members(for: [pick(db)], existing: made)
        #expect(again[0].name == "postgres")
    }

    @Test("ready port comes from the pick")
    func readyPort() {
        let p = GroupMembers.Pick(image: "redis:7", baseName: "redis", readyPort: 6379)
        #expect(GroupMembers.members(for: [p], existing: []).first?.readyPort == 6379)
    }

    @Test("a local image keeps its own reference, with a matching entry's values")
    func localImage() {
        let nginx = entry("nginx", image: "docker.io/library/nginx:1.27", ports: ["8080:80"], env: ["X=1"])
        let library = SuggestionLibrary(version: "t", entries: [nginx])
        let matched = GroupMembers.Pick(localImage: "docker.io/library/nginx:1.25", in: library)
        let made = GroupMembers.members(for: [matched], existing: [])
        #expect(made[0].image == "docker.io/library/nginx:1.25")
        #expect(made[0].ports == ["127.0.0.1:8080:80"] && made[0].env == ["X=1"] && made[0].name == "nginx")

        let plain = GroupMembers.Pick(localImage: "ghcr.io/Acme/My_App:2", in: library)
        let bare = GroupMembers.members(for: [plain], existing: []).first!
        #expect(bare.image == "ghcr.io/Acme/My_App:2" && bare.name == "my-app")
        #expect(bare.ports.isEmpty && bare.env.isEmpty && bare.volumes.isEmpty)
        #expect(Allowlist.accepts(bare.name, as: .identifier))
    }

    @Test("a tag's major version: numbers only, latest and digests say none")
    func majorVersions() {
        #expect(GroupMembers.majorVersion(of: "docker.io/library/postgres:18.6") == 18)
        #expect(GroupMembers.majorVersion(of: "postgres:17-alpine") == 17)
        #expect(GroupMembers.majorVersion(of: "docker.io/prom/prometheus:v3.13.4") == 3)
        #expect(GroupMembers.majorVersion(of: "postgres:17@sha256:abc") == 17)
        #expect(GroupMembers.majorVersion(of: "localhost:5000/postgres:16") == 16)
        for none in ["postgres", "postgres:latest", "postgres@sha256:abc", "localhost:5000/postgres",
                     "postgres:alpine", "postgres:"] {
            #expect(GroupMembers.majorVersion(of: none) == nil, "\(none)")
        }
    }

    /// Kyle and Iris, 20 October: PostgreSQL 18 keeps its data at `/var/lib/postgresql`, 17 at
    /// `/var/lib/postgresql/data`, and 18's entrypoint refuses the older mount. A recipe crosses
    /// neither way between majors; the logo still matches by repository.
    @Test("a local image inherits a recipe only for the same major version")
    func recipeNeedsTheSameMajor() {
        let pg18 = entry("postgresql", image: "docker.io/library/postgres:18.6", ports: ["5432:5432"],
                         secrets: ["POSTGRES_PASSWORD"],
                         volumes: [LibraryVolume(path: "/var/lib/postgresql")])
        let pg17 = entry("postgresql", image: "docker.io/library/postgres:17.6", ports: ["5432:5432"],
                         secrets: ["POSTGRES_PASSWORD"], volumes: [postgres])

        // Local 17 against the 18 recipe, and local 18 against a 17 one: nothing inherited.
        for (local, recipe) in [("postgres:17", pg18), ("postgres:18.1", pg17)] {
            let library = SuggestionLibrary(version: "t", entries: [recipe])
            #expect(library.entry(forImage: local)?.id == "postgresql")   // the logo still matches
            #expect(library.recipe(forImage: local) == nil)
            let made = GroupMembers.members(for: [GroupMembers.Pick(localImage: local, in: library)], existing: [])[0]
            #expect(made.image == local)
            #expect(made.volumes.isEmpty && made.ports.isEmpty && made.secretEnv.isEmpty)
        }
        // The same major does inherit, the volume path included.
        let same = GroupMembers.members(for: [GroupMembers.Pick(localImage: "postgres:18.1",
                                                                in: SuggestionLibrary(version: "t", entries: [pg18]))],
                                        existing: [])[0]
        #expect(same.volumes == ["postgresql-data:/var/lib/postgresql"])
        #expect(same.secretEnv.map(\.name) == ["POSTGRES_PASSWORD"])
        // `latest`, no tag and a bare digest name no version.
        let library = SuggestionLibrary(version: "t", entries: [pg18])
        for unversioned in ["postgres:latest", "postgres", "postgres@sha256:abc"] {
            #expect(library.recipe(forImage: unversioned) == nil, "\(unversioned)")
            #expect(GroupMembers.Pick(localImage: unversioned, in: library).container == nil)
        }
    }

    @Test("a stack is not a pick")
    func stackEntry() {
        let stack = LibraryEntry(id: "s", title: "s", summary: "", categories: ["Databases"], kind: .stack,
                                 tested: .init(date: "2026-10-12", macs: 1),
                                 stack: LibraryStack(services: [.init(role: "web", title: "w", image: "nginx:1")]))
        #expect(GroupMembers.Pick(entry: stack) == nil)
        #expect(GroupMembers.defaultName(forImage: "@@@") == "service")
    }

    /// Dave's review, 19 October: a pick with no free host port carries `127.0.0.1::80`, and the
    /// group used to save it and fail at Start, after its earlier members were already running.
    @Test func aServiceWithNoHostPortChosenIsRefusedAtSave() throws {
        var book = GroupBook()
        let group = try book.createGroup(name: "shop")
        #expect(throws: GroupBook.GroupError.invalidPort("127.0.0.1::80", member: "web")) {
            try book.addMember(GroupMember(name: "web", image: "nginx:1.29", ports: ["127.0.0.1::80"]),
                               to: group.id)
        }
        let added = try book.addMember(GroupMember(name: "web", image: "nginx:1.29",
                                                   ports: ["127.0.0.1:8080:80", "5432:5432"]), to: group.id)
        #expect(added.ports.count == 2)
    }
}

@Suite("Group form picker requests")
struct PickRequestsTests {
    /// Kyle, 20 October: Add, leave the picker, open Blank Service — the late result places nothing.
    @Test func leavingThePickerWithdrawsItsPendingAdd() throws {
        var requests = GroupMembers.PickRequests()
        let begun = requests.begin()
        let first = try #require(begun)
        #expect(requests.begin() == nil)            // a second Add while the first prepares
        requests.withdraw()                          // ✕, Back, or Blank Service
        #expect(!requests.isCurrent(first))

        // Open the picker again and Add: the old request finishing must not cancel the new one.
        let again = requests.begin()
        let second = try #require(again)
        requests.finish(first)
        #expect(requests.isCurrent(second))
        requests.finish(second)
        #expect(requests.current == nil)
        #expect(requests.begin() != nil)
    }
}
