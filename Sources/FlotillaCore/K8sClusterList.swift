import Foundation

/// One node of a local Kubernetes cluster, as `container k8s list` reports it.
///
/// A node rather than a cluster, because that is the row the command prints. Grouping nodes into
/// clusters is the caller's job and depends on `cluster` being populated — which, on 1.4.1, it is
/// not. See `K8sClusterList`.
public struct K8sNode: Sendable, Equatable, Identifiable, Hashable {
    /// The cluster this node belongs to. **Often empty** — see `K8sClusterList.parse`.
    public let cluster: String
    public let node: String
    /// `control-plane,worker` arrives as one field and is split here.
    public let roles: [String]
    public let state: String
    /// `nil` when the column is empty or unparseable, never 0 — a node with no reported CPU
    /// count is not a node with no CPUs.
    public let cpus: Int?
    /// Kept as printed, `16384 MB`. Not parsed to bytes: the unit is the CLI's choice and a
    /// number without it would lose what it meant.
    public let memory: String
    public let address: String
    /// `6445->6443`, one entry per mapping.
    public let ports: [String]

    public var id: String { cluster.isEmpty ? node : "\(cluster)/\(node)" }

    public var isRunning: Bool { state.caseInsensitiveCompare("running") == .orderedSame }

    public init(cluster: String, node: String, roles: [String], state: String,
                cpus: Int?, memory: String, address: String, ports: [String]) {
        self.cluster = cluster
        self.node = node
        self.roles = roles
        self.state = state
        self.cpus = cpus
        self.memory = memory
        self.address = address
        self.ports = ports
    }
}

/// Parses `container k8s list`.
///
/// ## Why this exists at all
///
/// Every other listing in `container` offers `--format json`. This one does not — `k8s list`
/// takes no options but `--debug` and `--help`, so a fixed-width table is the only thing it
/// will give you. That makes this the one place in `FlotillaCore` that reads a **human**
/// interface, and the reason the whole `k8s` family is treated as provisional.
///
/// ## Why it parses by column offset and not by splitting on spaces
///
/// The obvious parser — split the row on whitespace, zip with the headers — is not merely
/// fragile here, it is **silently wrong on the very first real cluster**. Captured output:
///
/// ```
/// CLUSTER  NODE     ROLE                  STATE    CPUS  MEMORY    ADDR           PORTS
///          k8s-dev  control-plane,worker  running  3     16384 MB  192.168.64.75  6445->6443
/// ```
///
/// Two things defeat splitting, and they cancel out:
///
/// 1. **`CLUSTER` is empty**, even for a cluster created with `--name k8s-dev`. The name is
///    reported under `NODE`. So the row is one field short.
/// 2. **`MEMORY` contains a space** — `16384 MB` is one column and two whitespace-separated
///    tokens. So the row is one field long.
///
/// The two errors cancel: a split yields exactly eight tokens for eight columns, so a naive
/// parser finds nothing wrong and hands back a row where `NODE` holds the role, `ROLE` holds the
/// state, `STATE` holds the CPU count and `MEMORY` holds the string `MB`. Nothing throws and
/// nothing looks broken until somebody reads it.
///
/// So the header line is the authority: it is measured for the column at which each name begins,
/// and every row is sliced at those offsets. The CLI recomputes its widths for each render, which
/// is exactly why the header has to come from the **same output** as the rows and never from a
/// remembered layout.
public enum K8sClusterList {

    /// Parses the command's output into nodes.
    ///
    /// Returns an empty array for output with no recognisable header, rather than guessing. A
    /// changed table is the failure this parser exists to survive, and inventing rows from a
    /// layout we do not recognise is worse than reporting none: the section can say it cannot
    /// read the output, which is true and actionable.
    public static func parse(_ output: String) -> [K8sNode] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: isHeader) else { return [] }

        let columns = self.columns(in: lines[headerIndex])
        // At least the two names that identify the table, and NODE specifically, since every row
        // is rejected without one. A header of unrecognised columns is not this table.
        guard columns.contains(where: { $0.name == "NODE" }) else { return [] }

        return lines[(headerIndex + 1)...].compactMap { line -> K8sNode? in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let field = { (name: String) -> String in value(of: name, in: line, columns: columns) }

            let node = field("NODE")
            // A row with no node name is not a node. It is the blank line before a footer, or a
            // layout this parser has misread; either way it must not become a row on screen.
            guard !node.isEmpty else { return nil }

            return K8sNode(
                cluster: field("CLUSTER"),
                node: node,
                roles: field("ROLE").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                state: field("STATE"),
                cpus: Int(field("CPUS")),
                memory: field("MEMORY"),
                address: field("ADDR"),
                ports: field("PORTS").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }

    /// Whether a line is the table's header.
    ///
    /// Two names rather than one, and neither of them `CLUSTER`: a single match would accept a
    /// data row containing the word, and `CLUSTER` is the column most likely to be renamed or
    /// dropped given it is the one that does not work.
    private static func isHeader(_ line: String) -> Bool {
        line.contains("NODE") && line.contains("STATE")
    }

    /// **Every** column in the header and the offset it begins at, recognised or not.
    ///
    /// Unrecognised ones are kept deliberately. They are not read, but they are boundaries: a
    /// future release that inserts `VERSION` between `NODE` and `ROLE` would otherwise have
    /// `NODE`'s slice run all the way to `ROLE` and swallow the version into the node name —
    /// which is what the first draft did, and what
    /// `anUnknownColumnIsIgnoredRatherThanShiftingTheOthers` now holds it to.
    private static func columns(in header: String) -> [(name: String, start: Int)] {
        var found: [(name: String, start: Int)] = []
        let characters = Array(header)
        var index = 0
        while index < characters.count {
            guard !characters[index].isWhitespace else { index += 1; continue }
            let start = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            found.append((String(characters[start..<index]), start))
        }
        return found
    }

    /// One field, sliced between its column's offset and the next column's.
    ///
    /// The last column runs to the end of the line, which is what lets `PORTS` hold a value
    /// wider than its own header. A line shorter than a column's start yields an empty string
    /// rather than a crash — rows are ragged when trailing values are absent.
    private static func value(of name: String, in line: String,
                              columns: [(name: String, start: Int)]) -> String {
        guard let position = columns.firstIndex(where: { $0.name == name }) else { return "" }
        let characters = Array(line)
        let start = columns[position].start
        guard start < characters.count else { return "" }
        let end = position + 1 < columns.count
            ? min(columns[position + 1].start, characters.count)
            : characters.count
        guard start < end else { return "" }
        return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
    }
}
