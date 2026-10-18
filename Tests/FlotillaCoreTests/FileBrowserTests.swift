import Foundation
import Testing
@testable import FlotillaCore

@Test func filesParseCapturedListing() throws {
    // Captured from /bin/ls -lan in an isolated directory on macOS. Numeric owners avoid
    // capturing the host account; -n changes owner/group display, not the metadata grammar.
    let url = try #require(Bundle.module.url(forResource: "files-ls-lan", withExtension: "txt", subdirectory: "Fixtures"))
    let entries = FileEntry.parse(try String(contentsOf: url, encoding: .utf8), directory: "/data")
    #expect(entries.count == 4)
    let folder = try #require(entries.first { $0.name == "Documents" })
    #expect(folder.kind == .directory)
    #expect(folder.path == "/data/Documents")
    #expect(folder.sizeLabel == "—")
    let file = try #require(entries.first { $0.name == "My Notes.txt" })
    #expect(file.kind == .file)
    #expect(file.sizeBytes == 6)
    #expect(file.kindLabel == "TXT File")
    #expect(file.modifiedDate != nil)
    let link = try #require(entries.first { $0.name == "shortcut" })
    #expect(link.kind == .symbolicLink)
    #expect(link.symlinkTarget == "My Notes.txt")
    #expect(!link.isDirectory)
    let old = try #require(entries.first { $0.name == "old.txt" })
    let date = try #require(old.modifiedDate)
    #expect(Calendar.current.component(.year, from: date) == 2022)
}

@Test func filesParseDateRolloverAndMalformedRows() throws {
    // Unit cases for ls's omitted-year convention, not fabricated live fixtures.
    let calendar = Calendar(identifier: .gregorian)
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2)))
    let entries = FileEntry.parse("""
    total 4
    drwxr-xr-x 2 0 0 4096 Jan 1 12:00 .
    drwxr-xr-x 2 0 0 4096 Jan 1 12:00 ..
    -rw-r--r-- 1 0 0 12 Dec 31 23:59 New Year's notes
    -rw-r--r-- 1 0 0 42 Unknown 99 nope bad-date
    malformed
    """, now: now)
    #expect(entries.count == 2)
    #expect(entries[0].name == "New Year's notes")
    #expect(calendar.component(.year, from: try #require(entries[0].modifiedDate)) == 2025)
    #expect(entries[1].modifiedDate == nil)
}

@Test func filesValidateNamesAndPaths() throws {
    for value in ["", ".", "..", "a/b", "a\nname", "nul\0", String(repeating: "a", count: 256)] {
        #expect(!FileCommand.isValidName(value))
        #expect(throws: (any Error).self) { try FileCommand.makeDirectory(parent: "/tmp", name: value).arguments(containerID: "web") }
    }
    for value in ["My Folder", "-rf", "$(touch pwned)", "a; b", "Résumé.txt", ".config"] {
        #expect(FileCommand.isValidName(value))
    }
    for path in ["/", "//", "relative", "/a/../b", "/a/./b", "/a\nb"] {
        #expect(throws: (any Error).self) { try FileCommand.delete(path: path, directory: true).arguments(containerID: "web") }
    }
}

