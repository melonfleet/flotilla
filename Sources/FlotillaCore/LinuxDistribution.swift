import Foundation

/// Known Linux distributions a machine image may come from, matched by normalised image
/// repository (`SuggestionLibrary.imageRepository`).
public enum LinuxDistribution: String, CaseIterable, Sendable, Equatable, Identifiable {
    case alpine
    case almalinux
    case debian
    case ubuntu
    case fedora
    case rocky
    case centos
    case rhel
    case oracle
    case amazon
    case opensuse
    case suse
    case arch
    case gentoo
    case void
    case nixos
    case kali
    case wolfi
    case mint

    /// The library artwork id used when a machine's image does not match a known distribution.
    public static let fallbackArtworkID = "distro.fallback"

    public var id: String { "distro.\(rawValue)" }

    public var displayName: String {
        switch self {
        case .alpine: "Alpine Linux"
        case .almalinux: "AlmaLinux"
        case .debian: "Debian"
        case .ubuntu: "Ubuntu"
        case .fedora: "Fedora"
        case .rocky: "Rocky Linux"
        case .centos: "CentOS Stream"
        case .rhel: "RHEL UBI"
        case .oracle: "Oracle Linux"
        case .amazon: "Amazon Linux"
        case .opensuse: "openSUSE"
        case .suse: "SUSE"
        case .arch: "Arch Linux"
        case .gentoo: "Gentoo"
        case .void: "Void Linux"
        case .nixos: "NixOS"
        case .kali: "Kali Linux"
        case .wolfi: "Wolfi"
        case .mint: "Linux Mint"
        }
    }

    /// Normalised repository patterns that identify this distribution. A trailing `/*` matches any
    /// repository under that namespace; a trailing `*` on a path segment (such as `.../ubi*`)
    /// matches that prefix.
    public var repositories: [String] {
        switch self {
        case .alpine:
            ["docker.io/library/alpine"]
        case .almalinux:
            ["docker.io/library/almalinux", "docker.io/almalinux/*", "quay.io/almalinuxorg/*"]
        case .debian:
            ["docker.io/library/debian"]
        case .ubuntu:
            ["docker.io/library/ubuntu", "public.ecr.aws/ubuntu/ubuntu"]
        case .fedora:
            [
                "docker.io/library/fedora",
                "registry.fedoraproject.org/fedora",
                "registry.fedoraproject.org/fedora-minimal",
                "registry.fedoraproject.org/fedora-toolbox",
                "quay.io/fedora/*",
            ]
        case .rocky:
            ["docker.io/library/rockylinux", "docker.io/rockylinux/*", "quay.io/rockylinux/*"]
        case .centos:
            ["quay.io/centos/centos", "docker.io/library/centos"]
        case .rhel:
            ["docker.io/redhat/ubi*", "registry.access.redhat.com/ubi*"]
        case .oracle:
            ["docker.io/library/oraclelinux", "container-registry.oracle.com/os/oraclelinux"]
        case .amazon:
            ["docker.io/library/amazonlinux", "public.ecr.aws/amazonlinux/amazonlinux"]
        case .opensuse:
            ["docker.io/opensuse/*", "registry.opensuse.org/opensuse/*"]
        case .suse:
            ["registry.suse.com/suse/*", "registry.suse.com/bci/*"]
        case .arch:
            ["docker.io/library/archlinux", "docker.io/archlinux/*", "ghcr.io/archlinux/*"]
        case .gentoo:
            ["docker.io/gentoo/*"]
        case .void:
            ["docker.io/voidlinux/*", "ghcr.io/void-linux/*"]
        case .nixos:
            ["docker.io/nixos/*"]
        case .kali:
            ["docker.io/kalilinux/*"]
        case .wolfi:
            ["cgr.dev/chainguard/wolfi-base"]
        case .mint:
            ["docker.io/linuxmintd/*"]
        }
    }

    public init?(imageReference: String) {
        let repository = SuggestionLibrary.imageRepository(imageReference)
        guard !repository.isEmpty,
              let match = Self.allCases.first(where: { $0.matches(normalisedRepository: repository) })
        else { return nil }
        self = match
    }

    public static func matching(_ imageReference: String) -> LinuxDistribution? {
        LinuxDistribution(imageReference: imageReference)
    }

    public func matches(_ imageReference: String) -> Bool {
        let repository = SuggestionLibrary.imageRepository(imageReference)
        guard !repository.isEmpty else { return false }
        return matches(normalisedRepository: repository)
    }

    private func matches(normalisedRepository repository: String) -> Bool {
        repositories.contains { pattern in
            if pattern.hasSuffix("/*") {
                let prefix = pattern.dropLast()
                return repository.hasPrefix(prefix) && repository.count > prefix.count
            }
            if pattern.hasSuffix("*") {
                let prefix = pattern.dropLast()
                return repository.hasPrefix(prefix)
            }
            return repository == pattern
        }
    }
}

extension ContainerMachine {
    /// The Linux distribution this machine's image comes from, when `image` has been populated and
    /// matches a known distribution.
    public var distribution: LinuxDistribution? {
        image.flatMap { LinuxDistribution(imageReference: $0.reference) }
    }
}
