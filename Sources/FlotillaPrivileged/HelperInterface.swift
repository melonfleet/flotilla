import Foundation
import Security

/// What the app and the Flotilla Helper agree on: the helper's name, its XPC interface, and how each
/// side checks who is on the other end.
///
/// The Flotilla Helper (decision 19, amended 7 October; one helper for every privileged job, Q41) is
/// a root `SMAppService` daemon the owner approves once in System Settings ▸ Login Items. Its whole
/// job is the short list in `HelperProtocol` — `system dns create|delete`, the fleet resolver files,
/// installing Apple's `container` package — and nothing else. It takes **typed requests**, never an
/// argv: the app says "create `test`", and the helper builds and validates the command itself, so a
/// caller that got past the signature check still could not choose what runs.
///
/// macOS-only (Security, the Objective-C runtime), which is why it is not in `FlotillaCore` — the
/// core stays Foundation-only and builds on Linux.
public enum HelperInterface {
    /// The launchd label, the Mach service name, the helper's signing identifier and the plist's
    /// basename are all this one string, so none of them can drift from the others.
    public static let label = "dev.melonfleet.Flotilla.helper"
    public static let plistName = label + ".plist"
    /// What the helper was called until 8 October (Q41), when it only did DNS. Kept so the app can
    /// unregister a Mac's old registration once, then register the helper under its new name.
    public static let legacyLabel = "dev.melonfleet.Flotilla.dns-helper"
    public static let legacyPlistName = legacyLabel + ".plist"
    /// The only app allowed to talk to the helper.
    public static let appIdentifier = "dev.melonfleet.Flotilla"
    /// Bumped when the interface changes, so an app can tell an old helper from a current one.
    /// 2 (8 October, Q37): adds the fleet resolver files.
    /// 3 (8 October, Q39): adds installing Apple's `container` package.
    /// 4 (9 October, Q43): adds installing a Flotilla update over a root-owned app.
    public static let version = 4

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
@objc public protocol HelperProtocol {
    func helperVersion(reply: @escaping @Sendable (Int) -> Void)
    func createDomain(_ domain: String, localhost: String?, reply: @escaping @Sendable (String?) -> Void)
    func deleteDomains(_ domains: [String], reply: @escaping @Sendable (String?) -> Void)
    /// Makes `/etc/resolver/flotilla.<zone>` exist for exactly `zones`, each pointing at Flotilla's
    /// responder on 127.0.0.1 (DECISIONS Q37). Version 2.
    func syncFleetResolvers(fleetDomain: String, zones: [String], reply: @escaping @Sendable (String?) -> Void)
    /// Removes every `/etc/resolver/flotilla.*` file. Version 2.
    func removeFleetResolvers(reply: @escaping @Sendable (String?) -> Void)
    /// Installs Apple's `container` package at `path` — only if it is Apple's, notarised, exactly
    /// `version`, and not older than what is installed (DECISIONS Q39). Version 3.
    func installContainer(packageAt path: String, version: String, reply: @escaping @Sendable (String?) -> Void)
    /// Replaces the Flotilla this helper belongs to with the app at `path` — only if it is Flotilla,
    /// signed by this helper's own Developer ID team with every nested binary valid, and a newer
    /// build. The destination is never given: it is the app the helper is inside. For a Mac where a
    /// package installed Flotilla owned by root, so the app cannot replace itself (Q43). Version 4.
    func installFlotillaUpdate(appAt path: String, reply: @escaping @Sendable (String?) -> Void)
}
