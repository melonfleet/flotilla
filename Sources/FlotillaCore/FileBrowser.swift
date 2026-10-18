import Foundation

/// Best-effort interpretation of busybox/coreutils `ls -la`, not a stable CLI JSON schema.
/// Dates without a year use ls's recent-file convention; the guest's timezone is unknown.
/// Raw ls rows are metadata only. NUL-delimited find records supply verified identities.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case directory, file, symbolicLink, other }
    public let isNameVerified: Bool
    /// UTF-8 bytes from the NUL record; Swift String equality folds canonical equivalents.
    public let id: [UInt8]
    public let path: String
    public let name: String
    public let kind: Kind
    public let symlinkTarget: String?
    public let sizeBytes: Int64?
    public let modified: String
    public let modifiedDate: Date?
    public var mutationRestriction: String? {
        // Commands are built from `path`, so its UTF-8 must be *exactly* the bytes the guest
        // listed. A Character test missed U+FFFD followed by a combining mark (one grapheme,
        // not equal to "\u{FFFD}"), so raw bytes FF CC 81 passed and targeted a valid sibling
        // named "\u{FFFD}\u{301}" (Kyle, 18 October). Comparing bytes closes the whole class.
        guard isNameVerified, (try? FileCommand.validatePath(path)) != nil,
              !path.unicodeScalars.contains("\u{FFFD}"),
              id.isEmpty || Array(path.utf8) == id else {
            return "Read-only: this name cannot be represented unambiguously for file operations."
        }
        return nil
    }
    public func requireMutable() throws {
        if let mutationRestriction { throw ContainerCLIError.unsupported(mutationRestriction) }
    }
    public func verifyMove(to destination: String, sourceEntries: [FileEntry], destinationEntries: [FileEntry]) throws {
        guard !sourceEntries.contains(where: { $0.id == id }),
              destinationEntries.contains(where: { $0.id == Array(destination.utf8) && $0.kind == kind }) else {
            throw ContainerCLIError.unsupported("The move could not be confirmed at the exact destination. Refresh before trying again; a destination may have appeared while moving.")
        }
    }
    public var isDirectory: Bool { kind == .directory }
    public var kindLabel: String {
        switch kind {
        case .directory: "Folder"
        case .symbolicLink: "Symbolic Link"
        case .other: "Special File"
        case .file:
            (name as NSString).pathExtension.isEmpty ? "File" : "\((name as NSString).pathExtension.uppercased()) File"
        }
    }
    public var sizeLabel: String {
        guard !isDirectory, let sizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public static func parse(_ output: String, directory: String = "/", now: Date = Date(),
                             timeZone: TimeZone = .current) -> [FileEntry] {
        output.split(separator: "\n").compactMap { line in
            // Eight metadata fields, then the untouched name (which may contain spaces).
            let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true,
                                    whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == 9, let type = fields[0].first,
                  "-dlbcps".contains(type), fields[0].count >= 10 else { return nil }
            var name = fields[8]
            var target: String?
            if type == "l", let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
            guard FileCommand.isValidName(name) else { return nil }
            let stamp = fields[5...7].joined(separator: " ")
            return FileEntry(isNameVerified: false, id: Array(FileCommand.child(name, in: directory).utf8),
                             path: FileCommand.child(name, in: directory), name: name,
                             kind: type == "d" ? .directory : type == "l" ? .symbolicLink : type == "-" ? .file : .other,
                             symlinkTarget: target, sizeBytes: Int64(fields[4]), modified: stamp,
                             modifiedDate: parseDate(stamp, now: now, timeZone: timeZone))
        }
    }

    /// Only NUL-delimited find output supplies identities. ls supplies best-effort metadata,
    /// never a mutation path: newline continuations and symlink arrows cannot alias a name.
    public static func listing(_ output: String, pathsOutput: String, directory: String) throws -> [FileEntry] {
        guard pathsOutput.isEmpty || pathsOutput.utf8.last == 0 else {
            throw ContainerCLIError.unsupported("Incomplete file names; refresh before changing files.")
        }
        let metadata = Dictionary(grouping: parse(output, directory: directory), by: \.id)
        let prefix = Array((directory == "/" ? "/" : directory + "/").utf8)
        return try pathsOutput.utf8.split(separator: 0).map { rawPath in
            let bytes = Array(rawPath)
            let path = String(decoding: bytes, as: UTF8.self)
            guard bytes.starts(with: prefix) else {
                throw ContainerCLIError.unsupported("Unexpected file listing path.")
            }
            let nameBytes = bytes.dropFirst(prefix.count)
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard !name.isEmpty, !nameBytes.contains(47), name != ".", name != ".." else {
                throw ContainerCLIError.unsupported("Unexpected file listing name.")
            }
            let candidates = metadata[bytes] ?? []
            let details = candidates.count == 1 ? candidates.first : nil
            return FileEntry(isNameVerified: true, id: bytes, path: path, name: name,
                             kind: details?.kind ?? .other, symlinkTarget: details?.symlinkTarget,
                             sizeBytes: details?.sizeBytes, modified: details?.modified ?? "—",
                             modifiedDate: details?.modifiedDate)
        }
    }

    private static func parseDate(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        let recent = text.contains(":")
        let year = calendar.component(.year, from: now)
        formatter.dateFormat = recent ? "MMM d HH:mm yyyy" : "MMM d yyyy"
        guard var date = formatter.date(from: recent ? "\(text) \(year)" : text) else { return nil }
        if recent && date > now.addingTimeInterval(86_400) {
            date = calendar.date(byAdding: .year, value: -1, to: date) ?? date
        }
        return date
    }
}

