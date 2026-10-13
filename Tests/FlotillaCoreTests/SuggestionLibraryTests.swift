import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SuggestionLibraryTests {
    private func container(_ change: (inout LibraryContainer) -> Void = { _ in }) -> LibraryEntry {
        var c = LibraryContainer(image: "docker.io/library/nginx:1.27", name: "web", ports: ["8080:80"])
        change(&c)
        return LibraryEntry(id: "web", title: "nginx", summary: "A web server.", categories: ["Networking & Web Servers"],
                            kind: .container, tested: .init(date: "2026-10-12", macs: 1), container: c)
    }

    private func stack(options: [LibraryStack.Option] = [.init(id: "database", label: "Database", defaultValue: "app", help: "")],
                       _ change: (inout LibraryStack) -> Void = { _ in }) -> LibraryEntry {
        var s = LibraryStack(
            options: options,
            services: [
                .init(role: "db", title: "DB", image: "docker.io/library/postgres:18.6",
                      env: ["POSTGRES_DB={{option:database}}"],
                      secretEnv: [.init(name: "POSTGRES_PASSWORD", secret: "db-password")], wiredPort: 5432),
                .init(role: "web", title: "Web", image: "docker.io/library/nginx:1.27", webPort: 80),
            ],
            notes: ["Database {{option:database}} at {{host:db}}:{{port:db}}."], opens: "web")
        change(&s)
        return LibraryEntry(id: "s", title: "S", summary: "", categories: ["Databases"], kind: .stack,
                            tested: .init(date: "2026-10-06", macs: 1), stack: s)
    }

    @Test func theBuiltInCopyPassesItsOwnChecks() {
        let (checked, dropped) = SuggestionLibrary.builtIn.checked()
        #expect(dropped.isEmpty, "\(dropped)")
        #expect(checked.entries.count == StackSuggestion.catalogue.count + GretaRouter.recipes.count)
        // A built-in stack opens in the stack form exactly as the catalogue's does.
        let postgres = checked.entries.first { $0.id == "postgres-stack" }?.stackSuggestion
        #expect(postgres?.services.map(\.image) == StackSuggestion.catalogue.first { $0.id == "postgres" }?.services.map(\.image))
        // Passwords are generated variables, never values in the file.
        let pg = checked.entries.first { $0.id == "postgres" }?.container
        #expect(pg?.secretEnv == ["POSTGRES_PASSWORD"])
        #expect(pg?.env.contains { $0.contains("change-me") } == false)
    }

    @Test func aGoodEntryPasses() {
        #expect(container().problem() == nil)
    }

    @Test func hostileOrSloppyEntriesAreDropped() {
        let bad: [LibraryEntry] = [
            container { $0.image = "nginx:latest" },
            container { $0.image = "docker.io/library/nginx" },
            container { $0.image = "nginx:1; rm -rf /" },
            container { $0.ports = ["80:80"] },                                  // low port on the Mac
            container { $0.ports = ["0.0.0.0:8080:80"] },                        // an address of its own
            container { $0.env = ["POSTGRES_PASSWORD=hunter2"] },                // a password in the file
            container { $0.env = ["X={{option:a}}"] },                           // no placeholders here
            container { $0.volumes = [LibraryVolume(path: "/Users/me/data")] }.withVolumeOnly("/../etc"),
            container { $0.volumes = [LibraryVolume(suffix: "a b", path: "/data")] },
            container { $0.command = ["sh", "-c", "echo $(id)"] },
            container { $0.name = "../web" },
        ]
        for entry in bad { #expect(entry.problem() != nil, "\(entry.container!)") }
        var wrongCategory = container()
        wrongCategory.categories = ["Gaming"]
        #expect(wrongCategory.problem() != nil)
    }

    @Test func aStackMayOnlyUsePlaceholdersThePlannerFills() {
        func stack(_ env: [String]) -> LibraryEntry {
            self.stack { $0.services[1].env = env }
        }
        #expect(stack(["DB={{host:db}}:{{port:db}}", "NAME={{option:database}}"]).problem() == nil)
        #expect(stack(["DB={{host:web}}"]).problem() != nil)          // web isn't reachable by others
        #expect(stack(["X={{secret:db-password}}"]).problem() != nil) // not supported yet
        #expect(stack(["X={{option:nope}}"]).problem() != nil)
    }

    // Kyle, 13 October: `hunter2` reached POSTGRES_PASSWORD through an option's default.
    @Test func aPasswordNeverComesFromAnOption() {
        let leaked = stack(options: [.init(id: "pw", label: "Password", defaultValue: "hunter2", help: "")]) {
            $0.services[0].env = ["POSTGRES_PASSWORD={{option:pw}}"]
            $0.services[0].secretEnv = []
            $0.notes = []
        }
        #expect(leaked.problem() != nil)
        // Wider names than PASSWORD, plain or templated, in a container or a stack.
        for name in ["DB_PASS", "MYSQL_PWD", "SMTP_PASSWD", "API_KEY", "JWT_SECRET", "GH_TOKEN", "AWS_CREDENTIALS"] {
            #expect(container { $0.env = ["\(name)=x"] }.problem() != nil, "\(name)")
            #expect(stack { $0.services[1].env = ["\(name)={{option:database}}"] }.problem() != nil, "\(name)")
        }
        // A generated variable is the only way, and it may not also be a plain one.
        #expect(container { $0.secretEnv = ["DB_PASS"] }.problem() == nil)
        #expect(container { $0.env = ["MODE=x"]; $0.secretEnv = ["MODE"] }.problem() != nil)
        #expect(container { $0.secretEnv = ["DB_PASS", "DB_PASS"] }.problem() != nil)
        #expect(stack { $0.services[0].env.append("POSTGRES_USER=app"); $0.services[0].secretEnv.append(.init(name: "POSTGRES_USER", secret: "u")) }
            .problem() != nil)
    }

    @Test func rolesDifferEvenIgnoringCaseAndOptionIDsDiffer() {
        #expect(stack { $0.services[1].role = "DB" }.problem() != nil)   // Kyle: `db` and `DB`
        let twice: [LibraryStack.Option] = [.init(id: "database", label: "A", defaultValue: "a", help: ""),
                                            .init(id: "database", label: "B", defaultValue: "b", help: "")]
        #expect(stack(options: twice).problem() != nil)
        #expect(stack { $0.services[0].volumes = [.init(path: "/a"), .init(path: "/b")] }.problem() != nil)
    }

    @Test func everyStackTheLibraryPassesIsOneTheGroupBookAccepts() throws {
        let entry = stack()
        #expect(entry.problem() == nil)
        let suggestion = try #require(entry.stackSuggestion)
        for wiring in [StackWiring.names(domain: "flotilla"), .gateway("192.168.71.1")] {
            let plan = try StackPlanner.plan(suggestion, choices: StackChoices(name: "s", webPorts: ["web": 8080]),
                                             wiring: wiring, usedHostPorts: [])
            var book = GroupBook()
            try book.commit(plan.group)
        }
    }

    // Kyle: a wired port of 40000 became host port 70000 on the gateway.
    @Test func aWiredPortTheGatewayCantCarryIsRefused() {
        #expect(stack { $0.services[0].wiredPort = 40000 }.problem() != nil)
        #expect(stack { $0.services[0].wiredPort = 35535 }.problem() == nil)
    }

    // Kyle: an untested entry was offered despite Q54.
    @Test func onlyTestedEntriesAreOffered() {
        var entry = container()
        entry.tested = nil
        #expect(entry.problem() != nil)
        for (date, macs) in [("2026-10-12", 0), ("2026-10-12", 21), ("2026-1-12", 1), ("2026-13-01", 1),
                             ("2026-02-30", 1), ("2026-10-12T00:00", 1), ("２０２６-10-12", 1), ("+026-10-12", 1)] {
            entry.tested = .init(date: date, macs: macs)
            #expect(entry.problem() != nil, "\(date) on \(macs)")
        }
        entry.tested = .init(date: "2028-02-29", macs: 20)
        #expect(entry.problem() == nil)
    }

    @Test func everyCollectionIsCapped() {
        let seventeen = (0..<17).map { $0 }
        #expect(container { $0.ports = seventeen.map { "\(8000 + $0):80" } }.problem() != nil)
        #expect(container { $0.env = seventeen.map { "V\($0)=x" } }.problem() != nil)
        #expect(container { $0.secretEnv = seventeen.map { "S\($0)" } }.problem() != nil)
        #expect(container { $0.volumes = seventeen.map { LibraryVolume(suffix: "v\($0)", path: "/v\($0)") } }.problem() != nil)
        #expect(container { $0.command = seventeen.map { "a\($0)" } }.problem() != nil)
        #expect(container { $0.env = ["X=" + String(repeating: "é", count: 300)] }.problem() != nil)  // 602 bytes
        #expect(stack(options: (0..<9).map { .init(id: "o\($0)", label: "O", defaultValue: "a", help: "") }).problem() != nil)
        #expect(stack { $0.notes = Array(repeating: "A note.", count: 9) }.problem() != nil)
        #expect(stack { $0.services[1].env = seventeen.map { "V\($0)=x" } }.problem() != nil)
        // Sixteen is fine.
        #expect(container { $0.env = (0..<16).map { "V\($0)=x" } }.problem() == nil)
    }

    @Test func shownTextIsPlainText() {
        func titled(_ title: String) -> LibraryEntry { var e = container(); e.title = title; return e }
        #expect(titled("nginx").problem() == nil)
        #expect(titled("Café").problem() == nil)
        #expect(titled("nginx\u{202E}xnign").problem() != nil)     // Kyle: a bidi override
        #expect(titled("ng\u{200B}inx").problem() != nil)          // zero-width space
        #expect(titled("nginx\nRun me").problem() != nil)
        #expect(titled("nginx\u{E000}").problem() != nil)          // private use
        #expect(titled("nginx\u{0378}").problem() != nil)          // unassigned
        #expect(titled("Cafe\u{301}").problem() != nil)            // not NFC
        #expect(titled(String(repeating: "\u{1F600}", count: 81)).problem() != nil)
        var licence = container(); licence.licenceNote = "SSPL\u{2066}"
        #expect(licence.problem() != nil)
        #expect(container { $0.note = "Line one\nline two" }.problem() != nil)
        #expect(stack { $0.services[0].title = "DB\u{202E}" }.problem() != nil)
        #expect(stack { $0.notes = ["Hidden\u{200D}text"] }.problem() != nil)
        #expect(stack(options: [.init(id: "database", label: "Data\u{202E}base", defaultValue: "app", help: "")]).problem() != nil)
        #expect(stack(options: [.init(id: "database", label: "Database", defaultValue: "app", help: "a\u{0007}")]).problem() != nil)
    }

    // Kyle: stray `{{` survived, and notes weren't checked at all.
    @Test func templatesFollowTheGrammarExactly() {
        for bad in ["X={{option:database", "X=}}", "X={{option:database}}}}", "X={{{option:database}}}",
                    "X={{option:database}} {{", "X={{}}", "X={{option:}}"] {
            #expect(stack { $0.services[1].env = [bad] }.problem() != nil, "\(bad)")
        }
        #expect(stack { $0.notes = ["Open {{ the page"] }.problem() != nil)
        #expect(stack { $0.notes = ["Ask {{option:nope}}."] }.problem() != nil)
        #expect(stack { $0.notes = ["At {{host:web}}."] }.problem() != nil)
        #expect(container { $0.env = ["X=}}"] }.problem() != nil)
        #expect(container { $0.note = "Then {{ open it" }.problem() != nil)
        #expect(Library.placeholders(in: "a {{option:x}} b {{port:db}}") == ["option:x", "port:db"])
    }

    @Test func itOpensAServiceWithAPage() {
        #expect(stack { $0.opens = "db" }.problem() != nil)
        #expect(stack { $0.opens = "nope" }.problem() != nil)
        #expect(stack { $0.opens = nil }.problem() == nil)
    }

    @Test func checkingDropsDuplicatesAndKeepsTheRest() {
        let library = SuggestionLibrary(version: "2026.10.12.0", entries: [container(), container(), container { $0.image = "x:latest" }])
        let (checked, dropped) = library.checked()
        #expect(checked.entries.count == 1)
        #expect(dropped.count == 2)
    }

    @Test func versionsCompareNumberByNumber() {
        let old = SuggestionLibrary(version: "2026.10.12.0", entries: [])
        #expect(old.isOlder(than: SuggestionLibrary(version: "2026.10.12.1", entries: [])))
        #expect(old.isOlder(than: SuggestionLibrary(version: "2026.10.13.0", entries: [])))
        #expect(!old.isOlder(than: SuggestionLibrary(version: "2026.9.30.9", entries: [])))
        #expect(!old.isOlder(than: old))
    }

    // Kyle: malformed parts read as zero, and an enormous one would freeze every later update.
    @Test func onlyFourBoundedNumbersAreAVersion() {
        let old = SuggestionLibrary(version: "2026.10.12.0", entries: [])
        for bad in ["2026.10.13", "2026.10.12.0.1", "2026.10.12.x", "2026.10.12.-1", "2026.10.12.+1", "99999.0.0.0",
                    "9223372036854775807.0.0.0", "2026.010.12.0", "2026..12.0", "", "2026.10.12.0 ", "２０２６.10.12.0"] {
            #expect(!SuggestionLibrary.isValidVersion(bad), "\(bad)")
            #expect(!old.isOlder(than: SuggestionLibrary(version: bad, entries: [])), "\(bad)")
            let (checked, dropped) = SuggestionLibrary(version: bad, entries: [container()]).checked()
            #expect(checked.entries.isEmpty)
            #expect(dropped.map(\.id) == ["library"])
        }
        #expect(SuggestionLibrary.isValidVersion("9999.0.0.0"))
        #expect(SuggestionLibrary.isValidVersion(SuggestionLibrary.builtIn.version))
    }

    /// Before publishing: `FLOTILLA_LIBRARY_CHECK=path/to/library.json swift test --filter aLibraryFile`.
    /// Skipped when the variable isn't set.
    @Test func aLibraryFileToPublishPassesEveryCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOTILLA_LIBRARY_CHECK"] else { return }
        let library = try JSONDecoder().decode(SuggestionLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let (checked, dropped) = library.checked()
        #expect(library.schema == SuggestionLibrary.currentSchema)
        #expect(dropped.isEmpty, "\(dropped.map { "\($0.id): \($0.problem)" }.joined(separator: "\n"))")
        #expect(checked.entries.count == library.entries.count)
    }

    @Test func aLibraryRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(SuggestionLibrary.builtIn)
        #expect(try JSONDecoder().decode(SuggestionLibrary.self, from: data) == SuggestionLibrary.builtIn)
    }
}

private extension LibraryEntry {
    func withVolumeOnly(_ path: String) -> LibraryEntry {
        var copy = self
        copy.container?.volumes = [LibraryVolume(path: path)]
        return copy
    }
}
