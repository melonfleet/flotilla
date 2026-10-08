import Foundation
import Testing
@testable import FlotillaCore

/// Pins the CSV escaping.
///
/// Every case here produces a file that opens without complaint and is silently wrong if the
/// rule is missed — a message split across two rows, a column shifted for the rest of the file,
/// or a formula that runs. That is exactly why this is not written inline in a view.
@Suite("CSV export")
struct CSVWriterTests {

    @Test("a plain field is not quoted")
    func plainField() {
        #expect(CSVWriter.field("hello") == "hello")
        #expect(CSVWriter.field("") == "")
        #expect(CSVWriter.field("nginx:latest") == "nginx:latest")
    }

    @Test("commas, quotes and newlines force quoting")
    func specialCharacters() {
        #expect(CSVWriter.field("a,b") == "\"a,b\"")
        #expect(CSVWriter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVWriter.field("line\nbreak") == "\"line\nbreak\"")
        #expect(CSVWriter.field("carriage\rreturn") == "\"carriage\rreturn\"")
    }

    /// Leading whitespace survives only inside quotes, and a log line that begins with
    /// indentation is one where the indentation is the information — a stack trace, say.
    @Test("surrounding whitespace is preserved by quoting")
    func whitespace() {
        #expect(CSVWriter.field("    at Foo.bar") == "\"    at Foo.bar\"")
        #expect(CSVWriter.field("trailing ") == "\"trailing \"")
    }

    /// Not RFC 4180: a defence against spreadsheet formula injection. Container logs are written
    /// by whatever runs in the container, and this file exists to be opened in a spreadsheet.
    @Test("a field that a spreadsheet would run as a formula is neutralised")
    func formulaInjection() {
        #expect(CSVWriter.field("=1+1") == "\"'=1+1\"")
        #expect(CSVWriter.field("=cmd|'/c calc'!A1") == "\"'=cmd|'/c calc'!A1\"")
        #expect(CSVWriter.field("+44 7700 900000") == "\"'+44 7700 900000\"")
        #expect(CSVWriter.field("-1") == "\"'-1\"")
        #expect(CSVWriter.field("@SUM(A1)") == "\"'@SUM(A1)\"")
        // Only at the start. A minus sign inside a message is just a minus sign.
        #expect(CSVWriter.field("exit code -1") == "exit code -1")
    }

    /// RFC 4180 §2.1 says CRLF, and Excel on Windows is why it says so.
    @Test("a document is CRLF-terminated, header first")
    func document() {
        let csv = CSVWriter.document(header: ["a", "b"], rows: [["1", "2"], ["x,y", "z"]])
        #expect(csv == "a,b\r\n1,2\r\n\"x,y\",z\r\n")
    }

    /// The round trip that matters: a message containing a newline must come back as one field,
    /// not as two rows.
    @Test("an embedded newline stays inside one field")
    func embeddedNewlineDoesNotSplitTheRow() {
        let csv = CSVWriter.document(header: ["Message"], rows: [["one\ntwo"]])
        #expect(csv == "Message\r\n\"one\ntwo\"\r\n")
        // Three physical lines, one logical record — which is the whole point of the quoting.
        #expect(csv.components(separatedBy: "\r\n").count == 3)
    }
}
