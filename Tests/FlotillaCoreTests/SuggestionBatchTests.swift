import Foundation
import Testing
@testable import FlotillaCore

@Suite struct SuggestionBatchTests {
    private func container(id: String, title: String, ports: [String]) -> LibraryEntry {
        LibraryEntry(id: id, title: title, summary: "", categories: ["Networking & Web Servers"],
                     kind: .container, tested: .init(date: "2026-10-12", macs: 1),
                     container: LibraryContainer(image: "docker.io/library/nginx:1.27", name: id, ports: ports))
    }

    private func stack(id: String, title: String, webPort: Int) -> LibraryEntry {
        LibraryEntry(id: id, title: title, summary: "", categories: ["Monitoring"],
                     kind: .stack, tested: .init(date: "2026-10-12", macs: 1),
                     stack: LibraryStack(
                        services: [
                            .init(role: "web", title: title, image: "docker.io/library/nginx:1.27", webPort: webPort),
                        ],
                        opens: "web"))
    }

    @Test func batchAdvancesAndClaimsPortsOnlyWhenTold() {
        var batch = SuggestionBatch(queue: ["a", "b", "c"])
        #expect(batch.progressLabel == "1 of 3")
        #expect(batch.currentID == "a")
        batch.advance(claiming: [3000])
        #expect(batch.index == 1)
        #expect(batch.claimedPorts == [3000])
        #expect(batch.progressLabel == "2 of 3")
        batch.advance() // skip — no claim
        #expect(batch.claimedPorts == [3000])
        #expect(batch.currentID == "c")
        batch.advance(claiming: [3001])
        #expect(batch.isFinished)
        #expect(batch.claimedPorts == [3000, 3001])
    }

    @Test func clashNotesNameThePairAndThePort() {
        let grafana = container(id: "grafana", title: "Grafana", ports: ["3000:3000"])
        let metabase = container(id: "metabase", title: "Metabase", ports: ["3000:3000"])
        let notes = SuggestionPorts.clashNotes(for: [grafana, metabase])
        #expect(notes == [
            "Grafana and Metabase both want port 3000; the second will suggest a free port"
        ])
    }

    @Test func clashNotesCoverThreeAndStackWebPorts() {
        let a = stack(id: "a", title: "Grafana", webPort: 3000)
        let b = stack(id: "b", title: "Metabase", webPort: 3000)
        let c = container(id: "c", title: "App", ports: ["3000:80"])
        let notes = SuggestionPorts.clashNotes(for: [a, b, c])
        #expect(notes.count == 1)
        #expect(notes[0].contains("Grafana, Metabase and App all want port 3000"))
        #expect(notes[0].contains("the later ones will suggest a free port"))
    }

    @Test func laterContainerPrefillMovesPastAClaimedPort() {
        let entry = LibraryContainer(image: "docker.io/library/nginx:1.27", name: "app", ports: ["3000:3000"])
        let specs = SuggestionPorts.publishSpecs(for: entry, avoiding: [3000], isPortFree: { _ in true })
        #expect(specs.specs == ["127.0.0.1:3001:3000"])
        #expect(specs.unavailablePorts.isEmpty)
    }

    @Test func replacementIsProbedAndAvoidsStackAndBatchReservations() {
        let entry = LibraryContainer(image: "nginx", name: "app", ports: ["3000:80", "3000:81/udp"])
        var probed: [Int] = []
        // 3000 and 3001 are local listeners; 3002 and 3003 are stack/batch reservations.
        let result = SuggestionPorts.publishSpecs(for: entry, avoiding: [3002, 3003]) { port in
            probed.append(port)
            return ![3000, 3001].contains(port)
        }
        #expect(result.specs == ["127.0.0.1:3004:80", "127.0.0.1:3005:81/udp"])
        #expect(result.unavailablePorts.isEmpty)
        #expect(probed == [3000, 3001, 3004, 3000, 3001, 3005])
    }

    @Test func exhaustedSearchLeavesHostBlankAndReportsPreferredPort() {
        let entry = LibraryContainer(image: "nginx", name: "app", ports: ["3000:80"])
        var probed: [Int] = []
        let result = SuggestionPorts.publishSpecs(for: entry, avoiding: []) { port in
            probed.append(port)
            return false
        }
        #expect(probed == Array(3000..<3020))
        #expect(probed.count == SuggestionPorts.searchLimit)
        #expect(result.specs == ["127.0.0.1::80"])
        #expect(result.unavailablePorts == [0: 3000])
        guard case .failure = Allowlist.validate(["run", "--publish", result.specs[0], "nginx"]) else {
            Issue.record("An unavailable host port must block Run")
            return
        }
        #expect(SuggestionPorts.unavailableMessage(near: 3000) == "No free port near 3000 — choose one")
        // Stack defaults must stay within the same range that the app probes.
        #expect(StackPlanner.defaultWebPorts(for: stack(id: "s", title: "S", webPort: 3000).stackSuggestion!,
                                            avoiding: Set(3000..<3020)).isEmpty)
    }

    @Test func claimedLastPortIsUnavailableWithoutProbingOutOfRange() {
        let entry = LibraryContainer(image: "nginx", name: "app", ports: ["65535:80"])
        var batch = SuggestionBatch(queue: ["first", "last"])
        batch.advance(claiming: [65535])
        var probed: [Int] = []
        let result = SuggestionPorts.publishSpecs(for: entry, avoiding: batch.claimedPorts) { port in
            probed.append(port)
            return true
        }
        #expect(probed.isEmpty)
        #expect(result.specs == ["127.0.0.1::80"])
        #expect(result.unavailablePorts == [0: 65535])
        #expect(SuggestionPorts.unavailableMessage(near: 65535) == "No free port near 65535 — choose one")
    }

    @Test func preferredWebHostPortMatchesStackDefaults() {
        #expect(SuggestionPorts.preferredWebHostPort(80) == 8080)
        #expect(SuggestionPorts.preferredWebHostPort(3000) == 3000)
        #expect(SuggestionPorts.preferredHostPorts(for: stack(id: "g", title: "G", webPort: 80)) == [8080])
    }
}