public enum FileGrouping: String, CaseIterable, Sendable {
    case none = "None", name = "Name", kind = "Kind", modified = "Date Modified", created = "Date Created", size = "Size"
    case application = "Application", opened = "Date Last Opened", added = "Date Added", tags = "Tags"
    public var available: Bool { [.none, .name, .kind, .modified, .size].contains(self) }
    public func key(for entry: FileEntry, calendar: Calendar = .current) -> String {
        switch self {
        case .none: return ""
        case .name: return entry.name.first.map { String($0).uppercased() } ?? "#"
        case .kind: return entry.kindLabel
        case .modified:
            guard let date = entry.modifiedDate else { return "Unknown date" }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        case .size:
            if entry.isDirectory { return "Folders" }
            guard let bytes = entry.sizeBytes else { return "Unknown size" }
            return bytes < 1_024 ? "Under 1 KB" : bytes < 1_048_576 ? "1 KB – 1 MB" : bytes < 1_073_741_824 ? "1 MB – 1 GB" : "1 GB or more"
        case .created, .application, .opened, .added, .tags: return "Unavailable"
        }
    }
    /// Stable group order; sorting within groups belongs to the selected column.
    public func groups(_ entries: [FileEntry]) -> [(name: String, entries: [FileEntry])] {
        guard self != .none, available else { return [("", entries)] }
        let buckets = Dictionary(grouping: entries, by: { key(for: $0) })
        let sizeOrder = ["Folders", "Under 1 KB", "1 KB – 1 MB", "1 MB – 1 GB", "1 GB or more", "Unknown size"]
        let keys = buckets.keys.sorted {
            if self == .size { return (sizeOrder.firstIndex(of: $0) ?? 99) < (sizeOrder.firstIndex(of: $1) ?? 99) }
            if self == .modified { return $0 > $1 }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return keys.map { ($0, buckets[$0] ?? []) }
    }
}

/// Only argv, never shell source. Container paths are absolute and follow the utility's `--`.
/// `find` has no portable `--`; its absolute starting path cannot be an option/expression.
public enum FileCommand: Equatable, Sendable {
    case makeDirectory(parent: String, name: String)
    case move(source: String, destination: String)
    case delete(path: String, directory: Bool)
    case find(directory: String, term: String)

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(47)
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && name.utf8.count <= 255
    }
    /// Split on the slash byte even when a combining mark follows the separator.
    public static func pathComponents(_ path: String) -> [String] {
        path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }
    }
    public static func child(_ name: String, in directory: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }
    public static func validatePath(_ path: String, allowRoot: Bool = false) throws {
        let components = path.utf8.split(separator: 47)
        guard path.utf8.first == 47, path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !components.contains(where: { $0.elementsEqual([46]) || $0.elementsEqual([46, 46]) }),
              allowRoot || !components.isEmpty else {
            throw ContainerCLIError.unsupported("Choose an absolute path inside the container, without . or .. components.")
        }
    }
    public func arguments(containerID: String) throws -> [String] {
        let command: [String]
        switch self {
        case .makeDirectory(let parent, let name):
            try Self.validatePath(parent, allowRoot: true)
            guard Self.isValidName(name) else { throw ContainerCLIError.unsupported("Enter a name without /, control characters, . or ...") }
            command = ["mkdir", "--", Self.child(name, in: parent)]
        case .move(let source, let destination):
            try Self.validatePath(source)
            try Self.validatePath(destination)
            // Exact destination, never move into a directory that appears after the UI check.
            // GNU and BusyBox support -nT; unsupported images must fail, never retry without T.
            command = ["mv", "-nT", "--", source, destination]
        case .delete(let path, let directory):
            try Self.validatePath(path)
            command = ["rm"] + (directory ? ["-r"] : []) + ["--", path]
        case .find(let directory, let term):
            try Self.validatePath(directory, allowRoot: true)
            guard !term.isEmpty, term.utf8.count <= 200,
                  !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ContainerCLIError.unsupported("Enter a search of 1–200 bytes without control characters.")
            }
            // Treat the user's term literally within find's pattern language too.
            let escaped = term.reduce(into: "") { result, character in
                if "\\*?[]".contains(character) { result.append("\\") }
                result.append(character)
            }
            command = ["find", directory, "-iname", "*\(escaped)*", "-print0"]
        }
        return ["exec", containerID, "--"] + command
    }
}

public struct FileSearchResults: Sendable {
    public let paths: [String]
    public let capped: Bool
}
