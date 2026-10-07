import Foundation
import Security

/// What the app and the DNS helper agree on: the helper's name, its XPC interface, and how each
/// side checks who is on the other end.
///
/// The helper (decision 19 as amended 7 October) is a root `SMAppService` daemon the owner approves
/// once in System Settings ▸ Login Items. It does two things — `system dns create` and `system dns
/// delete` — and nothing else. It takes **typed requests**, never an argv: the app says "create
/// `test`", and the helper builds and validates the command itself, so a caller that got past the
/// signature check still could not choose what runs.
///
/// macOS-only (Security, the Objective-C runtime), which is why it is not in `FlotillaCore` — the
/// core stays Foundation-only and builds on Linux.
public enum DNSHelperInterface {
    /// The launchd label, the Mach service name, the helper's signing identifier and the plist's
    /// basename are all this one string, so none of them can drift from the others.
    public static let label = "dev.melonfleet.Flotilla.dns-helper"
    public static let plistName = label + ".plist"
    /// The only app allowed to talk to the helper.
    public static let appIdentifier = "dev.melonfleet.Flotilla"
    /// Bumped when the interface changes, so an app can tell an old helper from a current one.
    public static let version = 1

    /// A code requirement for `identifier`, signed by Apple-issued Developer ID under `team`.
    /// Both ends use it: the helper on the app, and the app on the helper.
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The team this process is signed under, or `nil` when it is ad-hoc signed or unsigned. Each
    /// side requires the *other* to share its own team, so nothing is hardcoded and an ad-hoc dev
    /// build can never pass — it has no team to match.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The helper's XPC interface. Each reply carries `nil` on success, or the reason it refused or
/// failed, in words fit for an alert.
@objc public protocol DNSHelperProtocol {
    func helperVersion(reply: @escaping @Sendable (Int) -> Void)
    func createDomain(_ domain: String, localhost: String?, reply: @escaping @Sendable (String?) -> Void)
    func deleteDomains(_ domains: [String], reply: @escaping @Sendable (String?) -> Void)
}
