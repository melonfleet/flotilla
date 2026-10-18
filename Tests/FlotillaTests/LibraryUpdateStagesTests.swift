import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

@Suite @MainActor struct LibraryUpdateStagesTests {
    private func makeUpdater(fetch: @escaping (String, Int) async throws -> Data)
        -> (LibraryUpdater, UpdateActivityCenter, () -> [UpdateStage]) {
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let center = UpdateActivityCenter()
        var seen: [UpdateStage] = []
        center.observer = { _, stage in seen.append(stage) }
        let updater = LibraryUpdater(activity: center, defaults: UserDefaults(suiteName: suite)!)
        updater.fetchOverride = fetch
        return (updater, center, { seen })
    }

    @Test func aLibraryThatFailsItsSignatureReportsEachStepThenTheFailure() async {
        let (updater, center, seen) = makeUpdater { name, _ in Data("not from us \(name)".utf8) }
        let result = await updater.check(current: .builtIn)
        #expect(result == nil)
        #expect(seen() == [
            .checking, .downloading(nil), .verifying,
            .failed("Couldn't check: The library's signature didn't verify, so it wasn't used."),
        ])
        #expect(!updater.checking)
        #expect(center.activity.headline?.stage.isFailure == true)
        #expect(updater.status.hasPrefix("Couldn't check:"))
    }

    @Test func aFetchThatFailsStopsAtDownloading() async {
        let (updater, _, seen) = makeUpdater { name, _ in throw LibraryUpdater.Failure("GitHub didn't have \(name) (HTTP 404).") }
        _ = await updater.check(current: .builtIn)
        #expect(seen() == [.checking, .downloading(nil), .failed("Couldn't check: GitHub didn't have library.json (HTTP 404).")])
    }

    @Test func aSecondCheckWhileOneRunsReportsNothing() async {
        let (updater, _, seen) = makeUpdater { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            throw LibraryUpdater.Failure("slow")
        }
        async let first = updater.check(current: .builtIn)
        await Task.yield()
        _ = await updater.check(current: .builtIn)
        _ = await first
        #expect(seen().filter { $0 == .checking }.count == 1)
    }
}
