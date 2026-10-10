import Foundation
import Testing
@testable import FlotillaCore

@Suite struct RuntimeAutostartTests {
    let boot = Date(timeIntervalSince1970: 1_000_000)

    @Test func afterAStartUpTheServiceIsStarted() {
        // Last seen running before this start-up: stopped by the restart, so start it.
        #expect(RuntimeAutostart.shouldStart(.always, bootedAt: boot, lastSeenRunning: boot - 3600))
        // Never seen running at all: a first launch.
        #expect(RuntimeAutostart.shouldStart(.always, bootedAt: boot, lastSeenRunning: nil))
    }

    @Test func aStopMadeWhileTheMacWasUpIsLeftAlone() {
        // Seen running since this start-up, stopped now: someone stopped it, or it crashed.
        #expect(!RuntimeAutostart.shouldStart(.always, bootedAt: boot, lastSeenRunning: boot + 600))
        // And when the start-up time can't be read, a person decides.
        #expect(!RuntimeAutostart.shouldStart(.always, bootedAt: nil, lastSeenRunning: boot))
    }

    @Test func askAndNeverNeverStartIt() {
        for policy in [ServiceAutostartPolicy.ask, .never] {
            #expect(!RuntimeAutostart.shouldStart(policy, bootedAt: boot, lastSeenRunning: nil))
        }
    }
}
