import Foundation
import Testing
@testable import FlotillaCore

/// The registry that lets a quit end every live `--follow` child.
///
/// Written after measuring the failure it prevents: with the Logs section streaming five
/// sources, a clean quit left all five `container logs --follow` processes alive and reparented
/// to launchd, because `onDisappear` does not fire on termination.
@Suite("Live stream registry")
struct LiveStreamRegistryTests {

    @Test("cancelAll cancels every registered stream and empties the registry")
    func cancelAllCancels() {
        let registry = LiveStreamRegistry()
        let streams = [CommandStream.finished(), CommandStream.finished(), CommandStream.finished()]
        for stream in streams { registry.register(stream) }
        #expect(registry.count == 3)

        registry.cancelAll()
        #expect(registry.count == 0)
        // Cancelling an already-finished stream is a no-op, which is the point: the registry
        // must be safe to fire at whatever is left without knowing which have already ended.
        registry.cancelAll()
        #expect(registry.count == 0)
    }

    /// The leak one level up from the process leak: a registry that only ever grows holds a
    /// `CommandStream` per log tab visit for the life of the app.
    @Test("a removed stream is no longer held")
    func removeDrops() {
        let registry = LiveStreamRegistry()
        let token = registry.register(CommandStream.finished())
        registry.register(CommandStream.finished())
        #expect(registry.count == 2)

        registry.remove(token)
        #expect(registry.count == 1)
        // Removing twice is harmless — `PendingStream.cancel` can be reached from both the
        // owner cancelling and the stream ending by itself.
        registry.remove(token)
        #expect(registry.count == 1)
    }

    @Test("registration tokens are distinct so one removal cannot drop another stream")
    func tokensAreDistinct() {
        let registry = LiveStreamRegistry()
        let tokens = (0..<20).map { _ in registry.register(CommandStream.finished()) }
        #expect(Set(tokens).count == 20)
        #expect(registry.count == 20)
    }
}
