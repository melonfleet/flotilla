import Foundation
import Testing
@testable import FlotillaCore

@Suite("Resource suggestions")
struct ResourceSuggestionsTests {

    private func accepted(_ args: [String]) -> Bool {
        if case .success = Allowlist.validate(args) { true } else { false }
    }

    @Test("every volume suggestion's command is accepted")
    func volumes() {
        #expect(VolumeSuggestion.catalogue.map(\.id) == ["postgres", "mysql", "mongo"])
        for suggestion in VolumeSuggestion.catalogue {
            let args = ContainerCLI.createVolumeArguments(
                suggestion.baseName, options: .init(size: suggestion.size))
            #expect(accepted(args), "\(args)")
        }
    }

    @Test("every network suggestion's command is accepted; only the backend is host-only")
    func networks() {
        #expect(NetworkSuggestion.catalogue.filter(\.hostOnly).map(\.id) == ["backend"])
        for suggestion in NetworkSuggestion.catalogue {
            let args = ContainerCLI.createNetworkArguments(
                suggestion.baseName, options: .init(isInternal: suggestion.hostOnly))
            #expect(accepted(args), "\(args)")
        }
    }

    @Test("every cluster suggestion's command is accepted, node image pinned by tag and digest")
    func clusters() {
        for suggestion in ClusterSuggestion.catalogue {
            #expect(suggestion.nodeImage.contains(":v1.35.5@sha256:"))
            let args = ContainerCLI.createClusterArguments(
                name: suggestion.baseName, cpus: suggestion.cpus, memory: suggestion.memory,
                nodeImage: suggestion.nodeImage, scheme: .default, autoRemove: suggestion.disposable)
            #expect(accepted(args), "\(args)")
        }
        #expect(ClusterSuggestion.catalogue.first { $0.id == "disposable" }?.details
                    .contains { $0 == ("When stopped", "removed") } == true)
        #expect(ClusterSuggestion.catalogue[0].details[1].1 == "1.35.5")
    }

    @Test("every machine suggestion's command is accepted, and no stock Ubuntu or Debian")
    func machines() {
        #expect(MachineSuggestion.catalogue.map(\.id) == ["alpine", "alma9", "alma10"])
        for suggestion in MachineSuggestion.catalogue {
            #expect(!suggestion.image.contains("ubuntu") && !suggestion.image.contains("debian"))
            #expect(!suggestion.image.hasSuffix(":latest"))
            let args = ContainerCLI.createMachineArguments(
                image: suggestion.image, name: suggestion.baseName, cpus: suggestion.cpus,
                memory: "\(suggestion.memoryGB)G")
            #expect(accepted(args), "\(args)")
            #expect(MachineSuggestion.isTested(suggestion.image), "\(suggestion.image)")
        }
    }

    @Test("only a reference that was booted and logged in to is tested; nothing else is refused")
    func testedMachineImages() {
        #expect(MachineSuggestion.testedImages == ["alpine:3.22", "almalinux/9-init:9.8-20261002",
                                                   "almalinux/10-init:10.2-20261002"])
        for same in ["alpine:3.22", "docker.io/library/alpine:3.22", "docker.io/alpine:3.22",
                     "index.docker.io/library/alpine:3.22", "docker.io/almalinux/9-init:9.8-20261002",
                     "almalinux/10-init:10.2-20261002"] {
            #expect(MachineSuggestion.isTested(same), "\(same)")
        }
        for other in ["alpine", "alpine:latest", "alpine:3.21", "alpine:3.22.6", "alpine:3",
                      "alpine:3.22@sha256:abc", "alpine@sha256:abc", "alpine:", "ALPINE:3.22",
                      "ghcr.io/someone/alpine:3.22", "almalinux/9-init:latest",
                      "almalinux/9-init:9.8-20260901", "almalinux/9-init", "almalinux:9", ""] {
            #expect(!MachineSuggestion.isTested(other), "\(other)")
        }
        // Untested is a mark, not a refusal: the create command still validates.
        for untested in ["alpine:latest", "alpine:3.21", "ubuntu:24.04"] {
            #expect(accepted(ContainerCLI.createMachineArguments(image: untested, name: "box",
                                                                 cpus: 2, memory: "2G")), "\(untested)")
        }
    }

    @Test("every DNS suggestion is a domain the admin path accepts, and none is .local")
    func dns() throws {
        #expect(DNSSuggestion.catalogue.map(\.baseName) == ["test", "internal", "host.container.internal"])
        for suggestion in DNSSuggestion.catalogue {
            #expect(LocalDNS.reservedProblem(suggestion.baseName) == nil)
            let command = try ContainerCLI.dnsCreateCommand(domain: suggestion.baseName,
                                                            localhost: suggestion.hostAddress).get()
            #expect(command.arguments.last == suggestion.baseName)
            #expect(suggestion.details.count == 3)   // every card the same shape
        }
    }

    @Test("a suggested name moves past what exists")
    func names() {
        #expect(ResourceSuggestions.uniqueName("app", taken: []) == "app")
        #expect(ResourceSuggestions.uniqueName("app", taken: ["app", "app-2"]) == "app-3")
    }
}
