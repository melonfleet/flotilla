import Foundation

/// One line of `container image pull` progress.
///
/// The CLI emits these to **stderr**, one per second or so, and leaves stdout empty; on a pipe
/// they are newline-terminated rather than a redrawn terminal bar, which is why a line reader is
/// enough and no PTY is involved. See `Fixtures/pull-progress.txt` for a real transcript.
///
/// `detail` keeps the CLI's own parenthetical verbatim instead of re-parsing it into bytes and
/// rates. The CLI's "MB" and "KB" are ambiguous between decimal and binary, so reformatting them
/// would either invent precision we never measured or quietly disagree with what the same CLI
/// prints in a terminal.
///
/// `fraction` is **not monotonic**: the CLI discovers the blob count as it walks the manifest, so
/// 99% of 17 blobs becomes 8% of 96. A caller must not assume it only increases.
public struct ImagePullProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case fetching
        case unpacking
    }

    public let step: Int
    public let stepCount: Int
    public let phase: Phase
    public let platform: String?
    public let fraction: Double?
    public let detail: String?
    public let elapsed: TimeInterval

    public init?(line: String) {
        guard line.first == "[",
              let stepEnd = line.firstIndex(of: "]"),
              line[stepEnd...].hasPrefix("] ")
        else { return nil }

        let stepStart = line.index(after: line.startIndex)
        let stepParts = line[stepStart..<stepEnd].split(separator: "/", omittingEmptySubsequences: false)
        guard stepParts.count == 2,
              let step = Int(stepParts[0]),
              let stepCount = Int(stepParts[1]),
              step > 0,
              stepCount > 0,
              step <= stepCount
        else { return nil }

        let contentStart = line.index(stepEnd, offsetBy: 2)
        var content = String(line[contentStart...])
        let phase: Phase
        if content.hasPrefix("Fetching image") {
            phase = .fetching
            content.removeFirst("Fetching image".count)
        } else if content.hasPrefix("Unpacking image") {
            phase = .unpacking
            content.removeFirst("Unpacking image".count)
        } else {
            return nil
        }

        guard content.last == "]",
              let elapsedStart = content.range(of: " [", options: .backwards)
        else { return nil }

        let middle = String(content[..<elapsedStart.lowerBound])
        let elapsedToken = content[elapsedStart.upperBound..<content.index(before: content.endIndex)]
        guard elapsedToken.last == "s",
              let elapsed = Self.decimal(elapsedToken.dropLast()),
              elapsed >= 0
        else { return nil }

        var options = middle
        var platform: String?
        if options.hasPrefix(" for platform ") {
            options.removeFirst(" for platform ".count)
            let platformEnd = options.firstIndex(of: " ") ?? options.endIndex
            let candidate = String(options[..<platformEnd])
            guard Self.isPlatform(candidate) else { return nil }
            platform = candidate
            options = String(options[platformEnd...])
        }

        var fraction: Double?
        if !options.isEmpty, !options.hasPrefix(" (") {
            guard options.first == " ",
                  let percentEnd = options.firstIndex(of: "%")
            else { return nil }

            let valueStart = options.index(after: options.startIndex)
            guard let percent = Self.decimal(options[valueStart..<percentEnd]),
                  (0...100).contains(percent)
            else { return nil }

            fraction = percent / 100
            options = String(options[options.index(after: percentEnd)...])
        }

        var detail: String?
        if !options.isEmpty {
            guard options.hasPrefix(" ("), options.last == ")" else { return nil }
            let detailStart = options.index(options.startIndex, offsetBy: 2)
            let detailEnd = options.index(before: options.endIndex)
            let candidate = String(options[detailStart..<detailEnd])
            guard !candidate.isEmpty,
                  !candidate.contains("("),
                  !candidate.contains(")"),
                  !candidate.contains("\n"),
                  !candidate.contains("\r")
            else { return nil }
            detail = candidate
        }

        self.step = step
        self.stepCount = stepCount
        self.phase = phase
        self.platform = platform
        // The CLI revises discovered totals while fetching, so this value intentionally
        // reflects each line as emitted rather than being forced to increase.
        self.fraction = fraction
        self.detail = detail
        self.elapsed = elapsed
    }

    private static func decimal<S: StringProtocol>(_ text: S) -> Double? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) })
        else { return nil }
        return Double(String(text))
    }

    private static func isPlatform(_ text: String) -> Bool {
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        return (2...3).contains(components.count)
            && components.allSatisfy { component in
                !component.isEmpty && component.utf8.allSatisfy { byte in
                    (48...57).contains(byte)
                        || (65...90).contains(byte)
                        || (97...122).contains(byte)
                        || byte == 45
                        || byte == 46
                        || byte == 95
                }
            }
    }
}
