import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

/// A finished Run's Stop in the Tasks drawer, through the model's real `perform` (Kyle, 20 October,
/// round 2). The drawer finds the container in a list up to one poll old; the stop has to read it
/// again on the host and act only on the container that run made.
@Suite @MainActor struct RunStopTests {
    /// The captured 1.5.0 `inspect` payload. `ls --all` has the same shape, so it answers both.
    private static func captured() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../FlotillaCoreTests/Fixtures/container-1.5.0/inspect-container.json")
        return try String(contentsOf: url, encoding: .utf8)
    }
    private static let ran = "2026-10-05T11:52:04Z"

    private final class Host: ContainerHost, @unchecked Sendable {
        private let lock = NSLock()
        private var payload: String
        private var recorded: [[String]] = []
        init(_ payload: String) { self.payload = payload }
        func replace(with payload: String) { lock.withLock { self.payload = payload } }
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ args: [String]) throws -> CommandResult {
            let payload = lock.withLock { recorded.append(args); return self.payload }
            switch args.first {
            case "ls", "inspect": return CommandResult(stdout: payload, stderr: "", exitCode: 0)
            default: return CommandResult(stdout: "", stderr: "", exitCode: 0)
            }
        }
    }

    /// The model, its host, and a finished Run task that made `fx-k8s` at `ran`, listed as running.
    private func setUp() async throws -> (AppModel, Host, TaskBoard.TaskContainer, Container) {
        let host = Host(try Self.captured())
        let model = AppModel(cli: ContainerCLI(host: host, wirePolicy: .localOwner), settingsStore: SettingsStore())
        await model.refresh()
        let made = TaskBoard.TaskContainer(id: "fx-k8s", host: .local, createdAt: Self.ran)
        let listed = try #require(model.container(made))

        let progress = OperationProgress(title: "Run fx-k8s", command: "container run", kind: .runContainer)
        model.tasks.start(progress)
        progress.container = made
        progress.succeed("fx-k8s started")
        #expect(model.tasks.board.rows(at: Date()).first?.stopTarget { _ in true } == made)
        return (model, host, made, listed)
    }

    @Test func theStopStopsTheContainerTheRunMade() async throws {
        let (model, host, made, listed) = try await setUp()
        let before = host.calls.count
        await model.perform(.stop, on: listed, host: .local, made: made)
        let issued = host.calls.dropFirst(before).map { Array($0.prefix(2)) }
        // Read again on the host, then stopped, then the list refreshed.
        #expect(issued.prefix(2) == [["inspect", "fx-k8s"], ["stop", "fx-k8s"]])
        #expect(model.actionError == nil)
        #expect(model.tasks.board.rows(at: Date()).first?.stopWithdrawn == nil)
    }

    @Test func aContainerReplacedSinceThePollIsNotStoppedAndTheStopSaysWhy() async throws {
        let (model, host, made, listed) = try await setUp()
        // Deleted and run again under the same name before the next poll: the drawer's list
        // still holds the old one, so the button is still there.
        host.replace(with: try Self.captured().replacingOccurrences(of: Self.ran, with: "2026-10-20T09:00:00Z"))
        #expect(model.container(made) != nil)

        await model.perform(.stop, on: listed, host: .local, made: made)
        #expect(!host.calls.contains { $0.first == "stop" })
        #expect(model.actionError == nil)
        let row = try #require(model.tasks.board.rows(at: Date()).first)
        #expect(row.stopTarget { _ in true } == nil)
        #expect(row.step == TaskBoard.StopWithdrawn.replaced("fx-k8s").reason)
    }
}
