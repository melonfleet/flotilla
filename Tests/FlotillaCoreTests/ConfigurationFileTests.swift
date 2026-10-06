import Foundation
import Testing
@testable import FlotillaCore

@Suite("Configuration file")
struct ConfigurationFileTests {

    private var sample: ConfigurationFile {
        ConfigurationFile(
            networks: [NetworkSpec(name: "shop-net"), NetworkSpec(name: "backend", hostOnly: true)],
            volumes: [VolumeSpec(name: "shop-db-data", size: "10G")],
            machines: [MachineSpec(name: "dev-box", image: "alpine:3.22", cpus: 2, memory: "2G", homeMount: .ro)],
            clusters: [ClusterSpec(name: "k8s-dev", cpus: 4, memory: "8G",
                                   nodeImage: ClusterSuggestion.nodeImage135)],
            containers: [ServiceSpec(name: "scratch", image: "alpine:3.22", command: ["sleep", "infinity"])],
            groups: [GroupSpec(name: "shop", network: "shop-net", notes: ["Sign in as admin."], members: [
                ServiceSpec(name: "shop-db", image: "docker.io/library/postgres:18.6",
                            digest: "sha256:" + String(repeating: "a", count: 64),
                            env: ["POSTGRES_DB=app"],
                            secretEnv: [SecretEnv(name: "POSTGRES_PASSWORD", secret: "db-password")],
                            volumes: ["shop-db-data:/var/lib/postgresql"], readyPort: 5432),
                ServiceSpec(name: "shop-web", image: "caddy:2-alpine", ports: ["127.0.0.1:8080:80"]),
            ])],
            tags: TagsSpec(definitions: [.init(name: "Production", color: .red)],
                           assignments: [.init(kind: .group, id: "shop", tags: ["Production"])]),
            registries: RegistriesSpec(entries: [.init(host: "ghcr.io")], defaultRegistry: "docker.io"),
            dns: DNSSpec(domains: [.init(name: "flotilla"),
                                   .init(name: "host.container.internal", localhost: "203.0.113.113")],
                         containerDomain: "flotilla"))
    }

    @Test("a file round-trips exactly")
    func roundTrip() throws {
        let data = try sample.encoded()
        #expect(try ConfigurationFile.parse(data) == sample)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : 2"))
    }

    @Test("a secret is a name in the file, never a value")
    func noSecretValues() throws {
        let text = String(decoding: try sample.encoded(), as: UTF8.self)
        #expect(text.contains("\"secret\" : \"db-password\""))
        #expect(!text.contains("POSTGRES_PASSWORD="))
    }

    @Test("version 1 files still read")
    func version1() throws {
        let file = try ConfigurationFile.parse(Data(#"""
            {"version": 1, "machines": [{"name": "dev", "image": "alpine:3.22"}],
             "containers": [{"name": "web", "image": "nginx:1.27", "ports": ["8080:80"]}]}
            """#.utf8))
        #expect(file.machines.map(\.name) == ["dev"])
        #expect(file.containers.first?.ports == ["8080:80"])
    }

    @Test("unknown keys are refused, at the top and deep inside")
    func unknownKeys() {
        func refused(_ json: String) -> Bool {
            if case .failure(.unknownField) = Result(catching: { try ConfigurationFile.parse(Data(json.utf8)) })
                .mapError({ $0 as! ConfigurationFileError }) { return true }
            return false
        }
        #expect(refused(#"{"version": 2, "extras": []}"#))
        #expect(refused(#"{"version": 2, "groups": [{"name": "g", "members": [{"name": "a", "image": "alpine:3.22", "privileged": true}]}]}"#))
        #expect(refused(#"{"version": 2, "containers": [{"name": "a", "image": "alpine:3.22", "secretEnv": [{"name": "X", "secret": "x", "value": "hunter2"}]}]}"#))
    }

    @Test("refusals: future version, host folders, undefined tags, .local, clashing names")
    func refusals() {
        func fails(_ file: ConfigurationFile) -> Bool {
            (try? ConfigurationFile.parse(try! file.encoded())) == nil
        }
        #expect((try? ConfigurationFile.parse(Data(#"{"version": 3}"#.utf8))) == nil)
        #expect((try? ConfigurationFile.parse(Data(#"{"networks": []}"#.utf8))) == nil)

        var hostFolder = sample
        hostFolder.containers[0].volumes = ["/Users/someone/code:/code"]
        #expect(fails(hostFolder))

        var undefinedTag = sample
        undefinedTag.tags?.assignments[0].tags = ["Nope"]
        #expect(fails(undefinedTag))

        var local = sample
        local.dns?.domains.append(.init(name: "shop.local"))
        #expect(fails(local))

        var clash = sample
        clash.containers.append(ServiceSpec(name: "shop-db", image: "alpine:3.22"))
        #expect(fails(clash))

        var badDigest = sample
        badDigest.groups[0].members[0].digest = "sha256:XYZ"
        #expect(fails(badDigest))

        var shellInName = sample
        shellInName.volumes[0].name = "a;rm -rf ~"
        #expect(fails(shellInName))
    }

    @Test("a file over the size limit is refused before parsing")
    func sizeLimit() {
        var limits = ConfigurationFile.Limits()
        limits.maxFileBytes = 10
        #expect(throws: ConfigurationFileError.fileTooLarge(bytes: 15, limit: 10)) {
            try ConfigurationFile.parse(Data(#"{"version": 2} "#.utf8), limits: limits)
        }
    }
}
