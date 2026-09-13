import Foundation

/// Where an image reference says it comes from, and how to say it explicitly.
///
/// **This exists to make a setting real.** `defaultRegistryDomain` has been in the settings
/// registry since the beginning, shown in the Resources pane as "Default registry", and read by
/// exactly one thing: the About page, which *displays* it. It changed no pull. Its summary
/// claimed it "mirrors `[registry] domain`" — and `container` does have that property, but
/// `container system property` offers only `list`, so nothing Flotilla can run will change it.
/// A control that persists a value and alters nothing is the defect class this project has spent
/// weeks removing, and it had one of its own in the Settings window.
///
/// So the setting now means something Flotilla genuinely controls: **which registry its own Pull
/// form completes an unqualified reference against.** That is a smaller claim than the name
/// suggests and the screen says so — typing `alpine:latest` into a terminal still goes to Docker
/// Hub, because that is the CLI's business and not ours.
public enum ImageReferenceHost {

    /// Docker Hub, which is what the runtime resolves a host-less reference to. Not
    /// configurable from here — see the note above.
    public static let runtimeDefault = "docker.io"

    /// Whether a reference already names the registry it comes from.
    ///
    /// The rule is the one every OCI client uses, and it is not "does it contain a slash":
    /// `owner/app` is a Docker Hub reference with no host, while `ghcr.io/owner/app` has one. A
    /// first segment counts as a host when it contains a dot or a colon, or is exactly
    /// `localhost` — which is why `localhost:5000/app` works and `myteam/app` does not.
    public static func hasRegistryHost(_ reference: String) -> Bool {
        guard let slash = reference.firstIndex(of: "/") else { return false }
        let first = reference[reference.startIndex..<slash]
        return first.contains(".") || first.contains(":") || first == "localhost"
    }

    /// Completes a reference against the registry the user picked.
    ///
    /// Returns the reference **unchanged** when it already names a host, and unchanged again
    /// when the chosen registry is Docker Hub. That second case is deliberate: the CLI already
    /// completes `nginx` to `docker.io/library/nginx:latest`, including the `library/` namespace
    /// that only Docker Hub has, and prefixing `docker.io/nginx` ourselves would produce a
    /// reference the registry does not have. Leaving it alone means the runtime does what it has
    /// always done and Flotilla adds nothing it could get wrong.
    ///
    /// Everywhere else the prefix is exactly the host: `ghcr.io/owner/app`, no namespace
    /// insertion, because no other registry has Docker Hub's implicit one.
    public static func qualify(_ reference: String, with registry: String) -> String {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let registry = registry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !reference.isEmpty, !registry.isEmpty else { return reference }
        guard !hasRegistryHost(reference) else { return reference }
        // Docker Hub's three spellings all mean "leave it to the CLI".
        guard registry != runtimeDefault,
              registry != "registry-1.docker.io", registry != "index.docker.io"
        else { return reference }
        return "\(registry)/\(reference)"
    }

    /// Which registry a reference will actually be fetched from, for a preview that does not
    /// lie. `nil` when the reference is empty.
    public static func resolvedHost(_ reference: String, default registry: String) -> String? {
        let qualified = qualify(reference, with: registry)
        guard !qualified.isEmpty else { return nil }
        guard let slash = qualified.firstIndex(of: "/"),
              hasRegistryHost(qualified)
        else { return runtimeDefault }
        return String(qualified[qualified.startIndex..<slash])
    }
}
