import Foundation

/// Fixed commands only. No shell, interpolation, package names or user-supplied command text.
enum MachineUpdateCommand: CaseIterable, Sendable {
    case apkRefresh, apkVersions, dnfCheck, rpmInstalled

    var command: [String] {
        switch self {
        case .apkRefresh: ["apk", "update"]
        case .apkVersions: ["apk", "version", "-l", "<"]
        case .dnfCheck: ["dnf", "-q", "check-update"]
        case .rpmInstalled: ["rpm", "-qa", "--queryformat", #"%{NAME}.%{ARCH}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n"#]
        }
    }

    /// Only `apk update` needs root inside the machine: it rewrites apk's package index, and
    /// `machine run` otherwise runs as the user matching the Mac's own (Kyle, 19 October). It changes
    /// nothing else; no package is installed.
    var runsAsRoot: Bool { self == .apkRefresh }

    func arguments(machine: String) -> [String] {
        ["machine", "run", "--name", machine] + (runsAsRoot ? ["--root"] : []) + ["--"] + command
    }

    static func commands(for distribution: LinuxDistribution) -> [Self]? {
        switch distribution {
        case .alpine: [.apkRefresh, .apkVersions]
        case .almalinux: [.dnfCheck, .rpmInstalled]
        default: nil
        }
    }
}

public struct MachinePackageUpdate: Sendable, Equatable {
    public let package: String
    public let installed: String
    public let available: String
}

public struct MachineUpdateReport: Sendable, Equatable {
    public let updates: [MachinePackageUpdate]
    public let checkedAt: Date
    public let distribution: LinuxDistribution
}

extension LinuxDistribution {
    public var machineUpgradeCommand: String? {
        switch self {
        case .alpine: "apk upgrade"
        case .almalinux: "dnf upgrade"
        default: nil
        }
    }
}

/// No captured package-manager output is available in this mirror (machine service access is
/// denied). This parser intentionally has no synthetic fixture tests. Capture both distributions
/// on a live host before claiming the output formats have been verified.
enum MachineUpdateParser {
    private static var invalid: ContainerCLIError {
        .unsupported("Package update output could not be read safely. Check manually in the Shell tab.")
    }

    // Fail closed rather than presenting a partial list as a complete count or 'Up to date'.
    private static func lines(_ text: String) throws -> [String] {
        guard text.utf8.count <= 2_000_000 else { throw invalid }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= 20_000 else { throw invalid }
        return try lines.map { line in
            guard line.utf8.count <= 1_024,
                  line.unicodeScalars.allSatisfy({ $0.value == 9 || (32...126).contains($0.value) })
            else { throw invalid }
            return String(line)
        }
    }

    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || Array("._+-:~^".utf8).contains($0)
        }
    }

    static func parse(distribution: LinuxDistribution, output: [MachineUpdateCommand: String],
                      checkExit: Int32) throws -> [MachinePackageUpdate] {
        var updates: [MachinePackageUpdate] = []
        switch distribution {
        case .alpine:
            for line in try lines(output[.apkVersions] ?? "") {
                let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if fields.isEmpty || line.hasPrefix("Installed:") { continue }
                guard fields.count == 3, fields[1] == "<",
                      let range = fields[0].range(of: #"-[0-9][^-]*-r[0-9]+$"#, options: .regularExpression)
                else { throw invalid }
                let package = String(fields[0][..<range.lowerBound])
                let installed = String(fields[0][fields[0].index(after: range.lowerBound)...])
                guard token(package), token(installed), token(fields[2]) else { throw invalid }
                updates.append(.init(package: package, installed: installed, available: fields[2]))
                guard updates.count <= 1_000 else { throw invalid }
            }
        case .almalinux:
            var installed: [String: [String]] = [:]
            for line in try lines(output[.rpmInstalled] ?? "") where !line.isEmpty {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 2, token(fields[0]), token(fields[1]) else { throw invalid }
                let version = fields[1].hasPrefix("0:") ? String(fields[1].dropFirst(2)) : fields[1]
                installed[fields[0], default: []].append(version)
            }
            var pending: String?
            for line in try lines(output[.dnfCheck] ?? "") {
                var fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if fields.isEmpty { continue }
                if let name = pending {
                    fields.insert(name, at: 0)
                    pending = nil
                }
                if fields.count == 1, installed[fields[0]] != nil {
                    pending = fields[0] // DNF wraps long package names onto a separate line.
                    continue
                }
                guard let versions = installed[fields[0]] else {
                    // Ignore metadata notices, but never quietly omit a package-shaped row.
                    if fields.count == 3, fields[0].contains("."),
                       fields[1].first?.isNumber == true { throw invalid }
                    continue
                }
                guard fields.count == 3, token(fields[0]), token(fields[1]) else { throw invalid }
                let current = versions.sorted().joined(separator: ", ")
                guard current.utf8.count <= 1_024 else { throw invalid }
                updates.append(.init(package: fields[0], installed: current, available: fields[1]))
                guard updates.count <= 1_000 else { throw invalid }
            }
            guard pending == nil, (checkExit == 100) == !updates.isEmpty else { throw invalid }
        default: throw invalid
        }
        return updates
    }
}
