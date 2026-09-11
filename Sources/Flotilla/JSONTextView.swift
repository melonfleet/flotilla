import SwiftUI

/// JSON as a text editor shows it: a numbered gutter, syntax colour, and a surface of its own.
///
/// The Inspect tabs used to render the payload as plain secondary-coloured text on the window's
/// own background, which is legible and nothing more — every brace, key and value the same weight,
/// and no way to say "line 240" to anyone. Colour does the structural work here, the gutter does
/// the navigational work, and the raised surface separates a document you are reading from the
/// chrome around it.
///
/// Colour is the only thing carrying token *type*, which is fine — no decision depends on telling
/// a number from a string, and anyone who cannot see the difference still gets a correctly
/// indented, numbered document. The brand's own tokens are used rather than an editor theme, so
/// this looks like the rest of the app in both appearances.
struct JSONTextView: View {
    let json: String
    /// Lines not matching are dropped, as the plain view did. The filter stays line-based
    /// deliberately: dropping the enclosing braces would produce text that looks like JSON and is
    /// not, which is worse than a list of lines.
    var search: String = ""

    private var lines: [Line] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let all = json.split(separator: "\n", omittingEmptySubsequences: false)
        return all.enumerated().compactMap { index, raw in
            let text = String(raw)
            if !query.isEmpty, !text.localizedCaseInsensitiveContains(query) { return nil }
            // The *original* line number, so a filtered view still tells you where you are in the
            // document rather than numbering its own results 1…n.
            return Line(number: index + 1, text: text)
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                let rows = lines
                if rows.isEmpty {
                    Text("No line matches “\(search)”.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(line.number)")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: gutterWidth(for: rows.last?.number ?? 1),
                                           alignment: .trailing)
                                Text(Self.highlighted(line.text))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.vertical, 0.5)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    // A two-axis `ScrollView` centres content smaller than its viewport, which is
                    // what left the old plain-text view floating in the middle of the pane. See
                    // `MachineInspectTab` for the measurement.
                    .frame(minWidth: viewport.size.width,
                           minHeight: viewport.size.height,
                           alignment: .topLeading)
                }
            }
            .background(Theme.raisedSurface)
        }
    }

    /// Wide enough for the highest line number present, so the gutter does not resize as you
    /// scroll or filter.
    private func gutterWidth(for highest: Int) -> CGFloat {
        CGFloat(max(2, String(highest).count)) * 7.5
    }

    private struct Line: Identifiable {
        let number: Int
        let text: String
        var id: Int { number }
    }

    // MARK: Highlighting

    /// One line, coloured by token.
    ///
    /// A scanner rather than a regular expression: the shapes that matter here — a quoted string
    /// with escapes, a key distinguished from a string value only by the `:` that follows it —
    /// are exactly the ones a regex gets subtly wrong, and a mis-coloured line in a panel whose
    /// job is to be trustworthy about what a container is configured to do is not a small fault.
    static func highlighted(_ line: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(line)

        func emit(_ text: some StringProtocol, _ colour: Color) {
            var piece = AttributedString(String(text))
            piece.foregroundColor = colour
            out.append(piece)
        }

        while let first = rest.first {
            if first == "\"" {
                let (literal, remainder) = Self.scanString(rest)
                // A string followed by a colon is a key; anything else is a value. That is the
                // whole difference, and it is why this looks ahead rather than tracking state.
                let isKey = remainder.drop(while: { $0 == " " }).first == ":"
                emit(literal, isKey ? Theme.rind : Theme.info)
                rest = remainder
            } else if first.isNumber || (first == "-" && rest.dropFirst().first?.isNumber == true) {
                let literal = rest.prefix { $0.isNumber || $0 == "-" || $0 == "+" || $0 == "." || $0 == "e" || $0 == "E" }
                emit(literal, Theme.cantaloupe)
                rest = rest.dropFirst(literal.count)
            } else if rest.hasPrefix("true") || rest.hasPrefix("false") || rest.hasPrefix("null") {
                let literal = rest.hasPrefix("false") ? rest.prefix(5) : rest.prefix(4)
                emit(literal, Theme.accentText)
                rest = rest.dropFirst(literal.count)
            } else {
                // Punctuation, whitespace and indentation: deliberately quiet, so the structure
                // reads as structure and the content carries the colour.
                // Runs on until something that can *start* a token: a quote, a number, or the
                // first letter of true/false/null.
                let starters: Set<Character> = ["\"", "-", "t", "f", "n"]
                let literal = rest.prefix { !starters.contains($0) && !$0.isNumber }
                if literal.isEmpty {
                    emit(rest.prefix(1), .secondary)
                    rest = rest.dropFirst()
                } else {
                    emit(literal, .secondary)
                    rest = rest.dropFirst(literal.count)
                }
            }
        }
        return out
    }

    /// A complete JSON string literal including its quotes, honouring backslash escapes — so a
    /// value containing `\"` does not end the literal early and send the rest of the line into the
    /// wrong colour.
    private static func scanString(_ input: Substring) -> (Substring, Substring) {
        var index = input.index(after: input.startIndex)
        var escaped = false
        while index < input.endIndex {
            let character = input[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let end = input.index(after: index)
                return (input[input.startIndex..<end], input[end...])
            }
            index = input.index(after: index)
        }
        return (input, input[input.endIndex...])
    }
}
