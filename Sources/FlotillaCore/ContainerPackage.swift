import Foundation

// Installing Apple's `container` (DECISIONS Q39). Everything here is pure, so the rules the DNS
// helper applies as root are tested against what `pkgutil` really prints — captured in Fixtures.

/// The runtime this Flotilla build is made and tested with, and where Apple publishes it.
public enum ContainerRuntime {
    /// The version this build expects. Bumped with the build, never fetched: "latest" would let a
    /// release Flotilla has never run against arrive on every host.
    public static let expectedVersion = "1.5.0"
    public static let packageIdentifier = "com.apple.container-installer"
    /// The only signer a package may carry (pkgutil's own wording).
    public static let appleInstallerSigner = "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)"
    public static let installLocation = "/usr/local"
    /// Larger than Apple's package (118 MB for 1.5.0) by a wide margin; anything bigger is refused.
    public static let maxPackageBytes: Int64 = 1 << 30

    /// A version fit for a URL and a comparison: dotted numbers only.
    public static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    public static func packageFilename(version: String) -> String { "container-\(version)-installer-signed.pkg" }

    /// Apple's signed installer on apple/container's GitHub releases.
    public static func packageURL(version: String) -> URL? {
        guard isVersion(version) else { return nil }
        return URL(string: "https://github.com/apple/container/releases/download/\(version)/\(packageFilename(version: version))")
    }
}

/// What `pkgutil --check-signature` says about a package.
public struct PackageSignatureReport: Sendable, Equatable {
    /// "signed by a developer certificate issued by Apple for distribution".
    public var signedForDistribution: Bool
    /// "Notarization: trusted by the Apple notary service".
    public var notarized: Bool
    /// The first certificate in the chain — who signed it.
    public var signer: String?

    public static func parse(_ text: String) -> PackageSignatureReport {
        var report = PackageSignatureReport(signedForDistribution: false, notarized: false, signer: nil)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Status: signed by a developer certificate issued by Apple for distribution" {
                report.signedForDistribution = true
            } else if line == "Notarization: trusted by the Apple notary service" {
                report.notarized = true
            } else if report.signer == nil, line.hasPrefix("1. ") {
                report.signer = String(line.dropFirst(3))
            }
        }
        return report
    }
}

/// The parts of a component package's `PackageInfo` the checks read.
public struct ComponentPackageInfo: Sendable, Equatable {
    public var identifier: String
    public var version: String
    public var installLocation: String

    /// From the `<pkg-info …>` element's attributes; `nil` if any is missing.
    public static func parse(_ xml: String) -> ComponentPackageInfo? {
        guard let start = xml.range(of: "<pkg-info"), let end = xml[start.upperBound...].firstIndex(of: ">") else { return nil }
        let element = String(xml[start.upperBound..<end])
        func attribute(_ name: String) -> String? {
            guard let range = element.range(of: " \(name)=\"") else { return nil }
            let rest = element[range.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<close])
        }
        guard let identifier = attribute("identifier"), let version = attribute("version"),
              let location = attribute("install-location") else { return nil }
        return ComponentPackageInfo(identifier: identifier, version: version, installLocation: location)
    }
}

public enum ContainerPackageCheck {
    /// The installed version, from `pkgutil --pkg-info com.apple.container-installer`.
    public static func receiptVersion(_ text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) where raw.hasPrefix("version: ") {
            let version = String(raw.dropFirst("version: ".count)).trimmingCharacters(in: .whitespaces)
            return version.isEmpty ? nil : version
        }
        return nil
    }

    /// Why this package must not be installed, or `nil` — what the helper checks as root before it
    /// runs `installer`. Genuine Apple `container`, exactly the version asked for, never older than
    /// what is installed.
    public static func problem(signature: PackageSignatureReport, info: ComponentPackageInfo?,
                               requestedVersion: String, installedVersion: String?) -> String? {
        guard signature.signedForDistribution, signature.signer == ContainerRuntime.appleInstallerSigner else {
            return "That package isn't Apple's container installer — it isn't signed by Apple's Containerization team."
        }
        guard signature.notarized else { return "That package isn't notarised by Apple." }
        guard let info, info.identifier == ContainerRuntime.packageIdentifier,
              info.installLocation == ContainerRuntime.installLocation else {
            return "That package isn't the container installer."
        }
        guard info.version == requestedVersion else {
            return "That package is container \(info.version), not \(requestedVersion)."
        }
        if let installedVersion, let installed = SoftwareVersion(installedVersion), let wanted = SoftwareVersion(requestedVersion),
           wanted < installed {
            return "This Mac has container \(installedVersion), newer than \(requestedVersion); it isn't downgraded."
        }
        return nil
    }
}

/// What a Mac should do about its runtime (Q39).
public enum RuntimeSetup: Sendable, Equatable {
    case nothing
    case install
    /// Behind the expected version. `automatic` only when nothing is running — an upgrade restarts
    /// the runtime, which stops every container.
    case upgrade(automatic: Bool)
    /// Newer than this Flotilla expects: left alone.
    case newer

    public static func plan(installed: String?, expected: String = ContainerRuntime.expectedVersion,
                            runningContainers: Int) -> RuntimeSetup {
        guard let installed else { return .install }
        guard let have = SoftwareVersion(installed), let want = SoftwareVersion(expected) else { return .nothing }
        if have == want { return .nothing }
        if have > want { return .newer }
        return .upgrade(automatic: runningContainers == 0)
    }
}
