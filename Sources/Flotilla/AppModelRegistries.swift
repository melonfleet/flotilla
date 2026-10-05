import Foundation
import FlotillaCore

/// Registry sign-in, kept out of `AppModel.swift` and out of every view.
///
/// **Nothing here logs, stores or returns a password.** It is a parameter that goes straight
/// through to `ContainerCLI.registryLogin`, which writes it to the child's stdin; no copy is
/// kept, no error message can carry it (`registryLogin` throws with the *audit* description,
/// which drops flag values), and the diagnostics bundle has nothing to redact because there is
/// nothing here to find.
extension AppModel {

    /// The Registries section's rows: your list, then any login this Mac holds that is not in
    /// it. See `RegistryBook.rows(logins:)`.
    var registryRows: [RegistryRow] { registries.book.rows(logins: registryLogins) }

    /// Re-reads which registries this Mac is signed in to.
    ///
    /// The list itself is local and always there; only the logins come from the runtime. So a
    /// runtime that is down still shows your list — with the sign-in column unknown rather than
    /// "Not signed in", which would be a claim about the Keychain nobody checked.
    func refreshRegistries() async {
        guard runtimeUsable else {
            setRegistriesState(.unavailable(preflight.flatMap(Self.registryUnavailableReason)
                                            ?? "`container` is unavailable."))
            return
        }
        if registriesState != .loaded { setRegistriesState(.loading) }
        do {
            let logins = try await Task.detached { [cli] in try cli.registryLogins() }.value
            setRegistryLogins(logins, state: .loaded)
        } catch {
            setRegistriesState(.failed(String(describing: error)))
        }
    }

    /// Adds a catalogue registry to the list, and says so in the feed.
    @discardableResult
    func addRegistry(known: KnownRegistry) -> Bool {
        guard registries.add(known: known) != nil else { return false }
        recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .registry,
                                      subject: known.id, action: "Added"))
        return true
    }

    /// Adds one the catalogue does not know.
    @discardableResult
    func addRegistry(host: String, name: String, summary: String, kind: RegistryKind,
                     usesHTTP: Bool, signInRequired: Bool) -> Bool {
        guard let added = registries.add(host: host, name: name, summary: summary, kind: kind,
                                         usesHTTP: usesHTTP, signInRequired: signInRequired)
        else { return false }
        recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .registry,
                                      subject: added.id, action: "Added"))
        return true
    }

    /// Takes registries out of the list. **Does not sign out** — see `RegistryBook.remove(host:)`.
    func removeRegistries(_ hosts: [String]) {
        for host in hosts {
            registries.remove(host: host)
            recordActivity(ContainerEvent(date: Date(), from: "", to: "", kind: .registry,
                                          subject: host, action: "Removed from the list"))
        }
    }

    /// Makes `host` the registry Flotilla's own Pull form completes a bare name against.
    func setDefaultRegistry(_ host: String) {
        try? settingsStore.set(host, for: SettingsKeys.defaultRegistryDomain)
    }

    var defaultRegistry: String { settingsStore[SettingsKeys.defaultRegistryDomain] }

    /// Signs in, and returns the CLI's own complaint on failure rather than a generic one — an
    /// authentication failure, a host that does not resolve and a registry that refused TLS are
    /// three different problems and the user can act on each of them differently.
    ///
    /// `password` is `consuming`-adjacent by convention rather than by keyword: it is forwarded
    /// once and this function keeps nothing.
    func signIn(registry server: String, username: String, password: String,
                scheme: String?) async -> String? {
        do {
            try await Task.detached { [cli] in
                try cli.registryLogin(server: server, username: username,
                                      password: password, scheme: scheme)
            }.value
            // Recorded so the activity feed shows that this Mac authenticated somewhere, which
            // is a fact worth a trace. The username is deliberately absent from the entry.
            recordActivity(ContainerEvent(date: Date(), from: "", to: "",
                                          kind: .registry, subject: server,
                                          action: "Signed in"))
            return nil
        } catch {
            return (error as? ContainerCLIError)?.description ?? String(describing: error)
        }
    }

    func signOut(registry server: String) async -> String? {
        do {
            try await Task.detached { [cli] in try cli.registryLogout(server: server) }.value
            recordActivity(ContainerEvent(date: Date(), from: "", to: "",
                                          kind: .registry, subject: server,
                                          action: "Signed out"))
            return nil
        } catch {
            return (error as? ContainerCLIError)?.description ?? String(describing: error)
        }
    }
}
