import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SuggestionLibraryTests {
    private func container(_ change: (inout LibraryContainer) -> Void = { _ in }) -> LibraryEntry {
        var c = LibraryContainer(image: "docker.io/library/nginx:1.27", name: "web", ports: ["8080:80"])
        change(&c)
        return LibraryEntry(id: "web", title: "nginx", summary: "A web server.", categories: ["Networking & Web Servers"],
                            kind: .container, container: c)
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
            LibraryEntry(id: "s", title: "S", summary: "", categories: ["Databases"], kind: .stack, stack: LibraryStack(
                options: [.init(id: "database", label: "Database", defaultValue: "app", help: "")],
                services: [
                    .init(role: "db", title: "DB", image: "docker.io/library/postgres:18.6", wiredPort: 5432),
                    .init(role: "web", title: "Web", image: "docker.io/library/nginx:1.27", env: env, webPort: 80),
                ]))
        }
        #expect(stack(["DB={{host:db}}:{{port:db}}", "NAME={{option:database}}"]).problem() == nil)
        #expect(stack(["DB={{host:web}}"]).problem() != nil)          // web isn't reachable by others
        #expect(stack(["X={{secret:db-password}}"]).problem() != nil) // not supported yet
        #expect(stack(["X={{option:nope}}"]).problem() != nil)
    }

    @Test func checkingDropsDuplicatesAndKeepsTheRest() {
        let library = SuggestionLibrary(version: "1", entries: [container(), container(), container { $0.image = "x:latest" }])
        let (checked, dropped) = library.checked()
        #expect(checked.entries.count == 1)
        #expect(dropped.count == 2)
    }

    @Test func versionsCompareNumberByNumber() {
        let old = SuggestionLibrary(version: "2026.10.12.0", entries: [])
        #expect(old.isOlder(than: SuggestionLibrary(version: "2026.10.12.1", entries: [])))
        #expect(old.isOlder(than: SuggestionLibrary(version: "2026.10.13", entries: [])))
        #expect(!old.isOlder(than: SuggestionLibrary(version: "2026.9.30.9", entries: [])))
        #expect(!old.isOlder(than: old))
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
