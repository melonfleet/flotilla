import SwiftUI
import FlotillaCore

/// The severity a log line states about itself, when it states one.
///
/// `container logs` carries no level — only stdout and stderr — so this reads the line's own
/// text, and only where the line says so plainly: `ERROR`, `WARN` and the like in capitals near
/// the start, or any case where a logger brackets or labels it (`[error]`, `level=warn`,
/// `"level":"info"`). A word in ordinary prose ("Starting error handler") is not a level, and a
/// wrong chip on a line is worse than none, so everything that is not plainly one is nil.
enum LogLevel: String, CaseIterable {
    case error, warning, info, debug

    var title: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    var colour: Color {
        switch self {
        case .error: Theme.danger
        case .warning: Theme.warning
        case .info: .secondary
        case .debug: .secondary
        }
    }

    /// How far into a line a level may sit. Loggers put it first; a word 200 characters in is prose.
    private static let window = 96
    private static let tokens = 8

    private static let words: [String: LogLevel] = [
        "error": .error, "err": .error, "fatal": .error, "critical": .error, "crit": .error,
        "emerg": .error, "panic": .error, "severe": .error,
        "warn": .warning, "warning": .warning,
        "info": .info,
        "debug": .debug, "trace": .debug, "dbg": .debug,
    ]

    /// The line's level, or nil. Looks at the first `window` characters only, so it costs the same
    /// on a one-line stack trace as on a short message.
    static func of(_ text: String) -> LogLevel? {
        var word = ""
        var seen = 0
        // The character before the current word, and the one before that, to see `[`, `=` and `"level":"`.
        var before: Character = " "
        var labelled = false   // the previous word was `level`, `lvl`, `severity` or `loglevel`
        var upper = true       // every letter in the current word is a capital
        var started: Character = " "

        func finish() -> LogLevel? {
            guard !word.isEmpty else { return nil }
            defer { word = ""; upper = true; seen += 1 }
            let lower = word.lowercased()
            if ["level", "lvl", "severity", "loglevel"].contains(lower) { labelled = true; return nil }
            guard let level = words[lower] else { labelled = false; return nil }
            let wasLabelled = labelled
            labelled = false
            // Bracketed or labelled: any case. Otherwise it has to be shouted.
            if started == "[" || started == "(" || wasLabelled || (upper && word.count > 2) { return level }
            return nil
        }

        for character in text.prefix(window) {
            if character.isLetter {
                if word.isEmpty { started = before }
                if !character.isUppercase { upper = false }
                word.append(character)
            } else {
                if let level = finish() { return level }
                if seen >= tokens { return nil }
            }
            before = character
        }
        return finish()
    }
}

/// A coloured capsule for a level, drawn on a row's first line.
struct LogLevelChip: View {
    let level: LogLevel

    var body: some View {
        Text(level.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(level.colour)
            .lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(level.colour.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// `2026-09-13 12:04:50`, fixed, 24-hour, no AM/PM and no locale.
///
/// The format the Received column had, and for the reasons it had it: the date matters because
/// the feed can carry lines read minutes or hours apart, and a fixed format must not be
/// reinterpreted by whatever calendar or numbering system the Mac is set to.
enum LogTimestamp {
    static func full(_ date: Date) -> String {
        date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 timeZone: .current,
                                 calendar: Calendar(identifier: .gregorian)))
    }

    /// The time alone, for a row: the date is on the page.
    static func clock(_ date: Date) -> String {
        date.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                                 locale: Locale(identifier: "en_US_POSIX"),
                                 timeZone: .current,
                                 calendar: Calendar(identifier: .gregorian)))
    }
}

/// One log line's own page, in the right pane: the whole message, wrapped and selectable, then what
/// is known about where it came from.
struct LogLineDetailView: View {
    let line: AggregatedLogLine
    let open: () -> Void
    let copy: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.kind.systemImage).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(line.name).font(.title3.weight(.semibold)).lineLimit(2)
                        .textSelection(.enabled)
                    if let level = LogLevel.of(line.text) { LogLevelChip(level: level) }
                    Spacer(minLength: 0)
                }

                // Monospaced, wrapped, selectable: the one place a long line is read whole.
                Text(line.stream == .notice ? "[Flotilla] \(line.text)" : line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }

                DetailCard(title: "Details", minHeight: nil) {
                    row("Time", line.receivedAt.map(LogTimestamp.full) ?? "\u{2014}")
                    row("Source", line.name)
                    row("Kind", line.kind == .machine ? "Machine" : "Container")
                    row("Mac", line.host.isLocal ? "This Mac" : line.hostName)
                    row("Stream", streamText)
                    row("Line", "\(line.index + 1)")
                }
                Text("container logs has no timestamps of its own, so the time is when Flotilla "
                     + "received the line: per line while streaming, and one shared read time "
                     + "per source when fetched.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy", action: copy)
        Button("Open \(line.name) Logs", action: open)
    }

    private var streamText: String {
        switch line.stream {
        case .stdout: "stdout"
        // The CLI's stderr, not the container's own: `container logs` writes program output to stdout.
        case .stderr: "stderr"
        case .notice: "Flotilla notice (not the container\u{2019}s output)"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
