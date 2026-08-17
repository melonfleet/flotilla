import Foundation
import FlotillaCore

/// New read paths for the Logs tab, the Inspect tab, the System page, and Images'
/// tag/prune actions — kept out of `AppModel.swift` itself because the app owner is editing that
/// file this same round (see the delivery report for the full rationale).
///
/// These originally used a second `ContainerCLI` of their own, because `AppModel.cli` was
/// `private` and Swift's same-file rule puts that out of reach of an extension in another
/// file. That was a correct reading of the language and the wrong shape for the app:
/// a separate instance silently gets the *default* `mountPolicy`, so any narrowing applied
/// to `AppModel`'s own CLI would not apply here. `cli` is now internal and shared.
extension AppModel {
    // MARK: Logs — boot log variant

    /// `AppModel.fetchLogs(for:lines:)` has no `bootLog` parameter, so this is a new
    /// overload (distinct arity) rather than an edit to the original.
    func fetchLogs(for id: String, lines: Int, bootLog: Bool) async throws -> LogChunk {
        try await Task.detached { [cli] in try cli.logs(id, lines: lines, bootLog: bootLog) }.value
    }

    // MARK: Inspect

    /// `rawInspectJSON(_:)` and `JSONPrettyPrinter` landed in `FlotillaCore` partway
    /// through this work (the core owner, in parallel — confirmed present by grep and by the jump
    /// from 141 to 157 tests, not assumed). This is the CLI's own `inspect` output,
    /// verbatim and pretty-printed, so fields `Container` doesn't model are visible too.
    func fetchInspectJSON(for id: String) async throws -> String {
        let raw = try await Task.detached { [cli] in try cli.rawInspectJSON(id) }.value
        return JSONPrettyPrinter.prettyPrint(raw)
    }

    // MARK: Processes

    /// `ContainerCLI.processes(_:)` returns only `stdout` — `execute(_:)` inside
    /// `FlotillaCore` discards `CommandResult.exitCode`/`stderr`, so a failed `exec` (a
    /// stopped container has none to list) comes back as an empty string, not a thrown
    /// error. The Processes tab relies on `Container.isRunning` to skip the call entirely
    /// rather than trying to reconstruct "stopped" from an empty result after the fact.
    func fetchProcesses(for id: String) async throws -> String {
        try await Task.detached { [cli] in try cli.processes(id) }.value
    }

    // MARK: System — disk usage

    /// Backs `SystemView`'s disk usage section. `systemDiskUsage()` is already typed and
    /// already the real name (`ContainerCLI.swift`) — no guess needed here.
    func fetchSystemDiskUsage() async throws -> SystemDiskUsage {
        try await Task.detached { [cli] in try cli.systemDiskUsage() }.value
    }

    // MARK: Images — tag & prune-with-preview

    /// `ContainerCLI` names this `tag(_:as:)`, not `tagImage` — confirmed with
    /// `grep "public func" ContainerCLI.swift` as the brief asked, rather than guessed.
    func tagImage(_ source: String, as target: String) async throws {
        _ = try await Task.detached { [cli] in try cli.tag(source, as: target) }.value
        // Named rather than left to the existence diff, which would report the new reference as
        // "Created" and say nothing about where it came from.
        recordActivity(ContainerEvent(date: Date(), from: source, to: target,
                                      kind: .image, subject: target,
                                      action: "Tagged from \(source)"))
    }

    /// Deletes exactly the references passed in, one `image rm` at a time — deliberately
    /// NOT the CLI's own blanket `image prune`, whose definition of "unused" is opaque
    /// from here and could remove a different set than whatever `ImagesView` just showed
    /// the user. Looping known references is the only way the confirmation sheet's preview
    /// and the actual deletions are guaranteed to be the same set, which is the whole
    /// point of "prune must always preview exactly what dies."
    ///
    /// Collects every failure rather than stopping at the first, same rationale as
    /// `performBulk(_:on:)` in `AppModel.swift`. Can't route through `busy`/`actionError`:
    /// both are `private(set)` in `AppModel.swift`, and the setter half of `private(set)`
    /// has the same same-file restriction as plain `private`, so this extension can read
    /// them but not write them. `ImagesView` keeps its own local busy/error state for this
    /// action instead — the same shape `ContainerDetailView`'s `LogsTab` already uses for a
    /// tab-local error that shouldn't pop the shared alert.
    func deleteImages(_ references: [String]) async -> [(reference: String, error: String)] {
        var failures: [(reference: String, error: String)] = []
        for reference in references {
            do {
                _ = try await Task.detached { [cli] in try cli.removeImage(reference) }.value
            } catch {
                failures.append((reference, String(describing: error)))
            }
        }
        return failures
    }
}
