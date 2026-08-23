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
    var containerExecutable: String? { Preflight.locateBinary("container") }

    /// The sentence shown when the binary cannot be found, naming where we looked.
    var containerExecutableMissingReason: String {
        "The container CLI could not be found in "
            + Preflight.searchedDirectories().joined(separator: ", ")
            + "."
    }
}
