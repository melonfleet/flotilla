import Foundation
import Testing
@testable import FlotillaCore

/// Pins the container state vocabulary, so a `container` release that widens it arrives as a
/// failing test rather than as silence.
///
/// Silence is precisely what went wrong before. Five places classified containers with Docker's
/// words — `exit`, `dead`, `fail`, `restart`, `(0)` — which Apple's runtime never emits, so two
/// "Needs attention" panels, a danger tint, a warning tint and an event tint were all
/// unreachable. Nothing in the app looked broken, because a panel that is absent when there is
/// no problem is indistinguishable from a panel that can never appear.
@Suite("Container state vocabulary")
struct ContainerStateTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The four cases read out of `container` 1.4.1's own `RawValue`/`AllCases` block. If a
    /// release adds a fifth, this test is where it should be noticed — add the case to
    /// `ContainerState`, decide what it means for `needsAttention` and `Theme.color(for:)`, and
    /// extend this list.
    @Test("the known vocabulary is exactly running, stopping, stopped, unknown")
    func knownVocabulary() {
        #expect(ContainerState.known.map(\.rawValue) == ["running", "stopping", "stopped", "unknown"])
        for state in ContainerState.known {
            #expect(ContainerState(state.rawValue) == state)
        }
    }

    /// Every state a captured fixture contains must be one this build knows. A fixture carrying
    /// an unrecognised state means the runtime changed and nobody noticed.
    @Test("no captured fixture reports a state outside the known set")
    func fixturesUseKnownStatesOnly() throws {
        for name in ["containers", "containers-ports"] {
            let containers = try JSONDecoder().decode([Container].self, from: fixture(name))
            for container in containers {
                let where_ = "\(name): \(container.configuration.id) reports unknown state "
                    + "'\(container.status.state)'"
                #expect(!container.state.isOther, Comment(rawValue: where_))
            }
        }
    }

    /// `exited (137)` was the example in the old comments and the justification for the danger
    /// tint. It is not a state this runtime produces — measured on 1.4.1: a container run as
    /// `sh -c 'exit 3'` ends `stopped`, so does one killed with `container kill`, and `inspect`
    /// carries no exit code at all. It parses as `other` and is deliberately **not** a problem,
    /// so a future benign state cannot light up every row.
    @Test("Docker's vocabulary parses as other and never claims attention")
    func dockerVocabularyIsNotAFailure() {
        for raw in ["exited (137)", "exited (0)", "dead", "restarting", "created", "paused"] {
            let state = ContainerState(raw)
            #expect(state == .other(raw))
            #expect(!state.needsAttention, "'\(raw)' must not be treated as a failure")
            #expect(!state.isRunning)
        }
    }

    @Test("unknown is the one state that wants a person")
    func onlyUnknownNeedsAttention() {
        #expect(ContainerState.unknown.needsAttention)
        #expect(!ContainerState.running.needsAttention)
        #expect(!ContainerState.stopping.needsAttention)
        #expect(!ContainerState.stopped.needsAttention)
    }

    /// The wire type is a free-form string, so matching on exact casing would be the same class
    /// of assumption this whole type exists to remove.
    @Test("parsing is case-insensitive and keeps the runtime's own spelling")
    func parsingIsCaseInsensitive() {
        #expect(ContainerState("RUNNING") == .running)
        #expect(ContainerState("Stopped") == .stopped)
        #expect(ContainerState("Weird Thing").rawValue == "Weird Thing")
    }
}

/// The machine vocabulary, pinned the same way and for the same reason — the sixth copy of the
/// dead failure rule lived in `MachinesView.stateColor`.
@Suite("Machine state vocabulary")
struct MachineStateTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Five cases, one more than containers: machines have `starting`, containers do not. That
    /// difference is why these are two types rather than one shared enum.
    @Test("the known vocabulary is exactly starting, running, stopping, stopped, unknown")
    func knownVocabulary() {
        #expect(MachineState.known.map(\.rawValue)
                == ["starting", "running", "stopping", "stopped", "unknown"])
        for state in MachineState.known {
            #expect(MachineState(state.rawValue) == state)
        }
    }

    @Test("no captured fixture reports a status outside the known set")
    func fixturesUseKnownStatesOnly() throws {
        let machines = try JSONDecoder().decode([ContainerMachine].self, from: fixture("machines"))
        #expect(!machines.isEmpty)
        for machine in machines {
            let where_ = "\(machine.id) reports unknown status '\(machine.status)'"
            #expect(!machine.state.isOther, Comment(rawValue: where_))
        }
    }

    /// `MachinesView.stateColor` tested for these. Nothing produces them.
    @Test("error and failed are not machine statuses and never claim attention")
    func noFailureVocabulary() {
        for raw in ["error", "failed", "fail", "errored"] {
            let state = MachineState(raw)
            #expect(state == .other(raw))
            #expect(!state.needsAttention)
            #expect(!state.isTransitional)
        }
    }

    /// The bug the dot's colour was written after: `contains("stopp")` is true of *stopped* as
    /// well as *stopping*, so a machine at rest was painted amber.
    @Test("stopped is at rest, stopping is in motion")
    func stoppedIsNotStopping() {
        #expect(!MachineState.stopped.isTransitional)
        #expect(MachineState.stopping.isTransitional)
        #expect(MachineState.starting.isTransitional)
    }
}

private extension MachineState {
    var isOther: Bool {
        if case .other = self { return true }
        return false
    }
}

private extension ContainerState {
    var isOther: Bool {
        if case .other = self { return true }
        return false
    }
}
