import Foundation
import Testing
@testable import FlotillaCore

@Suite("Group secrets")
struct GroupSecretsTests {

    private let db = GroupMember(name: "db", image: "mariadb:12.3",
                                 env: ["MARIADB_DATABASE=wordpress"],
                                 secretEnv: [SecretEnv(name: "MARIADB_PASSWORD", secret: "db-password"),
                                             SecretEnv(name: "MARIADB_ROOT_PASSWORD", secret: "root-password")])
    private let app = GroupMember(name: "wp", image: "wordpress:7.1-php8.4-apache",
                                  secretEnv: [SecretEnv(name: "WORDPRESS_DB_PASSWORD", secret: "db-password")])

    @Test("generated passwords are long, alphanumeric and different")
    func generation() {
        let one = GroupSecrets.generatePassword()
        let two = GroupSecrets.generatePassword()
        #expect(one.count == 24)
        #expect(one != two)
        #expect(one.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    @Test("a group's secrets are listed once each, in order")
    func names() {
        let group = ContainerGroup(name: "wp", members: [db, app])
        #expect(GroupSecrets.secretNames(in: group) == ["db-password", "root-password"])
    }

    @Test("Start fills in values; a missing one stops it before anything runs")
    func resolution() throws {
        let values = ["db-password": "abc123", "root-password": "def456"]
        #expect(try GroupSecrets.resolvedEnv(for: db, values: values)
                == ["MARIADB_DATABASE=wordpress", "MARIADB_PASSWORD=abc123",
                    "MARIADB_ROOT_PASSWORD=def456"])
        #expect(throws: GroupSecrets.MissingSecret(secret: "root-password")) {
            try GroupSecrets.resolvedEnv(for: db, values: ["db-password": "abc123"])
        }
    }

    @Test("previews say where a value comes from, never what it is")
    func preview() {
        #expect(GroupSecrets.previewEnv(for: app) == ["WORDPRESS_DB_PASSWORD=<Keychain: db-password>"])
        // And the preview validates, so the Start panel can show it.
        guard case .success = AppRunPreviewCheck.validate(app) else {
            Issue.record("preview should validate"); return
        }
    }

    @Test("bad or doubled secret variables are refused")
    func validation() throws {
        var book = GroupBook()
        let group = try book.createGroup(name: "g")
        let clash = GroupMember(name: "a", image: "alpine:3.22", env: ["PASSWORD=x"],
                                secretEnv: [SecretEnv(name: "PASSWORD", secret: "p")])
        #expect(throws: GroupBook.GroupError.invalidSecretEnv("PASSWORD")) {
            try book.addMember(clash, to: group.id)
        }
        let badSecret = GroupMember(name: "b", image: "alpine:3.22",
                                    secretEnv: [SecretEnv(name: "PW", secret: "a b")])
        #expect(throws: GroupBook.GroupError.invalidSecretEnv("PW")) {
            try book.addMember(badSecret, to: group.id)
        }
        let badName = GroupMember(name: "c", image: "alpine:3.22",
                                  secretEnv: [SecretEnv(name: "1PW", secret: "p")])
        #expect(throws: GroupBook.GroupError.invalidSecretEnv("1PW")) {
            try book.addMember(badName, to: group.id)
        }
        #expect(try book.addMember(app, to: group.id).secretEnv.count == 1)
    }
}

/// The run grammar check, as the app's preview does it.
enum AppRunPreviewCheck {
    static func validate(_ member: GroupMember) -> Result<ValidatedCommand, AllowlistError> {
        Allowlist.validate(ContainerCLI.runArguments(image: member.image,
                                                     options: member.runOptions(network: nil),
                                                     command: member.command))
    }
}
