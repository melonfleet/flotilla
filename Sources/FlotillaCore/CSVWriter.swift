import Foundation

/// Writes RFC 4180 CSV.
///
/// **In the core, with tests, because CSV is exactly the kind of thing that looks trivial and
/// is not.** A log line can contain a comma, a double quote, a newline, a leading `=`, or all
/// four; every one of those has a rule, and getting one wrong produces a file that opens without
/// complaint and is silently wrong — a message split across two rows, or a column shifted for
/// the rest of the file. Writing it inline in a view would mean the rules live somewhere nothing
/// can check them.
///
/// ## The leading-punctuation rule is not RFC 4180
///
/// A field beginning with `=`, `+`, `-` or `@` is quoted **and** prefixed with a single quote.
/// That is not CSV; it is a defence against spreadsheet formula injection, in which a log line
/// beginning `=cmd|'/c calc'!A1` becomes an executable formula the moment the exported file is
/// opened in Excel or Numbers. Container logs are attacker-influenced by definition — anything
/// running in a container writes them — and this file is exported specifically to be opened in a
/// spreadsheet. The prefix is visible in the cell, which is the honest trade: a leading
/// apostrophe you can see beats a formula you cannot.
public enum CSVWriter {

    /// Characters that, at the start of a field, make a spreadsheet treat it as a formula.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@"]

    /// One field, escaped.
    public static func field(_ raw: String) -> String {
        var value = raw
        var mustQuote = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")

        if let first = value.first, Self.formulaLeaders.contains(first) {
            value = "'" + value
            mustQuote = true
        }
        // Leading or trailing whitespace survives only inside quotes; a log line that begins
        // with indentation is one where the indentation is the information.
        if value.hasPrefix(" ") || value.hasSuffix(" ") { mustQuote = true }

        guard mustQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    /// A whole document: a header row, then the data.
    ///
    /// CRLF line endings, per RFC 4180 §2.1. Excel on Windows is the reason the specification
    /// says so and the reason this does not quietly use `\n`.
    public static func document(header: [String], rows: [[String]]) -> String {
        ([row(header)] + rows.map(row)).joined(separator: "\r\n") + "\r\n"
    }
}
