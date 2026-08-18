import Foundation
import FlotillaCore

/// One line in the aggregated log view, tagged with where it came from.
///
/// Flat rather than grouped, so filtering is a single pass and the table can sort by source
/// without regrouping.
struct AggregatedLogLine: Identifiable, Equatable {
    let source: String
    let kind: ActivityKind
    /// Position within that source's chunk — the only identity a log line has. Text repeats,
    /// so `LogLine` numbers its lines for exactly this reason.
    let index: Int
    let stream: LogLine.Stream
    let text: String

    var id: String { "\(kind.rawValue)/\(source)#\(index)" }
}

/// What one source returned, so the view can say "these 200 are the tail of more" per source
/// rather than as one vague banner.
struct AggregatedLogChunk: Identifiable, Equatable {
    let source: String
    let kind: ActivityKind
    let lines: [AggregatedLogLine]
    let truncated: Bool
    /// Set when this source could not be read at all — a stopped container, a machine that has
    /// never booted. Held per source and shown as a row, because dropping the source silently
    /// would make "no output" and "could not read" look identical.
    let failure: String?

    var id: String { "\(kind.rawValue)/\(source)" }
}

extension AppModel {

    /// Fetches logs from several sources at once and returns them tagged.
    ///
    /// **Deliberately not interleaved into one chronological stream.** `container logs` has no
    /// `--timestamps` flag — verified against the captured help, and `LogLine.receivedAt` says
    /// so in its own docstring: the only clock available is *ours*, recording when we read the
    /// line, which is identical for every line in a chunk. Merging on that would produce a
    /// convincing lie: lines from different containers ordered by nothing at all. So sources
    /// stay separate and ordered, and the view says which source each line came from.
    ///
    /// Concurrent across sources, sequential within one: the fetches are independent processes
    /// and a serial loop over a dozen containers would take a dozen round trips.
    func aggregatedLogs(scope: LogsUIState.Scope,
                        sources: LogsUIState.Sources,
                        only: Set<String>,
                        lines: Int) async -> [AggregatedLogChunk] {
        guard runtimeUsable else { return [] }

        let wantContainers = sources != .machines
        let wantMachines = sources != .containers
        let boot = scope.isBoot

        // Only running containers can answer `logs`; a stopped one returns an error, and asking
        // anyway would fill the view with failure rows for things the user has not started.
        var targets: [(String, ActivityKind)] = []
        if wantContainers {
            targets += running.map { ($0.id, ActivityKind.container) }
        }
        if wantMachines {
            targets += machines.filter { MachinesView.isRunning($0) }.map { ($0.id, .machine) }
        }
        if !only.isEmpty {
            targets = targets.filter { only.contains($0.0) }
        }

        let cli = self.cli
        return await withTaskGroup(of: AggregatedLogChunk.self) { group in
            for (id, kind) in targets {
                group.addTask {
                    do {
                        let chunk = try await Task.detached {
                            switch kind {
                            case .machine: try cli.machineLogs(id, lines: lines, boot: boot)
                            default:       try cli.logs(id, lines: lines, bootLog: boot)
                            }
                        }.value
                        return AggregatedLogChunk(
                            source: id, kind: kind,
                            lines: chunk.lines.map {
                                AggregatedLogLine(source: id, kind: kind, index: $0.index,
                                                  stream: $0.stream, text: $0.text)
                            },
                            truncated: chunk.truncated, failure: nil)
                    } catch {
                        // The CLI's own sentence, not a generic one — for a machine that has
                        // never booted it explains itself better than we could.
                        return AggregatedLogChunk(source: id, kind: kind, lines: [],
                                                  truncated: false,
                                                  // `ContainerCLIError` already reduces the
                                                  // CLI's complaint to its salient line.
                                                  failure: (error as? ContainerCLIError)?.description
                                                      ?? error.localizedDescription)
                    }
                }
            }
            var chunks: [AggregatedLogChunk] = []
            for await chunk in group { chunks.append(chunk) }
            // Stable order: machines after containers, alphabetical within each. A task group
            // completes in whatever order the processes finish, so without this the sources
            // would shuffle on every refresh.
            return chunks.sorted {
                $0.kind == $1.kind ? $0.source < $1.source : $0.kind == .container
            }
        }
    }
}
