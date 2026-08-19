import Foundation
import FlotillaCore

@MainActor
extension AppModel {

    /// Build an image from a Dockerfile.
    ///
    /// **The authorisation is the folder the user picked**, and nothing wider.
    ///
    /// `AppModel`'s own `cli` carries `.denyHostPaths`, so it refuses every build context by
    /// design — correct for a boundary that Phase 2 will point at a remote peer, and useless
    /// for a local build. The tempting fixes are both wrong: giving the shared CLI
    /// `.unrestricted` would silently widen bind mounts in Run as well, and dropping the
    /// context requirement is exactly the hole the review found on 9 August.
    ///
    /// So this builds a CLI for **one command**, granting exactly the directory the user chose
    /// in an `NSOpenPanel` and nothing else. That is a genuine widening of the app's default
    /// and is stated rather than hidden: the grant is per-invocation, its scope is the single
    /// path the user selected in a system panel, and the Dockerfile — which may sit outside the
    /// context — must be inside it too or the same policy refuses it.
    ///
    /// This is the one sanctioned exception to `cli`'s "one instance, one boundary" rule, and
    /// it goes the safe way round: the new policy is narrow and explicit, not inherited and
    /// forgotten. A `ContainerCLI` that quietly *discards* a narrowed policy is the failure
    /// that rule exists to prevent; this one names its scope in the call.
    func buildImage(context: URL, dockerfile: String?, tag: String?,
                    buildArgs: [String], labels: [String],
                    noCache: Bool, platform: String?, target: String?) async -> Bool {
        // Resolve symlinks before validating, so the policy is granted for — and the CLI is
        // handed — the path the build will actually read. Choosing the folder in a panel and
        // having a link in it silently redirect the build elsewhere is the same TOCTOU shape
        // the review flagged, and resolving here removes the UI's contribution to it.
        let contextPath = context.resolvingSymlinksInPath().standardizedFileURL.path
        let scoped = ContainerCLI(host: LocalHost(), mountPolicy: .roots([contextPath]), wirePolicy: .localOwner)

        do {
            _ = try await Task.detached {
                try scoped.buildImage(contextDirectory: contextPath,
                                      dockerfile: dockerfile, tag: tag,
                                      buildArgs: buildArgs, labels: labels,
                                      noCache: noCache, platform: platform, target: target)
            }.value
            recordActivity(ContainerEvent(date: Date(), from: "absent", to: "present",
                                          kind: .image,
                                          subject: tag ?? contextPath,
                                          action: "Built"))
            await refreshImages()
            return true
        } catch {
            actionError = describeBuild(error)
            record("Build failed in \(contextPath): \(error)", subsystem: "images")
            return false
        }
    }

    /// The validated argv, for the live preview — same construction the build runs, checked
    /// against the same per-invocation policy, so the preview cannot claim a command the
    /// button would then refuse.
    nonisolated static func buildPreview(
        context: URL?, dockerfile: String?, tag: String?, buildArgs: [String],
        labels: [String], noCache: Bool, platform: String?, target: String?
    ) -> Result<ValidatedCommand, AllowlistError> {
        guard let context else {
            return .failure(.missingOperand(subcommand: "build", need: 1))
        }
        // Resolve symlinks before validating, so the policy is granted for — and the CLI is
        // handed — the path the build will actually read. Choosing the folder in a panel and
        // having a link in it silently redirect the build elsewhere is the same TOCTOU shape
        // the review flagged, and resolving here removes the UI's contribution to it.
        let contextPath = context.resolvingSymlinksInPath().standardizedFileURL.path
        var argv = ["build"]
        if let dockerfile, !dockerfile.isEmpty { argv += ["--file", dockerfile] }
        if let tag, !tag.isEmpty { argv += ["--tag", tag] }
        for argument in buildArgs where !argument.isEmpty { argv += ["--build-arg", argument] }
        for label in labels where !label.isEmpty { argv += ["--label", label] }
        if noCache { argv.append("--no-cache") }
        if let platform, !platform.isEmpty { argv += ["--platform", platform] }
        if let target, !target.isEmpty { argv += ["--target", target] }
        argv.append(contextPath)
        return Allowlist.validate(argv, mountPolicy: .roots([contextPath]))
    }

    private func describeBuild(_ error: any Error) -> String {
        if let cliError = error as? ContainerCLIError { return String(describing: cliError) }
        if let allowlist = error as? AllowlistError { return allowlist.description }
        return String(describing: error)
    }
}