@Test func filesArgvBuildersAndCapabilityBoundaries() throws {
    let commands: [(FileCommand, [String])] = [
        (.makeDirectory(parent: "/tmp", name: "-new folder"), ["mkdir", "--", "/tmp/-new folder"]),
        (.move(source: "/tmp/a;whoami", destination: "/tmp/b"), ["mv", "-nT", "--", "/tmp/a;whoami", "/tmp/b"]),
        (.delete(path: "/tmp/a", directory: false), ["rm", "--", "/tmp/a"]),
        (.delete(path: "/tmp/a", directory: true), ["rm", "-r", "--", "/tmp/a"]),
        (.find(directory: "/tmp", term: "a *?[x]$(id)"), ["find", "/tmp", "-iname", "*a \\*\\?\\[x\\]$(id)*", "-print0"])
    ]
    for (command, tail) in commands {
        let argv = try command.arguments(containerID: "web")
        #expect(argv == ["exec", "web", "--"] + tail)
        let validated = try Allowlist.validated(argv, execPolicy: .interactiveShell)
        // exec's own -- is removed, the utility's remains. Check the canonical form too.
        #expect(validated.arguments == ["exec", "web"] + tail)
        #expect(throws: AllowlistError.self) { try Allowlist.validated(argv) }
        #expect(throws: AllowlistError.self) { try Allowlist.validated(argv, execPolicy: .interactiveShell, wirePolicy: .remotePeer) }
    }
    for term in ["", String(repeating: "x", count: 201), "a\nb"] {
        #expect(throws: (any Error).self) { try FileCommand.find(directory: "/", term: term).arguments(containerID: "web") }
    }
}

@Test func filesGroupingUsesOnlyAvailableMetadata() throws {
    let entries = FileEntry.parse("""
    drwxr-xr-x 2 0 0 4096 Jul 15 2025 Documents
    -rw-r--r-- 1 0 0 24 Jul 15 2025 apple.txt
    -rw-r--r-- 1 0 0 2048 Jul 16 2025 Another.txt
    -rw-r--r-- 1 0 0 2097152 Jul 16 2025 zoo.png
    """)
    #expect(FileGrouping.none.groups(entries).count == 1)
    #expect(FileGrouping.none.groups(entries)[0].entries == entries)
    #expect(FileGrouping.name.groups(entries).map(\.name) == ["A", "D", "Z"])
    #expect(FileGrouping.kind.groups(entries).map(\.name) == ["Folder", "PNG File", "TXT File"])
    #expect(FileGrouping.modified.groups(entries).map(\.name) == ["2025-07-16", "2025-07-15"])
    #expect(FileGrouping.size.groups(entries).map(\.name) == ["Folders", "Under 1 KB", "1 KB – 1 MB", "1 MB – 1 GB"])
    for unavailable in [FileGrouping.created, .opened, .added, .application, .tags] { #expect(!unavailable.available) }
}

private final class FilesHost: ContainerHost, @unchecked Sendable {
    var arguments: [String] = []
    var calls: [[String]] = []
    var timeout: TimeInterval = 0
    var result = CommandResult(stdout: "", stderr: "", exitCode: 0)
    func run(_ args: [String]) throws -> CommandResult { arguments = args; calls.append(args); return result }
    func run(_ args: [String], timeout: TimeInterval, onLine: (@Sendable (String) -> Void)?) throws -> CommandResult {
        self.timeout = timeout; return try run(args)
    }
}

@Test func filesCLIHasDeadlinesChecksFailuresAndCapsSearch() throws {
    let host = FilesHost()
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    try cli.performFileCommand(.makeDirectory(parent: "/", name: "new"), in: "web")
    #expect(host.timeout == 30)
    #expect(host.arguments == ["exec", "web", "mkdir", "--", "/new"])
    _ = try cli.listDirectory("web", path: "/")
    #expect(host.timeout == 15)
    #expect(host.arguments == ["exec", "web", "find", "/", "-mindepth", "1", "-maxdepth", "1", "-print0"])
    host.result = CommandResult(stdout: (0..<600).map { "/tmp/file\($0)" }.joined(separator: "\0") + "\0", stderr: "", exitCode: 0)
    let search = try cli.searchFiles("web", directory: "/tmp", term: "file")
    #expect(host.timeout == 10)
    #expect(search.paths.count == 500)
    #expect(search.capped)
    host.result = CommandResult(stdout: "", stderr: "permission denied", exitCode: 1)
    #expect(throws: ContainerCLIError.self) { try cli.performFileCommand(.delete(path: "/tmp/a", directory: false), in: "web") }
    let restricted = ContainerCLI(host: host, wirePolicy: .localOwner)
    #expect(throws: AllowlistError.self) { try restricted.performFileCommand(.delete(path: "/tmp/a", directory: false), in: "web") }
    let remote = ContainerCLI(host: host, mountPolicy: .denyHostPaths, execPolicy: .interactiveShell, wirePolicy: .remotePeer)
    #expect(throws: AllowlistError.self) { try remote.performFileCommand(.delete(path: "/tmp/a", directory: false), in: "web") }
    #expect(throws: AllowlistError.self) { try remote.listDirectory("web", path: "/") }
}

@Test func machinesFilesCannotUseTheExistingShellGrammar() throws {
    // The captured CLI help offers argv, but the current owner-shell capability deliberately
    // permits only the login shell and boot no-op. Do not silently widen it for a Files tab.
    for policy in [ExecPolicy.processListOnly, .interactiveShell] {
        #expect(throws: AllowlistError.self) {
            try Allowlist.validated(["machine", "run", "--name", "dev", "--", "ls", "-la", "--", "/"], execPolicy: policy)
        }
    }
}

