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

    /// When **Flotilla** received this line. Never the container's own clock.
    ///
    /// `container logs` has no `--timestamps` (captured help confirms it), so there is no
    /// timestamp in the data to show. This is the next most honest thing and it is worth being
    /// precise about what it means in each mode:
    ///
    /// - **Streaming**, it is genuine per-line arrival, to within one 120 ms drain tick — the
    ///   same bound the detail viewer's tail carries, and real ordering rather than an invented
    ///   one.
    /// - **Fetched**, it is when that source's chunk was read, so every line from one source
    ///   carries the same value. That is not a defect of the recording; it is the truth about a
    ///   bulk read, and it is why the column is off by default and says so in its header.
    ///
    /// Optional because a line with no recorded time must render as "—" rather than as the epoch.
    let receivedAt: Date?
    /// Which Mac said it (PLAN.md Phase C). A paired host's lines carry `host.rowID(id)` as their
    /// `source`, so two Macs' `web` never share a line id, a filter entry or a tag.
    var host: HostRef = .local
    var hostName = ""

    var id: String { "\(kind.rawValue)/\(source)#\(index)" }

    /// The container or machine's own name, without the host prefix `source` carries.
    var name: String { AggregatedLogLine.name(of: source, on: host) }

    static func name(of source: String, on host: HostRef) -> String {
        host.isLocal ? source : String(source.drop { $0 != "/" }.dropFirst())
    }
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
    var host: HostRef = .local
    var hostName = ""

    var id: String { "\(kind.rawValue)/\(source)" }
    var name: String { AggregatedLogLine.name(of: source, on: host) }
}

/// One thing the Logs section can read: a running container or machine, on This Mac or a paired
/// host. `key` is what filters, line ids and tags use; `label` is what a person reads.
struct LogSource: Hashable {
    let key: String
    let kind: ActivityKind
    let host: HostRef
    let hostName: String

    var name: String { AggregatedLogLine.name(of: key, on: host) }
    var label: String { host.isLocal ? key : "\(name) on \(hostName)" }
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

        let boot = scope.isBoot
        var targets = logSources(sources)
        if !only.isEmpty {
            targets = targets.filter { only.contains($0.key) }
        }

        // Each target's CLI, resolved here on the main actor: This Mac's own, or a paired host's
        // over the wire. A host that cannot be reached is a failure row, not a missing source.
        var resolved: [(LogSource, Result<ContainerCLI, Error>)] = []
        for target in targets {
            resolved.append((target, Result { try cli(for: target.host) }))
        }

        return await withTaskGroup(of: AggregatedLogChunk.self) { group in
            // One clock reading for the whole fetch, taken before any process starts, so two
            // sources that take different times to answer do not appear to have been read
            // minutes apart. This is the read time, not the write time; see
            // `AggregatedLogLine.receivedAt`.
            let readAt = Date()
            for (target, connection) in resolved {
                let key = target.key, name = target.name, kind = target.kind
                let host = target.host, hostName = target.hostName
                group.addTask {
                    do {
                        let cli = try connection.get()
                        let chunk = try await Task.detached {
                            switch kind {
                            case .machine: try cli.machineLogs(name, lines: lines, boot: boot)
                            default:       try cli.logs(name, lines: lines, bootLog: boot)
                            }
                        }.value
                        return AggregatedLogChunk(
                            source: key, kind: kind,
                            lines: chunk.lines.map {
                                // Stamped here, once per chunk. `LogChunk.from` only carries a
                                // `receivedAt` when the caller passes one and `ContainerCLI`
                                // does not, so without this the column would be empty on every
                                // fetched line — a control that exists and never has anything
                                // to show.
                                AggregatedLogLine(source: key, kind: kind, index: $0.index,
                                                  stream: $0.stream, text: $0.text,
                                                  receivedAt: $0.receivedAt ?? readAt,
                                                  host: host, hostName: hostName)
                            },
                            truncated: chunk.truncated, failure: nil, host: host, hostName: hostName)
                    } catch {
                        // The CLI's own sentence, not a generic one — for a machine that has
                        // never booted it explains itself better than we could. A host's
                        // failure is the wire's own description of it.
                        return AggregatedLogChunk(source: key, kind: kind, lines: [],
                                                  truncated: false,
                                                  failure: host.isLocal
                                                      // `ContainerCLIError` already reduces the
                                                      // CLI's complaint to its salient line.
                                                      ? (error as? ContainerCLIError)?.description
                                                          ?? error.localizedDescription
                                                      : HostModeController.describe(error),
                                                  host: host, hostName: hostName)
                    }
                }
            }
            var chunks: [AggregatedLogChunk] = []
            for await chunk in group { chunks.append(chunk) }
            // Stable order: containers, then machines; within each This Mac first, then each
            // host, then by name. A task group completes in whatever order the processes finish,
            // so without this the sources would shuffle on every refresh.
            return chunks.sorted {
                if $0.kind != $1.kind { return $0.kind == .container }
                if $0.host.isLocal != $1.host.isLocal { return $0.host.isLocal }
                if $0.hostName != $1.hostName { return $0.hostName < $1.hostName }
                return $0.name < $1.name
            }
        }
    }

    /// Every source the Logs section can read, in the feed's order. Only running containers and
    /// machines can answer `logs`; a stopped one returns an error, and asking anyway would fill
    /// the view with failure rows for things the user has not started. A paired host's running
    /// containers come from what it last reported (PLAN.md Phase C); machines are This Mac's.
    func logSources(_ sources: LogsUIState.Sources = .all) -> [LogSource] {
        var all: [LogSource] = []
        if sources != .machines {
            all += running.map { LogSource(key: $0.id, kind: .container, host: .local, hostName: hostLabel) }
            for (peer, snapshot) in hostMode.fleetContainers {
                let host = HostRef.peer(peer.fingerprint)
                all += snapshot.items.filter(\.isRunning).sorted { $0.id < $1.id }.map {
                    LogSource(key: host.rowID($0.id), kind: .container, host: host, hostName: peer.displayName)
                }
            }
        }
        if sources != .containers {
            all += machines.filter { MachinesView.isRunning($0) }
                .map { LogSource(key: $0.id, kind: .machine, host: .local, hostName: hostLabel) }
        }
        return all
    }
}
