import Foundation

/// One environment variable whose value is a Keychain-held secret: `POSTGRES_PASSWORD` from the
/// secret `db-password`.
public struct SecretEnv: Codable, Sendable, Equatable, Hashable {
    /// The variable the container sees.
    public var name: String
    /// The secret's name within its group. The Keychain item is keyed by group id and this.
    public var secret: String

    public init(name: String, secret: String) {
        self.name = name
        self.secret = secret
    }
}

/// Generated passwords for groups, kept in the Keychain (Suggestions, decided 2026-10-06).
///
/// The rules live here, Foundation-only and tested; the Keychain itself is the app's
/// (`KeychainSecrets`). **The preferences file holds only names** — which variable, which
/// secret — and an export (when there is one) carries the same names and no values, so a group
/// file is safe to share by construction rather than by remembering to scrub it.
public enum GroupSecrets {
    /// Letters and digits only. Images put passwords into URLs and config files
    /// (`DATABASE_URL=postgres://user:PASSWORD@db/app`), where `@`, `:`, `/` or a quote breaks the
    /// value; 24 alphanumerics are ~143 bits, which is plenty without them.
    public static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    public static func generatePassword(length: Int = 24) -> String {
        var generator = SystemRandomNumberGenerator()
        return generatePassword(length: length, using: &generator)
    }

    public static func generatePassword<G: RandomNumberGenerator>(length: Int,
                                                                   using generator: inout G) -> String {
        String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Every secret a group's members name, in first-mentioned order, without repeats.
    public static func secretNames(in group: ContainerGroup) -> [String] {
        var seen = Set<String>()
        return group.members.flatMap(\.secretEnv).map(\.secret).filter { seen.insert($0).inserted }
    }

    /// Why a member's Keychain-held variables are refused, or `nil`. Returns the offending name.
    public static func problem(with member: GroupMember) -> String? {
        let plainKeys = Set(member.env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        var seen = Set<String>()
        for entry in member.secretEnv {
            guard Allowlist.accepts(entry.name + "=x", as: .envAssignment),
                  Allowlist.accepts(entry.secret, as: .identifier),
                  !plainKeys.contains(entry.name),
                  seen.insert(entry.name).inserted
            else { return entry.name }
        }
        return nil
    }

    public struct MissingSecret: Error, Equatable, CustomStringConvertible {
        public let secret: String
        public init(secret: String) { self.secret = secret }
        public var description: String {
            "The password “\(secret)” isn't in this Mac's Keychain. Open the group to set a new one."
        }
    }

    /// The member's whole environment for `container run`: its plain variables, then each
    /// Keychain-held one with its value filled in from `values` (secret name → value).
    public static func resolvedEnv(for member: GroupMember,
                                   values: [String: String]) throws -> [String] {
        try member.env + member.secretEnv.map { entry in
            guard let value = values[entry.secret] else { throw MissingSecret(secret: entry.secret) }
            return "\(entry.name)=\(value)"
        }
    }

    /// The same environment for a **preview**, with each secret shown as where it comes from
    /// rather than what it is.
    public static func previewEnv(for member: GroupMember) -> [String] {
        member.env + member.secretEnv.map { "\($0.name)=<Keychain: \($0.secret)>" }
    }
}