@Test func filesNewlineNamesNeverAliasAnOrdinaryFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["report\nold", "report", " leading space", "literal -> arrow"] {
        try Data(name.utf8).write(to: directory.appendingPathComponent(name))
    }
    // Real ls output reproduces the lossy metadata row; find's NUL records supply identities.
    func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
    let raw = try output("/bin/ls", ["-lan", "--", directory.path])
    let names = try output("/usr/bin/find", [directory.path, "-mindepth", "1", "-maxdepth", "1", "-print0"])
    let entries = try FileEntry.listing(raw, pathsOutput: names, directory: directory.path)
    #expect(entries.count == 4)
    #expect(Set(entries.map(\.path)).count == 4)
    let newline = try #require(entries.first { $0.name == "report\nold" })
    let ordinary = try #require(entries.first { $0.name == "report" })
    #expect(newline.path != ordinary.path)
    #expect(newline.mutationRestriction?.contains("Read-only") == true)
    #expect(throws: ContainerCLIError.self) { try newline.requireMutable() }
    #expect(throws: ContainerCLIError.self) { try FileCommand.delete(path: newline.path, directory: false).arguments(containerID: "web") }
    #expect(throws: ContainerCLIError.self) { try FileCommand.move(source: newline.path, destination: "/new").arguments(containerID: "web") }
    try ordinary.requireMutable()
    for entry in entries where entry.name != newline.name { try entry.requireMutable() }
    // Bare ls output can never authorize mutation, even if the row looks ordinary.
    for entry in FileEntry.parse(raw, directory: directory.path) {
        #expect(throws: ContainerCLIError.self) { try entry.requireMutable() }
    }
}

@Test func filesListingRejectsIncompleteOrForeignNames() throws {
    for names in ["/data/report", "/elsewhere/report\0", "/data/nested/report\0"] {
        #expect(throws: ContainerCLIError.self) {
            try FileEntry.listing("", pathsOutput: names, directory: "/data")
        }
    }
    let invalidUTF8 = try FileEntry.listing("", pathsOutput: "/data/\u{FFFD}\0", directory: "/data")
    #expect(throws: ContainerCLIError.self) { try invalidUTF8[0].requireMutable() }
}

@Test func filesMoveRequiresExactDestinationAndNeverRetriesWithoutT() throws {
    let host = FilesHost()
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    for source in ["/data/report", "/data/folder"] {
        host.calls = []
        try cli.performFileCommand(.move(source: source, destination: "/data/destination"), in: "web")
        #expect(host.calls == [["exec", "web", "mv", "-nT", "--", source, "/data/destination"]])
    }
    // Both an image without -T and a directory appearing after preflight must surface
    // utility failures; no retry may use mv's move-into-directory semantics.
    for error in ["mv: invalid option -- T", "mv: destination is a directory"] {
        host.calls = []
        host.result = CommandResult(stdout: "", stderr: error, exitCode: 1)
        #expect(throws: ContainerCLIError.self) {
            try cli.performFileCommand(.move(source: "/data/report", destination: "/data/destination"), in: "web")
        }
        #expect(host.calls.count == 1)
        #expect(host.arguments.contains("-nT"))
    }
}

