import Foundation
import Testing
@testable import FlotillaCore

@Suite("Stack suggestions")
struct StackSuggestionsTests {

    private var wordpress: StackSuggestion { StackSuggestion.catalogue.first { $0.id == "wordpress" }! }

    @Test("the catalogue is Iris's top five, pinned, with no nginx")
    func catalogue() {
        #expect(StackSuggestion.catalogue.map(\.id) == ["postgres", "wordpress", "redis", "mysql", "monitoring"])
        for stack in StackSuggestion.catalogue {
            for image in stack.images {
                #expect(!image.contains("nginx"))
                #expect(!image.hasSuffix(":latest") && image.contains(":"), "\(image) must be pinned")
            }
        }
    }

    @Test("with a domain, services find each other by name on their own port")
    func namesWiring() throws {
        let plan = try StackPlanner.plan(wordpress,
                                         choices: StackChoices(name: "blog", webPorts: ["site": 8082]),
                                         wiring: .names(domain: "flotilla"), usedHostPorts: [])
        #expect(plan.network == "blog-net" && plan.createsNetwork)
        #expect(plan.group.memberNames == ["blog-db", "blog-site"])
        let db = plan.group.members[0], site = plan.group.members[1]
        #expect(db.ports.isEmpty)               // nothing published: reached by name
        #expect(db.readyPort == 3306)
        #expect(site.env.contains("WORDPRESS_DB_HOST=blog-db:3306"))
        #expect(site.env.contains("WORDPRESS_DB_NAME=wordpress"))
        #expect(site.ports == ["127.0.0.1:8082:80"])
        #expect(plan.volumes == ["blog-db-data", "blog-site-data"])
        #expect(plan.secrets == ["db-password", "root-password"])
        #expect(plan.openURL == "http://127.0.0.1:8082")
    }

    @Test("without a domain, the database is published on the gateway only")
    func gatewayWiring() throws {
        let plan = try StackPlanner.plan(wordpress,
                                         choices: StackChoices(name: "blog", webPorts: ["site": 8082]),
                                         wiring: .gateway("192.168.71.1"), usedHostPorts: [33306])
        let db = plan.group.members[0], site = plan.group.members[1]
        // 33306 is taken, so the next one up.
        #expect(db.ports == ["192.168.71.1:33307:3306"])
        #expect(site.env.contains("WORDPRESS_DB_HOST=192.168.71.1:33307"))
    }

    @Test("options fill in, and bad ones are refused")
    func options() throws {
        let plan = try StackPlanner.plan(wordpress,
                                         choices: StackChoices(name: "blog", webPorts: ["site": 8082],
                                                               options: ["database": "shop"]),
                                         wiring: .names(domain: "flotilla"), usedHostPorts: [])
        #expect(plan.group.members[0].env.contains("MARIADB_DATABASE=shop"))
        #expect(throws: StackPlanner.PlanError.self) {
            try StackPlanner.plan(wordpress,
                                  choices: StackChoices(name: "blog", webPorts: ["site": 8082],
                                                        options: ["user": "a b"]),
                                  wiring: .names(domain: "flotilla"), usedHostPorts: [])
        }
    }

    @Test("an existing network is used and not created")
    func existingNetwork() throws {
        let plan = try StackPlanner.plan(wordpress,
                                         choices: StackChoices(name: "blog", network: .existing("shop-net"),
                                                               webPorts: ["site": 8082]),
                                         wiring: .names(domain: "flotilla"), usedHostPorts: [])
        #expect(plan.network == "shop-net" && !plan.createsNetwork)
        #expect(plan.group.network == "shop-net")
    }

    @Test("names and ports avoid what the Mac already has")
    func clashes() {
        let taken = StackPlanner.Taken(containerNames: ["wordpress-db"], hostPorts: [8080, 8081])
        #expect(StackPlanner.suggestedName(for: wordpress, taken: taken, groupNames: []) == "wordpress-2")
        #expect(StackPlanner.nameProblem("wordpress", stack: wordpress, network: .new, taken: taken,
                                         groupNames: []) != nil)
        #expect(StackPlanner.nameProblem("Blog", stack: wordpress, network: .new, taken: taken,
                                         groupNames: []) != nil)
        #expect(StackPlanner.nameProblem("blog", stack: wordpress, network: .new, taken: taken,
                                         groupNames: ["Blog"]) != nil)
        #expect(StackPlanner.defaultWebPorts(for: wordpress, avoiding: taken.hostPorts) == ["site": 8082])
    }

    @Test("every stack's every command passes the Allowlist, both wirings")
    func everyCommandValidates() throws {
        for stack in StackSuggestion.catalogue {
            let ports = StackPlanner.defaultWebPorts(for: stack, avoiding: [])
            for wiring in [StackWiring.names(domain: "flotilla"), .gateway("192.168.71.1")] {
                let plan = try StackPlanner.plan(stack, choices: StackChoices(name: stack.id, webPorts: ports),
                                                 wiring: wiring, usedHostPorts: [])
                var book = GroupBook()
                try book.commit(plan.group)        // the book's own rules accept it
                for member in plan.group.members {
                    let args = ContainerCLI.runArguments(image: member.image,
                                                         options: member.runOptions(network: plan.network),
                                                         command: member.command)
                    guard case .success = Allowlist.validate(args) else {
                        Issue.record("\(stack.id)/\(member.name) refused: \(args)"); continue
                    }
                }
                #expect(!plan.notes.contains { $0.contains("{{") }, "\(stack.id) left a token unfilled")
                #expect(!plan.group.members.flatMap(\.env).contains { $0.contains("{{") })
            }
        }
    }

    @Test("publish specs give up their host port")
    func publishSpecs() {
        #expect(StackPlanner.hostPort(fromPublishSpec: "8080:80") == 8080)
        #expect(StackPlanner.hostPort(fromPublishSpec: "127.0.0.1:8090:8000") == 8090)
        #expect(StackPlanner.hostPort(fromPublishSpec: "192.168.71.1:33306:3306/tcp") == 33306)
        #expect(StackPlanner.hostPort(fromPublishSpec: "80") == nil)
    }

    @Test("a stack's notes travel with its group, through a commit")
    func notesKept() throws {
        let plan = try StackPlanner.plan(wordpress,
                                         choices: StackChoices(name: "blog", webPorts: ["site": 8082]),
                                         wiring: .names(domain: "flotilla"), usedHostPorts: [])
        #expect(!plan.group.notes.isEmpty)
        var book = GroupBook()
        try book.commit(plan.group)
        #expect(book.groups.first?.notes == plan.group.notes)
    }

    @Test("email options")
    func email() {
        let option = StackOption(id: "e", label: "E", defaultValue: "", help: "", kind: .email)
        #expect(option.problem(with: "admin@example.com") == nil)
        #expect(option.problem(with: "admin") != nil)
        #expect(option.problem(with: "a@b") != nil)
        #expect(option.problem(with: "a b@c.com") != nil)
    }
}
