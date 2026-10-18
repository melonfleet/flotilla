import Foundation
import Testing
@testable import FlotillaCore

@Suite struct LinuxDistributionTests {
    @Test func everyDistributionHasDistinctIDAndDisplayName() {
        #expect(LinuxDistribution.allCases.count == 19)
        #expect(Set(LinuxDistribution.allCases.map(\.id)).count == LinuxDistribution.allCases.count)
        #expect(Set(LinuxDistribution.allCases.map(\.displayName)).count == LinuxDistribution.allCases.count)
        for distro in LinuxDistribution.allCases {
            #expect(distro.id.hasPrefix("distro."))
            #expect(!distro.displayName.isEmpty)
            #expect(!distro.repositories.isEmpty)
        }
    }

    @Test(arguments: [
        ("alpine:3.22", LinuxDistribution.alpine),
        ("docker.io/library/alpine:3.22", .alpine),
        ("DOCKER.IO/library/alpine@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8", .alpine),
        ("almalinux:9", .almalinux),
        ("almalinux/9-init:9.8-20261002", .almalinux),
        ("docker.io/almalinux/10-init:10.2-20261002", .almalinux),
        ("debian:13", .debian),
        ("docker.io/library/debian:bookworm-slim", .debian),
        ("ubuntu:24.04", .ubuntu),
        ("docker.io/ubuntu:noble@sha256:abc", .ubuntu),
        ("fedora:41", .fedora),
        ("registry.fedoraproject.org/fedora:41", .fedora),
        ("rockylinux:9", .rocky),
        ("rockylinux/rockylinux:9-ubi-init", .rocky),
        ("quay.io/rockylinux/rockylinux:9", .rocky),
        ("quay.io/centos/centos:stream9", .centos),
        ("QUAY.IO/centos/centos:stream10@sha256:def", .centos),
        ("redhat/ubi9:9.4", .rhel),
        ("redhat/ubi8-init:8.10", .rhel),
        ("registry.access.redhat.com/ubi9/ubi:latest", .rhel),
        ("registry.access.redhat.com/ubi9-init:9.4", .rhel),
        ("oraclelinux:9", .oracle),
        ("container-registry.oracle.com/os/oraclelinux:9-slim", .oracle),
        ("amazonlinux:2023", .amazon),
        ("public.ecr.aws/amazonlinux/amazonlinux:2023", .amazon),
        ("opensuse/leap:15.6", .opensuse),
        ("opensuse/tumbleweed:latest", .opensuse),
        ("registry.opensuse.org/opensuse/tumbleweed:latest", .opensuse),
        ("registry.suse.com/suse/sle15:15.6", .suse),
        ("archlinux:latest", .arch),
        ("docker.io/library/archlinux:base-devel", .arch),
        ("gentoo/stage3:latest", .gentoo),
        ("voidlinux/voidlinux:latest", .void),
        ("ghcr.io/void-linux/void-glibc:latest", .void),
        ("nixos/nix:2.24.0", .nixos),
        ("kalilinux/kali-rolling:latest", .kali),
        ("cgr.dev/chainguard/wolfi-base:latest", .wolfi),
        ("CGR.DEV/chainguard/wolfi-base@sha256:123", .wolfi),
        ("linuxmintd/mint22-amd64:latest", .mint),
    ])
    func knownRepositoriesMatchAcrossTagsDigestsAndDockerHubForms(reference: String, expected: LinuxDistribution) {
        let matched = LinuxDistribution(imageReference: reference)
        #expect(matched == expected)
        #expect(expected.matches(reference))
    }

    @Test(arguments: [
        "",
        "alpine-foo:latest",
        "docker.io/library/alpine-foo:3.22",
        "my-alpine:3.22",
        "almalinux-foo/9-init:latest",
        "debian-slim:bookworm",
        "ubuntu-debootstrap:24.04",
        "fedora-minimal:41",
        "rockylinux-extra/base:9",
        "quay.io/centos/centos-stream:9",
        "redhat/ubuntu:latest",
        "registry.access.redhat.com/openshift/ose:v4",
        "oraclelinux-slim:9",
        "amazonlinux-2:latest",
        "opensuse-leap/leap:15.6",
        "registry.suse.com/rancher/rancher:latest",
        "archlinux-base:latest",
        "gentoo-stage3:latest",
        "voidlinux:latest",
        "nixos:latest",
        "kalilinux:latest",
        "cgr.dev/chainguard/wolfi-base-dev:latest",
        "cgr.dev/chainguard/static:latest",
        "linuxmint:22",
        "postgres:17",
    ])
    func unknownAndNearMissRepositoriesReturnNil(reference: String) {
        #expect(LinuxDistribution(imageReference: reference) == nil)
    }

    @Test func capturedMachineInspectFixtureMatchesAlpine() throws {
        let url = try #require(
            Bundle.module.url(forResource: "machine-inspect", withExtension: "json", subdirectory: "Fixtures")
        )
        let inspected = try JSONDecoder().decode([ContainerMachine].self, from: Data(contentsOf: url))
        let machine = try #require(inspected.first)
        #expect(machine.image?.reference == "docker.io/library/alpine:3.22")
        #expect(machine.distribution == .alpine)
        #expect(machine.distribution?.id == "distro.alpine")
    }
}