@Test func filesSearchPreservesNewlineBoundaries() throws {
    let host = FilesHost()
    host.result = CommandResult(stdout: "/data/report\nold\0/data/report\0", stderr: "", exitCode: 0)
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    let result = try cli.searchFiles("web", directory: "/data", term: "report")
    #expect(result.paths == ["/data/report\nold", "/data/report"])
    #expect(host.arguments.last == "-print0")
}

@Test func filesMoveConfirmationRejectsSkippedMissingAndNestedOutcomes() throws {
    func listing(_ name: String, directory: Bool = false) throws -> [FileEntry] {
        try FileEntry.listing("\(directory ? "drwxr-xr-x" : "-rw-r--r--") 1 0 0 12 Jul 15 2025 \(name)",
                              pathsOutput: "/data/\(name)\0", directory: "/data")
    }
    let source = try #require(try listing("report").first)
    let destination = try listing("renamed")
    try source.verifyMove(to: "/data/renamed", sourceEntries: [], destinationEntries: destination)
    // mv -n can return zero when it skips a newly appeared destination.
    #expect(throws: ContainerCLIError.self) {
        try source.verifyMove(to: "/data/renamed", sourceEntries: [source], destinationEntries: destination)
    }
    #expect(throws: ContainerCLIError.self) {
        try source.verifyMove(to: "/data/renamed", sourceEntries: [], destinationEntries: [])
    }
    // The old mv -n outcome: source vanished into renamed/report, while renamed is a folder.
    let racedDirectory = try listing("renamed", directory: true)
    #expect(throws: ContainerCLIError.self) {
        try source.verifyMove(to: "/data/renamed", sourceEntries: [], destinationEntries: racedDirectory)
    }
}

@Test func filesCanonicalEquivalentNamesHaveByteExactIdentities() throws {
    let composed = "/data/\u{E9}"
    let decomposed = "/data/e\u{301}"
    #expect(composed == decomposed) // String equality is intentionally insufficient here.
    let entries = try FileEntry.listing("""
    -rw-r--r-- 1 0 0 12 Jul 15 2025 \u{E9}
    drwxr-xr-x 2 0 0 24 Jul 15 2025 e\u{301}
    """, pathsOutput: composed + "\0" + decomposed + "\0", directory: "/data")
    #expect(entries.map(\.id) == [Array(composed.utf8), Array(decomposed.utf8)])
    #expect(Set(entries.map(\.id)).count == 2)
    #expect(Set(entries).count == 2)
    // Metadata must use the same byte identity as selection, caches, and action resolution.
    #expect(entries[0].kind == .file)
    #expect(entries[0].sizeBytes == 12)
    #expect(entries[1].kind == .directory)
    #expect(entries[1].sizeBytes == 24)
    var cache: [FileEntry.ID: FileEntry] = [:]
    for entry in entries { cache[entry.id] = entry; try entry.requireMutable() }
    for entry in entries {
        let selection: Set<FileEntry.ID> = [entry.id]
        let selected = entries.filter { selection.contains($0.id) }
        #expect(selected.count == 1)
        #expect(selected.first?.id == entry.id)
        #expect(cache[entry.id]?.id == entry.id)
        let argv = try FileCommand.delete(path: try #require(selected.first).path, directory: entry.isDirectory)
            .arguments(containerID: "web")
        #expect(Array(try #require(argv.last).utf8) == entry.id)
    }
}

@Test func filesMoveConfirmationComparesSourceAndDestinationBytes() throws {
    func listing(_ name: String) throws -> [FileEntry] {
        try FileEntry.listing("-rw-r--r-- 1 0 0 12 Jul 15 2025 \(name)",
                              pathsOutput: "/data/\(name)\0", directory: "/data")
    }
    let source = try #require(try listing("report").first)
    let composed = try listing("\u{E9}")
    let decomposed = try listing("e\u{301}")
    #expect(throws: ContainerCLIError.self) {
        try source.verifyMove(to: "/data/\u{E9}", sourceEntries: [], destinationEntries: decomposed)
    }
    try source.verifyMove(to: "/data/\u{E9}", sourceEntries: [], destinationEntries: composed)
    // Renaming between canonical equivalents succeeds only when the source bytes disappear.
    let renamed = try #require(composed.first)
    try renamed.verifyMove(to: "/data/e\u{301}", sourceEntries: decomposed, destinationEntries: decomposed)
    #expect(throws: ContainerCLIError.self) {
        try renamed.verifyMove(to: "/data/e\u{301}", sourceEntries: composed + decomposed, destinationEntries: decomposed)
    }
}

