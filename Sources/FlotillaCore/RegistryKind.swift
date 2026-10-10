import Foundation

/// What *sort* of registry something is, as distinct from which one.
///
/// **This exists because the first Add form asked the wrong question.** Its picker offered
/// "catalogue entries not already in your list", which on a fresh install is the empty set — all
/// eight built-ins are always listed, because they are known public registries rather than
/// things you add. So the picker rendered with one item in it ("Something else…") and the rail
/// had nothing to follow, which is the entire feature.
///
/// The registries people actually *add* are the ones with no fixed hostname: Amazon ECR is
/// per-account and per-region, Azure is per-registry, Google Artifact Registry is per-region,
/// and Harbor, JFrog, Gitea and a bare `registry:2` are wherever you put them. What they share
/// is not a host — it is **how you authenticate to that family**, and that is what the rail
/// needs to teach. So the picker asks for the family and the host stays a field.
///
/// Every fact here was verified against vendor documentation and, where possible, against the
/// live registry API; see `DECISIONS.md` Q20.
public enum RegistryKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case dockerHub, github, gitlab, quay, redHat, microsoft, amazonPublic, kubernetes
    case chainguard
    case amazonECR, azure, googleArtifact, harbor, jfrog, gitea
    /// A registry Flotilla knows nothing specific about — a bare `registry:2`, or anything else
    /// that speaks the distribution API.
    case other

    public var id: Self { self }

    public var name: String {
        switch self {
        case .dockerHub: "Docker Hub"
        case .github: "GitHub Container Registry"
        case .gitlab: "GitLab Container Registry"
        case .quay: "Quay"
        case .redHat: "Red Hat Registry"
        case .microsoft: "Microsoft Artifact Registry"
        case .amazonPublic: "Amazon ECR Public"
        case .kubernetes: "Kubernetes"
        case .chainguard: "Chainguard"
        case .amazonECR: "Amazon ECR (private)"
        case .azure: "Azure Container Registry"
        case .googleArtifact: "Google Artifact Registry"
        case .harbor: "Harbor"
        case .jfrog: "JFrog Artifactory"
        case .gitea: "Gitea or Forgejo"
        // **Not "Something else".** That is the Registry picker's own wording for "let me
        // describe one", and the owner saw it twice on one screen: once to get here, and again
        // as the default answer to the next question. Two controls whose only option reads the
        // same is two controls that look like one mistake.
        case .other: "Generic or self-hosted"
        }
    }

    /// Whether this family lives at one well-known hostname.
    ///
    /// The ones that do are already in the catalogue and are never "added"; the ones that do not
    /// are exactly what the Add form is for. This is the property the picker filters on, so a
    /// choice that could only produce a duplicate is not offered at all.
    public var hostIsFixed: Bool {
        switch self {
        case .dockerHub, .github, .quay, .redHat, .microsoft, .amazonPublic, .kubernetes,
             .chainguard:
            true
        // GitLab's *hosted* registry is `registry.gitlab.com` and is in the catalogue; a
        // self-managed GitLab usually puts its registry on a different host from its web UI,
        // which is precisely the trap worth a form field.
        case .gitlab, .amazonECR, .azure, .googleArtifact, .harbor, .jfrog, .gitea, .other:
            false
        }
    }

    /// A host of this shape, for the field's placeholder and the rail's example.
    public var hostExample: String? {
        switch self {
        case .amazonECR: "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
        case .azure: "myteam.azurecr.io"
        case .googleArtifact: "europe-west1-docker.pkg.dev"
        case .harbor: "harbor.example.com"
        case .jfrog: "mycompany.jfrog.io"
        case .gitea: "git.example.com"
        case .gitlab: "registry.gitlab.example.com"
        case .other: "registry.internal:5000"
        default: nil
        }
    }

    /// What goes in the two sign-in fields, in this family's own terms. A trailing paragraph
    /// separated by a blank line is a command, and the views render it monospaced.
    public var credentialHint: String? {
        switch self {
        case .dockerHub:
            "Your Docker ID, and a personal access token — not your account password. Public "
            + "images pull without signing in; a token mainly raises your rate limit."
        case .github:
            "Your GitHub username, and a classic personal access token with only the "
            + "read:packages scope — GHCR does not accept fine-grained tokens, and a GitHub "
            + "password will not work. Public images pull without signing in. Do not tick "
            + "write:packages: Flotilla never pushes, and GitHub adds the repo scope — full "
            + "control of private repositories — along with it."
        case .gitlab:
            "Your GitLab username, and a personal access token with the read_registry scope. "
            + "A password will not work if you have two-factor authentication on. Public "
            + "projects pull without signing in."
        case .quay:
            "A robot account name and its token, or your Quay username and the encrypted CLI "
            + "password from Account Settings. A robot name contains a plus, as in "
            + "myorg+buildbot. Public repositories pull without signing in."
        case .redHat:
            "A registry service account — its username looks like 12345678|name, and its token "
            + "is the password. Everything here is behind a subscription; "
            + "registry.access.redhat.com carries the unauthenticated images."
        case .amazonPublic:
            "Public images need no account; signing in only raises your pull rate limit. The "
            + "username is AWS; for the password run:\n\n"
            + "aws ecr-public get-login-password --region us-east-1"
        case .amazonECR:
            "Amazon ECR issues a token that lasts about 12 hours, so expect to sign in again. "
            + "The username is AWS; for the password run:\n\n"
            + "aws ecr get-login-password --region <region>"
        case .azure:
            "Azure issues a token that lasts about 3 hours. Run:\n\n"
            + "az acr login --name <registry> --expose-token\n\n"
            + "Use 00000000-0000-0000-0000-000000000000 as the username and the accessToken it "
            + "prints as the password."
        case .googleArtifact:
            "Google issues an access token that lasts about an hour. The username is "
            + "oauth2accesstoken; for the password run:\n\n"
            + "gcloud auth print-access-token"
        case .harbor:
            "Your Harbor username and password, or a robot account and its secret. A robot name "
            + "is prefixed — robot$name, or robot$project+name depending on the version — and "
            + "the secret is shown only once. If your Harbor is behind single sign-on you need "
            + "the CLI secret from your profile page, not your SSO password."
        case .jfrog:
            "Your Artifactory username and an access or identity token. API keys are deprecated. "
            + "Sign in to the exact host in the image reference: repository-path and subdomain "
            + "layouts use different hosts."
        case .gitea:
            "Your account username and a personal access token with the package scope. The "
            + "registry is on the main site host, not a registry. subdomain."
        case .chainguard:
            "Your Chainguard account and a token from the console. The free tier of images "
            + "pulls without signing in."
        case .microsoft, .kubernetes:
            nil
        case .other:
            "Whatever your registry asks for. Most want an access token rather than an account "
            + "password."
        }
    }

    /// Where, in a browser, this family's token is created. `nil` where there is no such page —
    /// the cloud registries mint theirs with a CLI, and two of these have no accounts at all.
    public var tokenURL: String? {
        switch self {
        case .dockerHub: "https://app.docker.com/settings/personal-access-tokens/create"
        case .github: "https://github.com/settings/tokens/new?scopes=read:packages&description=Flotilla"
        case .gitlab: "https://gitlab.com/-/user_settings/personal_access_tokens/legacy/new?scopes=read_registry"
        case .quay: "https://docs.quay.io/glossary/robot-accounts.html"
        case .redHat: "https://access.redhat.com/terms-based-registry/"
        case .chainguard: "https://console.chainguard.dev/"
        case .amazonECR, .amazonPublic, .azure, .googleArtifact, .harbor, .jfrog, .gitea,
             .microsoft, .kubernetes, .other:
            nil
        }
    }

    /// The vendor's own page on authenticating a container client. Shown for the families whose
    /// credential is minted somewhere Flotilla cannot link to directly.
    public var docsURL: String? {
        switch self {
        case .amazonECR: "https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html"
        case .amazonPublic: "https://docs.aws.amazon.com/AmazonECR/latest/public/docker-pull-ecr-image.html"
        case .azure: "https://learn.microsoft.com/en-us/azure/container-registry/container-registry-authentication"
        case .googleArtifact: "https://docs.cloud.google.com/artifact-registry/docs/docker/authentication"
        case .harbor: "https://goharbor.io/docs/2.13.0/working-with-projects/working-with-images/pulling-pushing-images/"
        case .jfrog: "https://docs.jfrog.com/artifactory/docs/docker-repositories"
        case .gitea: "https://docs.gitea.com/usage/packages/container/"
        case .gitlab: "https://docs.gitlab.com/user/packages/container_registry/authenticate_with_container_registry/"
        case .github: "https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry"
        case .quay: "https://docs.quay.io/guides/login.html"
        case .redHat: "https://access.redhat.com/articles/RegistryAuthentication"
        case .dockerHub: "https://docs.docker.com/security/access-tokens/personal-access-tokens/"
        case .chainguard: "https://edu.chainguard.dev/chainguard/containers/using-and-deploying/using-containers/"
        case .microsoft, .kubernetes, .other: nil
        }
    }

    /// One line on what this family is, for the rail.
    public var summary: String {
        switch self {
        case .amazonECR:
            "Per account and per region, so the same AWS account is a different registry in "
            + "each region."
        case .azure:
            "Per registry. Private by default; anonymous pull is something the owner turns on, "
            + "and it exposes every repository at once."
        case .googleArtifact:
            "Per region. Private by default; a repository is public only if it grants read to "
            + "allUsers."
        case .harbor: "Self-hosted. Public projects allow anonymous pull."
        case .jfrog: "Self-hosted or on jfrog.io. Anonymous access is an instance setting."
        case .gitea:
            "Self-hosted Gitea or Forgejo. Package visibility follows the **owner**, not the "
            + "linked repository — an easy way to publish something by accident."
        case .gitlab: "A self-managed GitLab's own registry, which is usually not the GitLab host."
        case .other: "Anything that speaks the OCI distribution API."
        default: name
        }
    }

    /// Which family a host belongs to, where that can be told from the host alone.
    ///
    /// Used to give a registry the user typed the right guidance without asking them twice.
    /// Returns `.other` rather than guessing when nothing matches.
    public static func inferred(fromHost host: String) -> RegistryKind {
        let host = KnownRegistry.canonicalHost(host)
        switch host {
        case "docker.io": return .dockerHub
        case "ghcr.io": return .github
        case "quay.io": return .quay
        case "mcr.microsoft.com": return .microsoft
        case "public.ecr.aws": return .amazonPublic
        case "registry.k8s.io": return .kubernetes
        case "cgr.dev": return .chainguard
        case "registry.gitlab.com": return .gitlab
        case "registry.redhat.io", "registry.access.redhat.com": return .redHat
        default: break
        }
        if host.hasSuffix(".amazonaws.com"), host.contains(".dkr.ecr.") { return .amazonECR }
        if host.hasSuffix(".azurecr.io") { return .azure }
        if host.hasSuffix("-docker.pkg.dev") || host == "gcr.io" || host.hasSuffix(".gcr.io") {
            return .googleArtifact
        }
        if host.hasSuffix(".jfrog.io") { return .jfrog }
        return .other
    }
}
