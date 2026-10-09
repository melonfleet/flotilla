import AppKit
import FlotillaCore

/// Runs validated `container` commands **as an administrator**, behind the standard macOS password
/// prompt. Today that is only `system dns create` and `system dns delete`, which write
/// `/etc/resolver` and so need root.
///
/// The owner's rule (6 October): never silent. Every run shows the system's own prompt, carrying a
/// sentence that says what is about to happen, and the form that leads here shows the exact
/// command beforehand. Nothing is cached or retried without asking.
///
/// What may run is narrower than anything else in the app:
///
/// - only commands that crossed the `Allowlist` (`ValidatedCommand` cannot be built otherwise);
/// - only the installed binary, `/usr/local/bin/container`, and only while it and its directory
///   are root-owned and writable by no one else (`AdminExecutable`) — **never** the configurable
///   `containerBinaryPath`, which anything that can write Flotilla's preferences can change;
/// - each argument shell-quoted, the line AppleScript-escaped (`AdminScript`, tested in the core).
///
/// `NSAppleScript` rather than `osascript` so the prompt names Flotilla, not osascript. It runs on
/// the main actor, as `NSAppleScript` must; the prompt is modal anyway, and the commands it runs
/// return in well under a second.
@MainActor
enum AdminCommandRunner {
    enum Outcome: Equatable {
        case succeeded
        /// The user pressed Cancel in the password prompt. Not an error, and not reported as one.
        case cancelled
        case failed(String)
    }

    static func run(_ commands: [ValidatedCommand], prompt: String) -> Outcome {
        guard !commands.isEmpty else { return .succeeded }
        if let problem = AdminExecutable.installedProblem() { return .failed(problem) }
        guard let script = NSAppleScript(source: AdminScript.source(commands, prompt: prompt)) else {
            return .failed("flotilla couldn't prepare the administrator prompt.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .succeeded }
        // -128 is AppleScript's "User canceled."
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let message = (error[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message?.isEmpty == false ? message! : "The command failed.")
    }
}