@Test func filesLeadingCombiningMarkUsesBytePrefixBoundaries() throws {
    let name = "\u{301}notes"
    for directory in ["/", "/data", "/\u{E9}", "/e\u{301}"] {
        let path = FileCommand.child(name, in: directory)
        let entries = try FileEntry.listing("-rw-r--r-- 1 0 0 12 Jul 15 2025 \(name)",
                                            pathsOutput: path + "\0", directory: directory)
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.id == Array(path.utf8))
        #expect(Array(entry.name.utf8) == Array(name.utf8))
        try entry.requireMutable()
        let argv = try FileCommand.delete(path: entry.path, directory: false).arguments(containerID: "web")
        #expect(Array(try #require(argv.last).utf8) == entry.id)
    }
    #expect(throws: ContainerCLIError.self) {
        try FileEntry.listing("", pathsOutput: "/e\u{301}/notes\0", directory: "/\u{E9}")
    }
    #expect(!FileCommand.isValidName("a/\u{301}b"))
    #expect(throws: ContainerCLIError.self) {
        try FileEntry.listing("", pathsOutput: "/data/a/\u{301}b\0", directory: "/data")
    }
}


@Test func filesCLIPreservesBytePrefixesAndLeadingCombiningMarks() throws {
    let host = FilesHost()
    let cli = ContainerCLI(host: host, execPolicy: .interactiveShell, wirePolicy: .localOwner)
    let directory = "/\u{301}folder"
    _ = try cli.listDirectory("web", path: directory)
    #expect(host.arguments.contains { Array($0.utf8) == Array(directory.utf8) })
    host.result = CommandResult(stdout: "/\u{E9}/\u{301}notes\0/e\u{301}/other\0", stderr: "", exitCode: 0)
    let result = try cli.searchFiles("web", directory: "/\u{E9}", term: "notes")
    #expect(result.paths.map { Array($0.utf8) } == [Array("/\u{E9}/\u{301}notes".utf8)])
    host.result = CommandResult(stdout: "/\u{301}notes\0", stderr: "", exitCode: 0)
    let rootResult = try cli.searchFiles("web", directory: "/", term: "notes")
    #expect(rootResult.paths.map { Array($0.utf8) } == [Array("/\u{301}notes".utf8)])
}

/// Kyle, 18 October: raw bytes FF CC 81 decode to U+FFFD + U+0301, one grapheme that a Character
/// test does not see as "\u{FFFD}", so the name passed as mutable and its commands named a valid
/// sibling spelled the same way. Any replacement scalar, combined or not, makes a name read-only.
@Test func filesReplacementScalarWithCombiningMarkIsReadOnly() throws {
    let entries = try FileEntry.listing("", pathsOutput: "/data/\u{FFFD}\u{301}\0/data/ok\0", directory: "/data")
    let odd = try #require(entries.first { $0.name.unicodeScalars.first == "\u{FFFD}" })
    #expect(odd.mutationRestriction?.contains("Read-only") == true)
    #expect(throws: ContainerCLIError.self) { try odd.requireMutable() }
    let ok = try #require(entries.first { $0.name == "ok" })
    try ok.requireMutable()
}
