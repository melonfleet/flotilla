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

    /// Every registry this Mac is signed in to. `[]` is the normal answer for someone who only
    /// pulls public images.
    func registryLogins() async -> [RegistryLogin] {
        guard runtimeUsable else { return [] }
        return (try? await Task.detached { [cli] in try cli.registryLogins() }.value) ?? []
    }

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
                                          kind: .image, subject: server,
                                          action: "Signed in to registry"))
            return nil
        } catch {
            return (error as? ContainerCLIError)?.description ?? String(describing: error)
        }
    }

    func signOut(registry server: String) async -> String? {
        do {
            try await Task.detached { [cli] in try cli.registryLogout(server: server) }.value
            recordActivity(ContainerEvent(date: Date(), from: "", to: "",
                                          kind: .image, subject: server,
                                          action: "Signed out of registry"))
            return nil
        } catch {
            return (error as? ContainerCLIError)?.description ?? String(describing: error)
        }
    }
}
