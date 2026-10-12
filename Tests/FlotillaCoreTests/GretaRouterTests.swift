import Foundation
import Testing
@testable import FlotillaCore

@Suite struct GretaRouterTests {
    private func route(_ message: String, after reply: String? = nil) -> GretaRoute {
        GretaRouter.route(message, lastReply: reply)
    }

    private func recipeID(_ route: GretaRoute) -> String? {
        if case .draft(let recipe) = route { return recipe.id }
        return nil
    }

    @Test func questionsAreAnswered() {
        #expect(route("What can Flotilla do?") == .answer)
        #expect(route("Why does a host say it isn't answering?") == .answer)
        #expect(route("How do I keep a container running if it crashes?") == .answer)
        #expect(route("How do I run postgres?") == .answer)              // asked how, not asked to
        #expect(route("is redis running?") == .answer)
    }

    @Test func aNamedContainerIsDraftedFromItsRecipe() {
        #expect(recipeID(route("Draft Postgres with its data kept")) == "postgres")
        #expect(recipeID(route("Can you set up a web server for me?")) == "nginx")
        #expect(recipeID(route("redis")) == "redis")
        #expect(recipeID(route("I need a mariadb")) == "mariadb")
        #expect(recipeID(route("Draft Postgres 17 with its data kept")) == "postgres")
    }

    @Test func somethingWithNoRecipeIsNotGuessed() {
        #expect(route("run gitea for me") == .noRecipe)
        #expect(route("set up uptime kuma") == .noRecipe)
    }

    private func draft(_ message: String) -> GretaDraft {
        guard case .draft(let recipe) = route(message) else { Issue.record("not a draft: \(message)"); return GretaDraft(image: "", name: "", ports: [], env: [], volumes: []) }
        return GretaRouter.draft(recipe, for: message)
    }

    @Test func anUnchangedRecipeIsTheDraft() {
        let postgres = draft("Draft Postgres with its data kept")
        #expect(postgres.image == "docker.io/library/postgres:18.6")
        #expect(postgres.volumes == ["postgres-data:/var/lib/postgresql"])
        #expect(postgres.changes.isEmpty)
    }

    @Test func aVersionChangesTheTagAndAnOlderPostgresItsDataPath() {
        let postgres = draft("Draft Postgres 17 with its data kept")
        #expect(postgres.image == "docker.io/library/postgres:17")
        #expect(postgres.volumes == ["postgres-data:/var/lib/postgresql/data"])
        #expect(postgres.changes == ["version 17"])
        #expect(draft("run prometheus version 3.12").image == "docker.io/prom/prometheus:v3.12")
    }

    @Test func aPortNameUserAndDatabaseAreApplied() {
        let web = draft("run nginx on port 9000")
        #expect(web.ports == ["9000:80"])
        #expect(web.env.isEmpty && web.volumes.isEmpty)                    // nothing invented
        let shop = draft("run postgres called shop-db with user shop and database orders")
        #expect(shop.name == "shop-db")
        #expect(shop.volumes == ["shop-db-data:/var/lib/postgresql"])
        #expect(shop.env == ["POSTGRES_DB=orders", "POSTGRES_USER=shop", "POSTGRES_PASSWORD=change-me"])
        #expect(shop.changes == ["named shop-db", "user shop", "database orders"])
    }

    @Test func aConnectiveIsNeverTakenAsAValue() {
        let maria = draft("set up a mariadb database called shop")
        #expect(maria.name == "shop")
        #expect(maria.env.first == "MARIADB_DATABASE=app")
    }

    @Test func aPasswordIsLeftForTheRunForm() {
        let postgres = draft("postgres with password hunter2")
        #expect(postgres.passwordLeftForTheForm)
        #expect(!postgres.env.contains { $0.contains("hunter2") })
    }

    @Test func noVolumeDropsIt() {
        #expect(draft("run postgres without a volume").volumes.isEmpty)
    }

    @Test func runningSomethingUnnamedAsksWhich() {
        #expect(route("I want to run something") == .askWhich)
        #expect(route("set up a database") == .askWhich)
        #expect(route("can you draft a container?") == .askWhich)
    }

    @Test func aBareYesTakesWhatHerLastMessageOffered() {
        #expect(recipeID(route("yes", after: "Would you like me to draft Redis for you?")) == "redis")
        #expect(route("yes", after: "Flotilla manages containers, images and hosts. Want me to draft one?") == .askWhich)
        #expect(route("yes please", after: "I can draft Postgres or MySQL.") == .askWhich)
        #expect(route("sure", after: "WordPress needs a database; want the stack?") == .stack("WordPress + MariaDB"))
        #expect(route("yes") == .askWhich)
    }

    @Test func servicesThatNeedCompanyGoToSuggestions() {
        #expect(route("set up wordpress") == .stack("WordPress + MariaDB"))
        #expect(route("postgres and grafana please") == .stack(""))
    }

    @Test func pgAdminIsNotAlsoPostgres() {
        #expect(recipeID(route("run pgadmin")) == "pgadmin")
    }

    @Test func recipesComeFromTheTestedCatalogue() {
        let byID = Dictionary(uniqueKeysWithValues: GretaRouter.recipes.map { ($0.id, $0) })
        #expect(byID["postgres"]?.image == "docker.io/library/postgres:18.6")
        #expect(byID["postgres"]?.ports == ["5432:5432"])
        #expect(byID["postgres"]?.env == ["POSTGRES_DB=app", "POSTGRES_USER=app", "POSTGRES_PASSWORD=change-me"])
        #expect(byID["postgres"]?.volumes == ["postgres-data:/var/lib/postgresql"])
        #expect(byID["redis"]?.volumes == [])                              // lost+found, measured
        #expect(byID["pgadmin"]?.ports == ["8080:80"])
        #expect(byID["pgadmin"]?.env == ["PGADMIN_DEFAULT_EMAIL=admin@example.com", "PGADMIN_DEFAULT_PASSWORD=change-me"])
        #expect(GretaRouter.recipes.count == 8)                           // a catalogue rename would drop one
        #expect(GretaRouter.recipes.allSatisfy { !$0.image.hasSuffix(":latest") && $0.image.contains(":") })
    }
}
