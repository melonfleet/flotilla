import Foundation
import Testing
@testable import FlotillaCore

/// The Command field's tokenizer. The app target has no test target, so the split that decides what
/// a container is asked to run lives here, where it can be held to the shell's rules.

/// The bug, as measured on 2026-10-07. Splitting on whitespace handed `sh` the argument `'i=0;`,
/// and the container exited with "sh: syntax error: unterminated quoted string".
@Test func aSingleQuotedScriptIsOneArgument() throws {
    let typed = "sh -c 'i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done'"
    #expect(try ShellWords.split(typed) == [
        "sh", "-c", "i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done",
    ])
}

/// The field's own help example, which the old split broke the same way.
@Test func aDoubleQuotedScriptIsOneArgument() throws {
    #expect(try ShellWords.split(#"sh -c "while true; do date; sleep 5; done""#)
            == ["sh", "-c", "while true; do date; sleep 5; done"])
}

@Test func plainWordsSplitOnAnyRunOfWhitespace() throws {
    #expect(try ShellWords.split("  echo \t hello\nworld  ") == ["echo", "hello", "world"])
    #expect(try ShellWords.split("") == [])
    #expect(try ShellWords.split("   ") == [])
}

@Test func singleQuotesKeepEverythingLiteral() throws {
    // No escape inside single quotes: the backslash and the `$` both arrive as typed.
    #expect(try ShellWords.split(#"echo 'a\b $HOME "x"'"#) == ["echo", #"a\b $HOME "x""#])
}

/// POSIX: inside double quotes a backslash escapes only `"`, `\`, `$`, `` ` `` and newline, and is
/// otherwise itself.
@Test func doubleQuotesEscapeOnlyTheirOwnSpecials() throws {
    #expect(try ShellWords.split(#"echo "say \"hi\"" "a\\b" "\$HOME" "\`x\`""#)
            == ["echo", #"say "hi""#, #"a\b"#, "$HOME", "`x`"])
    #expect(try ShellWords.split(#"type "C:\temp\n""#) == ["type", #"C:\temp\n"#])
}

@Test func aBackslashOutsideQuotesEscapesTheNextCharacter() throws {
    #expect(try ShellWords.split(#"touch my\ file it\'s \\"#) == ["touch", "my file", "it's", #"\"#])
    // Backslash-newline joins the lines, as a shell does.
    #expect(try ShellWords.split("echo hel\\\nlo") == ["echo", "hello"])
}

/// Adjacent quoted and unquoted parts are one word, as in a shell.
@Test func quotedPiecesConcatenate() throws {
    #expect(try ShellWords.split(#"--opt="a b"'c d'e"#) == ["--opt=a bc de"])
}

/// `''` is an argument. Dropping it would shift every argument after it one place left.
@Test func emptyQuotesAreAnEmptyArgument() throws {
    #expect(try ShellWords.split("printf '%s|' '' x \"\"") == ["printf", "%s|", "", "x", ""])
}

/// Nothing is expanded or interpreted: there is no shell on the far side of `container run`.
@Test func operatorsAndExpansionsArePassedThroughLiterally() throws {
    #expect(try ShellWords.split("echo $HOME ~ *.txt # not a comment; ls | wc && true")
            == ["echo", "$HOME", "~", "*.txt", "#", "not", "a", "comment;", "ls", "|", "wc", "&&", "true"])
}

/// An open quote refuses to split rather than guessing. A guess is what reached the container.
@Test func unterminatedQuotesAreErrors() {
    #expect(throws: ShellWords.SplitError.unterminatedSingleQuote) {
        try ShellWords.split("sh -c 'i=0; while true")
    }
    #expect(throws: ShellWords.SplitError.unterminatedDoubleQuote) {
        try ShellWords.split(#"sh -c "echo hi"#)
    }
    #expect(throws: ShellWords.SplitError.unterminatedDoubleQuote) {
        try ShellWords.split(#"echo "abc\"#)
    }
    #expect(throws: ShellWords.SplitError.trailingBackslash) {
        try ShellWords.split(#"echo abc\"#)
    }
    // The other kind of quote does not close it.
    #expect(throws: ShellWords.SplitError.unterminatedSingleQuote) {
        try ShellWords.split(#"echo 'it"s"#)
    }
}

@Test func splitErrorsReadAsSentences() {
    for error in [ShellWords.SplitError.unterminatedSingleQuote, .unterminatedDoubleQuote, .trailingBackslash] {
        #expect(error.description.hasSuffix("."))
    }
}

/// A combining mark after a quote forms one `Character` with it. Splitting by scalar keeps the
/// quote a quote.
@Test func aCombiningMarkAfterAQuoteDoesNotHideIt() throws {
    #expect(try ShellWords.split("echo 'e\u{301}'") == ["echo", "e\u{301}"])
    #expect(try ShellWords.split("echo '\u{301}x'") == ["echo", "\u{301}x"])
}

@Test func plainArgumentsAreNotQuoted() {
    #expect(ShellWords.join(["container", "run", "--name", "web", "-p", "8080:80", "nginx:1.27",
                             "--env", "A=b,c", "/usr/bin/env", "user@host", "50%"])
            == "container run --name web -p 8080:80 nginx:1.27 --env A=b,c /usr/bin/env user@host 50%")
}

@Test func argumentsThatNeedQuotingAreSingleQuoted() {
    #expect(ShellWords.quote("i=0; echo $i") == "'i=0; echo $i'")
    #expect(ShellWords.quote("") == "''")
    #expect(ShellWords.quote("it's") == #"'it'\''s'"#)
    #expect(ShellWords.quote("~") == "'~'")
    #expect(ShellWords.quote("*.txt") == "'*.txt'")
    #expect(ShellWords.quote("café") == "'café'")
}

/// The preview of the measured command reads the way it was typed, rather than as the
/// misleading space-join of its tokens.
@Test func theMeasuredCommandRendersAsTyped() throws {
    let argv = try ShellWords.split("sh -c 'i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done'")
    #expect(ShellWords.join(argv) == "sh -c 'i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done'")
}

/// The property everything else rests on: text rendered by `join` splits back to the same argv,
/// so a Group member's saved command survives being shown in a field and saved again.
@Test func joinThenSplitIsTheIdentity() throws {
    let samples: [[String]] = [
        [],
        ["echo", "hello"],
        ["sh", "-c", "i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done"],
        [""], ["", ""], ["a", "", "b"],
        ["it's", #"say "hi""#, #"back\slash"#, "$HOME", "`x`", "~", "*", "#"],
        ["line\nbreak", "tab\there", "  padded  "],
        ["'", "''", "\"", "\\", "'\\''"],
        ["e\u{301}", "\u{301}", "naïve", "日本語", "🍉"],
    ]
    for argv in samples {
        #expect(try ShellWords.split(ShellWords.join(argv)) == argv, "\(argv)")
    }
}

/// End to end, the way the Run form does it: split the field, build the run argv, validate it.
/// The script must reach the container as **one** argument, and the preview — the validated argv —
/// must show it quoted, not as a space-join that reads like a different command.
@Test func theRunFormsCommandReachesTheContainerAsTyped() throws {
    let typed = "sh -c 'i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done'"
    let argv = ContainerCLI.runArguments(image: "alpine", options: .init(detach: true),
                                         command: try ShellWords.split(typed))
    let validated = try Allowlist.validated(argv, mountPolicy: .unrestricted)
    #expect(Array(validated.arguments.suffix(3))
            == ["sh", "-c", "i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done"])
    #expect(!validated.arguments.contains("--"))
    #expect(validated.localPreview.hasSuffix(" alpine " + typed))
}
