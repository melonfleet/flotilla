import Foundation
import Testing
@testable import FlotillaCore

// Built from **captured** output (`Fixtures/container-1.5.0/export-*.json`, 6 October): the demo's
// `storefront-db` and `storefront-web`, and `image inspect` of their images.

@Suite("Configuration export")
struct ConfigurationExportTests {

    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/container-1.5.0"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func inputs() throws -> ConfigurationExport.Inputs {
        var inputs = ConfigurationExport.Inputs()
        inputs.containers = try load("export-containers", as: [Container].self)
        inputs.images = try load("export-images", as: [ContainerImage].self)
        return inputs
    }

    private func everything(_ inputs: ConfigurationExport.Inputs) -> ConfigurationExport.Selection {
        var selection = ConfigurationExport.Selection()
        selection.containers = Set(inputs.containers.map(\.id))
        return selection
    }

    @Test("only what was chosen is exported — not the image's own variables or command")
    func subtractsImageDefaults() throws {
        let inputs = try inputs()
        let result = ConfigurationExport.build(inputs, selection: everything(inputs))
        let db = try #require(result.file.containers.first { $0.name == "storefront-db" })
        #expect(db.env == ["PGDATA=/var/lib/postgresql/data/pgdata", "POSTGRES_DB=shop"])
        #expect(db.command.isEmpty)                    // docker-entrypoint.sh postgres is the image's
        #expect(db.volumes == ["shop-db-data:/var/lib/postgresql/data"])
        #expect(db.network == "shop-net")
        #expect(db.memory == "1G")
        #expect(db.digest?.hasPrefix("sha256:") == true)
        let web = try #require(result.file.containers.first { $0.name == "storefront-web" })
        #expect(web.command.isEmpty)
        #expect(web.ports == ["127.0.0.1:8080:80"])
    }

    @Test("a password becomes a name, and a folder on this Mac is left out — both reported")
    func secretsAndFolders() throws {
        let inputs = try inputs()
        let result = ConfigurationExport.build(inputs, selection: everything(inputs))
        let db = try #require(result.file.containers.first { $0.name == "storefront-db" })
        #expect(db.secretEnv == [SecretEnv(name: "POSTGRES_PASSWORD", secret: "postgres-password")])
        let web = try #require(result.file.containers.first { $0.name == "storefront-web" })
        #expect(web.volumes.isEmpty)
        #expect(result.omissions.contains { $0.subject == "storefront-db" && $0.reason.contains("POSTGRES_PASSWORD") })
        #expect(result.omissions.contains { $0.subject == "storefront-web" && $0.reason.contains("/usr/share/caddy") })

        // And neither reaches the file's bytes.
        let text = String(decoding: try result.file.encoded(), as: UTF8.self)
        #expect(!text.contains("example-password"))
        #expect(!text.contains("/Users/"))
        #expect(try ConfigurationFile.parse(Data(text.utf8)) == result.file)
    }

    @Test("group members are exported with their group, not again as containers")
    func groupsOwnTheirMembers() throws {
        var inputs = try inputs()
        let group = ContainerGroup(name: "storefront", network: "shop-net", members: [
            GroupMember(name: "storefront-db", image: "docker.io/library/postgres:17-alpine",
                        env: ["POSTGRES_DB=shop", "POSTGRES_PASSWORD=example-password"],
                        volumes: ["shop-db-data:/var/lib/postgresql/data"], readyPort: 5432),
            GroupMember(name: "storefront-web", image: "docker.io/library/caddy:2-alpine",
                        volumes: ["/Users/example/site:/usr/share/caddy:ro"]),
        ])
        inputs.groups = [group]
        var selection = everything(inputs)
        selection.groups = [group.id]
        let result = ConfigurationExport.build(inputs, selection: selection)
        #expect(result.file.containers.isEmpty)
        let members = try #require(result.file.groups.first?.members)
        #expect(members[0].secretEnv.map(\.name) == ["POSTGRES_PASSWORD"])
        #expect(members[0].env == ["POSTGRES_DB=shop"])
        #expect(members[0].readyPort == 5432)
        #expect(members[0].digest?.hasPrefix("sha256:") == true)
        #expect(members[1].volumes.isEmpty)
        #expect(!String(decoding: try result.file.encoded(), as: UTF8.self).contains("/Users/"))
    }

    @Test("which variable names count as secrets")
    func secretWords() {
        for secret in ["POSTGRES_PASSWORD", "MYSQL_ROOT_PASSWORD", "API_KEY", "GITHUB_TOKEN",
                       "AWS_SECRET_ACCESS_KEY", "DB_PASS", "PRIVATE_KEY"] {
            #expect(ConfigurationExport.looksSecret(secret), "\(secret)")
        }
        for plain in ["POSTGRES_DB", "KEYBOARD_LAYOUT", "PATH", "PGDATA", "PASSWORDLESS_MODE_X".replacingOccurrences(of: "_X", with: "")] {
            #expect(!ConfigurationExport.looksSecret(plain), "\(plain)")
        }
    }

    @Test("sizes are written as the CLI's flags take them")
    func sizes() {
        #expect(ConfigurationExport.sizeString(1_073_741_824) == "1G")
        #expect(ConfigurationExport.sizeString(10 * 1_073_741_824) == "10G")
        #expect(ConfigurationExport.sizeString(536_870_912) == "512M")
    }
}
