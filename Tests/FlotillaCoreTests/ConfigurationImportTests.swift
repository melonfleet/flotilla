import Foundation
import Testing
@testable import FlotillaCore

@Suite("Configuration import")
struct ConfigurationImportTests {

    private var file: ConfigurationFile {
        ConfigurationFile(
            networks: [NetworkSpec(name: "wordpress-net")],
            volumes: [VolumeSpec(name: "wordpress-db-data", size: "10G")],
            containers: [ServiceSpec(name: "scratch", image: "alpine:3.22",
                                     secretEnv: [SecretEnv(name: "API_TOKEN", secret: "api-token")])],
            groups: [GroupSpec(name: "wordpress", network: "wordpress-net",
                               notes: ["Open wordpress-site, not wordpress-db."], members: [
                ServiceSpec(name: "wordpress-db", image: "mariadb:12.3",
                            secretEnv: [SecretEnv(name: "MARIADB_PASSWORD", secret: "db-password")],
                            volumes: ["wordpress-db-data:/var/lib/mysql"], readyPort: 3306),
                ServiceSpec(name: "wordpress-site", image: "wordpress:7.1-php8.4-apache",
                            env: ["WORDPRESS_DB_HOST=wordpress-db:3306", "WORDPRESS_DB_NAME=wordpress-dbx"],
                            secretEnv: [SecretEnv(name: "WORDPRESS_DB_PASSWORD", secret: "db-password")]),
            ])],
            tags: TagsSpec(definitions: [.init(name: "Blog", color: .green)],
                           assignments: [.init(kind: .group, id: "wordpress", tags: ["Blog"]),
                                         .init(kind: .container, id: "scratch", tags: ["Blog"])]),
            dns: DNSSpec(domains: [.init(name: "flotilla")], containerDomain: "flotilla"))
    }

    private var existing: ConfigurationImport.Existing {
        var e = ConfigurationImport.Existing()
        e.networks = ["wordpress-net"]
        e.containers = ["wordpress-db", "wordpress-site", "web"]
        e.groups = ["WordPress"]
        e.dnsDomains = ["flotilla"]
        return e
    }

    @Test("clashes are found, case-insensitively for groups, and through a group's members")
    func clashes() {
        let items = ConfigurationImport.items(file, existing: existing)
        let clashing = Set(items.filter(\.clashes).map(\.id))
        #expect(clashing == ["network/wordpress-net", "group/wordpress", "dnsDomain/flotilla"])
        #expect(!items.first { $0.id == "volume/wordpress-db-data" }!.clashes)
    }

    @Test("a clash waits for an answer; an existing DNS domain needs none")
    func undecided() {
        let items = ConfigurationImport.items(file, existing: existing)
        let resolutions = ConfigurationImport.initialResolutions(items)
        let problems = ConfigurationImport.problems(items, resolutions: resolutions, existing: existing)
        #expect(Set(problems.keys) == ["network/wordpress-net", "group/wordpress"])
        #expect(resolutions["dnsDomain/flotilla"] == .skip)
    }

    @Test("renames carry through: network, volume, members, values that name them, tags")
    func renamesCarry() {
        var resolutions = ConfigurationImport.initialResolutions(ConfigurationImport.items(file, existing: existing))
        resolutions["network/wordpress-net"] = .rename("blog-net")
        resolutions["volume/wordpress-db-data"] = .rename("blog-db-data")
        resolutions["group/wordpress"] = .rename("blog")
        let built = ConfigurationImport.resolve(file, resolutions: resolutions, existing: existing)

        #expect(built.networks.map(\.name) == ["blog-net"])
        let group = built.groups[0]
        #expect(group.name == "blog")
        #expect(group.network == "blog-net")
        #expect(group.members.map(\.name) == ["wordpress-db-2", "wordpress-site-2"])
        #expect(group.members[0].volumes == ["blog-db-data:/var/lib/mysql"])
        // The value that names the database follows it; a longer name that merely contains it
        // does not.
        #expect(group.members[1].env == ["WORDPRESS_DB_HOST=wordpress-db-2:3306",
                                         "WORDPRESS_DB_NAME=wordpress-dbx"])
        #expect(group.notes == ["Open wordpress-site-2, not wordpress-db-2."])
        #expect(built.tags?.assignments.first { $0.kind == .group }?.id == "blog")
    }

    @Test("skipping drops the thing and its tags; references to a skipped network stay")
    func skips() {
        var resolutions = ConfigurationImport.initialResolutions(ConfigurationImport.items(file, existing: existing))
        resolutions["network/wordpress-net"] = .skip
        resolutions["group/wordpress"] = .skip
        resolutions["container/scratch"] = .skip
        let built = ConfigurationImport.resolve(file, resolutions: resolutions, existing: existing)
        #expect(built.networks.isEmpty && built.groups.isEmpty && built.containers.isEmpty)
        #expect(built.tags?.assignments.isEmpty == true)
        #expect(built.dns?.domains.isEmpty == true)
    }

    @Test("renaming to a taken or doubled name is refused")
    func badRenames() {
        let items = ConfigurationImport.items(file, existing: existing)
        var resolutions = ConfigurationImport.initialResolutions(items)
        resolutions["network/wordpress-net"] = .rename("wordpress-net")
        resolutions["group/wordpress"] = .rename("wordpress")
        let problems = ConfigurationImport.problems(items, resolutions: resolutions, existing: existing)
        #expect(problems["network/wordpress-net"] != nil)
        #expect(problems["group/wordpress"] != nil)
    }

    @Test("what import must ask for: a group's secrets once each, a container's variables")
    func needs() {
        let needs = ConfigurationImport.secretNeeds(file)
        #expect(needs.map(\.id) == ["container/scratch", "group/wordpress"])
        #expect(needs.first { $0.id == "group/wordpress" }?.names == ["db-password"])
        #expect(ConfigurationImport.images(file).map(\.reference)
                == ["alpine:3.22", "mariadb:12.3", "wordpress:7.1-php8.4-apache"])
    }
}
