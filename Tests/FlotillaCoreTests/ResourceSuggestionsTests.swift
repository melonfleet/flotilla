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
        }
    }

    @Test("a suggested name moves past what exists")
    func names() {
        #expect(ResourceSuggestions.uniqueName("app", taken: []) == "app")
        #expect(ResourceSuggestions.uniqueName("app", taken: ["app", "app-2"]) == "app-3")
    }
}
