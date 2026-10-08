import Foundation
import FlotillaCore

extension AppModel {

    /// Where the `container` binary is, for the two places that launch it **outside**
    /// `ContainerHost`: the container terminal and the machine console. Both need the path
    /// itself, because they hand it to a PTY rather than to `Process` with pipes.
    ///
    /// One resolver, and it is `Preflight.locateBinary` — the same call `LocalHost` makes.
    /// There used to be two private copies of this, each with its own hardcoded candidate list
    /// and each ending `?? "/usr/bin/env"`. Both faults are the ones this project keeps
    /// relearning:
    ///
    /// * **Two authorities for one property.** A candidate list that drifts from
    ///   `Preflight.installDirectories` means the app can find the CLI for status and not for
    ///   the terminal, or the reverse. There is now one list.
    /// * **`/usr/bin/env` as a fallback.** It is a PATH lookup by another route, and a
    ///   GUI-launched app's PATH is `/usr/bin:/bin:/usr/sbin:/sbin` — no `/usr/local/bin`. So
    ///   the "fallback" resolved to nothing on the exact machines it was meant to rescue, and
    ///   `env` then failed with its own message about a command it could not find, which reads
    ///   like the CLI is broken rather than absent. Worse, it was a PATH-shaped hole in an app
    ///   that otherwise launches only absolute paths from known directories.
    ///
    /// `nil` means not found, and the callers say so plainly instead of launching something and
    /// hoping.
    var containerExecutable: String? {
        // The user's override wins, but only if it is actually there — a stale path left in
        // preferences must not take the app down with it, and "detection" is a better answer than
        // "nothing". Existence is checked here rather than trusted from the settings row, because
        // the binary can be moved after the value was entered.
        let configured = settingsStore[SettingsKeys.containerBinaryPath]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return Preflight.locateBinary("container")
    }

    /// What the Settings row shows underneath the field: which path is actually in force, and why.
    /// A configured-but-missing path is the case worth naming — silently falling back would look
    /// like the override was accepted.
    var containerExecutableExplanation: String {
        let configured = settingsStore[SettingsKeys.containerBinaryPath]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured) {
                return "Using \(configured)."
            }
            return "\(configured) isn't an executable file — detecting automatically instead."
        }
        if let found = Preflight.locateBinary("container") { return "Detected \(found)." }
        return containerExecutableMissingReason
    }

    /// The one authority on whether a destructive action is confirmed first.
    ///
    /// Built fresh from the store on each read so a Settings change takes effect immediately —
    /// it is two field reads, and caching it would introduce the staleness this app has already
    /// been bitten by twice (the appearance override, the binary-path cache).
    var deletePolicy: DeletePolicy {
        DeletePolicy(confirmsSingleDeletes: settingsStore[SettingsKeys.confirmDestructiveActions])
    }

    /// The sentence shown when the binary cannot be found, naming where we looked.
    var containerExecutableMissingReason: String {
        "The container CLI could not be found in "
            + Preflight.searchedDirectories().joined(separator: ", ")
            + "."
    }
}
