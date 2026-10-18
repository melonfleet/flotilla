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
        let specs = SuggestionPorts.publishSpecs(for: entry, avoiding: [3000])
        #expect(specs == ["127.0.0.1:3001:3000"])
    }

    @Test func preferredWebHostPortMatchesStackDefaults() {
        #expect(SuggestionPorts.preferredWebHostPort(80) == 8080)
        #expect(SuggestionPorts.preferredWebHostPort(3000) == 3000)
        #expect(SuggestionPorts.preferredHostPorts(for: stack(id: "g", title: "G", webPort: 80)) == [8080])
    }
}
