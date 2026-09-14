import Foundation

/// One line of `container k8s create`'s progress.
///
/// The command reports itself as it goes — `[2/2] Waiting for cluster to be ready [12m 3s]` —
/// and a create takes minutes, so this is the difference between a panel that says what is
/// happening and a spinner that says nothing for a quarter of an hour.
public struct K8sCreateProgress: Sendable, Equatable {
    /// `2` of `[2/2]`, when the line carries a counter.
    public let step: Int?
    /// `2` of `[2/2]`.
    public let total: Int?
    /// What the CLI says it is doing, without the counter or the clock.
    public let phase: String
    /// The CLI's own elapsed time, `12m 3s`. Its clock, not ours: a timer of our own would
    /// start when Flotilla noticed rather than when the work began, and disagree on screen.
    public let elapsed: String?

    public init(step: Int?, total: Int?, phase: String, elapsed: String?) {
        self.step = step
        self.total = total
        self.phase = phase
        self.elapsed = elapsed
    }

    /// What to show: the phase, with the counter and clock when there are any.
    ///
    /// `Waiting for cluster to be ready · 2 of 2 · 12m 3s`
    public var summary: String {
        var parts = [phase]
        if let step, let total { parts.append("\(step) of \(total)") }
        if let elapsed { parts.append(elapsed) }
        return parts.joined(separator: " · ")
    }
}

extension K8sCreateProgress {

    /// Parses one line, or `nil` when it carries nothing worth showing.
    ///
    /// Shapes seen in a real 12-minute create, captured in `k8s-create-progress.txt`:
    ///
    /// ```
    /// [2/2] Waiting for cluster to be ready [12m 3s]
    /// Waiting for kube-system pods to become ready
    /// Fetching kubeconfig: ["cluster": k8s-dev]
    /// Writing kubeconfig: ["cluster": k8s-dev, "path": /Users/…/.kube/config]
    /// [2/2] Writing kubeconfig [12m 18s]
    /// k8s-dev
    /// ```
    ///
    /// The last line is the cluster's name on stdout — the command's *result*, not progress, and
    /// showing it as a phase would put a bare word on screen where a sentence belongs. It is
    /// dropped by the rule that a line with no counter, no clock and no space in it is not a
    /// phase.
    ///
    /// The `Fetching`/`Writing kubeconfig:` lines carry a Swift dictionary literal, which is a
    /// log line that escaped rather than anything meant for a person. The key part is kept and
    /// the dictionary dropped.
    public static func parse(_ raw: String) -> K8sCreateProgress? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        var step: Int?
        var total: Int?
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let inside = String(line[line.index(after: line.startIndex)..<close])
            let halves = inside.split(separator: "/")
            if halves.count == 2, let a = Int(halves[0]), let b = Int(halves[1]) {
                step = a
                total = b
                line = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // A trailing `[12m 18s]`. Taken from the end rather than by searching, so a phase that
        // itself contained brackets could not be mistaken for the clock.
        var elapsed: String?
        if line.hasSuffix("]"), let open = line.lastIndex(of: "[") {
            let inside = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            if !inside.isEmpty, inside.allSatisfy({ $0.isNumber || $0.isLetter || $0 == " " || $0 == "." }) {
                elapsed = inside
                line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Drop a trailing Swift dictionary literal — `Fetching kubeconfig: ["cluster": k8s-dev]`
        // is a log statement, and the half after the colon is not for reading.
        if let colon = line.firstIndex(of: ":"),
           line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            line = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        }

        guard !line.isEmpty else { return nil }
        // The command prints the cluster's name on success. It is the result, not a phase.
        guard step != nil || elapsed != nil || line.contains(" ") else { return nil }

        return K8sCreateProgress(step: step, total: total, phase: line, elapsed: elapsed)
    }
}
