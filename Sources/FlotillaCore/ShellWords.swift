import Foundation

/// A command typed as one line of text, split into argv the way `/bin/sh` would split it — and an
/// argv rendered back into a line that splits to the same argv.
///
/// ## Why this exists
///
/// The Run form split its Command field on whitespace. `sh -c 'i=0; while true; do …; done'` became
/// `sh`, `-c`, `'i=0;`, `while`, … and the container died with "unterminated quoted string" — while
/// the preview, joining those same tokens with spaces, showed the quotes as though they had been
/// honoured. The command and its preview agreed with each other and with nothing the user meant.
/// Measured live against a paired Mac mini on 2026-10-07.
///
/// ## What it does, and deliberately does not
///
/// Quoting only, because quoting is the part of shell syntax people type without thinking of it as
/// syntax:
///
/// - outside quotes, spaces, tabs and newlines separate arguments, and `\` makes the next
///   character literal (`\` before a newline joins the lines, as in a shell);
/// - inside `'…'` every character is literal, and there is no escape;
/// - inside `"…"`, `\` escapes only `"`, `\`, `$`, `` ` `` and a newline, and is otherwise kept —
///   POSIX's rule, so a Windows-ish `"C:\temp"` survives;
/// - `''` and `""` are a real, empty argument.
///
/// Nothing is **expanded**: no `$VARIABLES`, `~`, globs, command substitution, comments, `;`, `|`
/// or `&&`. Those are characters like any other and reach the program as written. `container run`
/// executes argv directly — there is no shell on the other end — so pretending to have one here
/// would be a second lie of the same kind. Someone who wants a shell writes `sh -c '…'`, and the
/// shell inside the container does the expanding.
///
/// Foundation-only and in `FlotillaCore` so it is tested, and so Groups, the Run form and anything
/// later that edits a command as text all split it one way.
public enum ShellWords {
    public enum SplitError: Error, Equatable, Sendable, CustomStringConvertible {
        case unterminatedSingleQuote
        case unterminatedDoubleQuote
        /// A `\` with nothing after it. A shell would wait for another line; a one-line field has
        /// no other line, so this is a mistake rather than a continuation.
        case trailingBackslash

        public var description: String {
            switch self {
            case .unterminatedSingleQuote:
                "A single quote (') is never closed."
            case .unterminatedDoubleQuote:
                "A double quote (\") is never closed."
            case .trailingBackslash:
                "The command ends with a backslash (\\) that escapes nothing."
            }
        }
    }

    /// Splits `text` into arguments. Throws rather than guessing when a quote is left open: running
    /// a best guess is how the original bug reached a container.
    public static func split(_ text: String) throws(SplitError) -> [String] {
        // Scalars, not `Character`s: a combining mark after a quote forms one grapheme with it,
        // and `"'\u{301}"` would then fail to compare equal to `'` and the quote would vanish.
        var words: [String] = []
        var current = String.UnicodeScalarView()
        // Separate from `current.isEmpty`, because `''` is an argument that happens to be empty.
        var inWord = false
        var scalars = text.unicodeScalars.makeIterator()

        func finishWord() {
            if inWord { words.append(String(current)) }
            current = String.UnicodeScalarView()
            inWord = false
        }

        while let scalar = scalars.next() {
            switch scalar {
            case " ", "\t", "\n", "\r":
                finishWord()
            case "\\":
                guard let next = scalars.next() else { throw .trailingBackslash }
                if next == "\n" { continue }
                current.append(next)
                inWord = true
            case "'":
                inWord = true
                var closed = false
                while let inner = scalars.next() {
                    if inner == "'" { closed = true; break }
                    current.append(inner)
                }
                guard closed else { throw .unterminatedSingleQuote }
            case "\"":
                inWord = true
                var closed = false
                while let inner = scalars.next() {
                    if inner == "\"" { closed = true; break }
                    if inner == "\\" {
                        guard let next = scalars.next() else { throw .unterminatedDoubleQuote }
                        switch next {
                        case "\"", "\\", "$", "`": current.append(next)
                        case "\n": break
                        default: current.append(inner); current.append(next)
                        }
                        continue
                    }
                    current.append(inner)
                }
                guard closed else { throw .unterminatedDoubleQuote }
            default:
                current.append(scalar)
                inWord = true
            }
        }
        finishWord()
        return words
    }

    /// One argument, quoted for `/bin/sh` only if it needs to be. Plain words stay plain, so the
    /// common preview reads exactly as it did; anything else is single-quoted, with a `'` inside
    /// written as `'\''`. `split(quote(x)) == [x]` for every `x`.
    public static func quote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        if argument.unicodeScalars.allSatisfy(isPlain) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An argv as one line a person can read, copy into a terminal, or type back into a Command
    /// field — `split(join(argv)) == argv`.
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    /// Characters no POSIX shell treats specially anywhere in a word. ASCII only, and `~` is left
    /// out because it expands at the start of one; a word that needs no quotes but gets them is
    /// still correct, which is the safe direction to be wrong in.
    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        case "_", "-", ".", "/", ":", "=", "+", ",", "@", "%": true
        default: false
        }
    }
}
