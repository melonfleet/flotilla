import Testing
import Foundation
import ObjectiveC
import FlotillaPrivileged

/// The helper is an executable, so what can be pinned at this level is its XPC contract — the
/// surface the app and the root daemon agree on (DECISIONS Q41, amended 19 October).
struct HelperInterfaceTests {
    private func description(_ selector: String) -> objc_method_description {
        protocol_getMethodDescription(HelperProtocol.self, NSSelectorFromString(selector), true, true)
    }

    @Test func restartIsATypedOperationThatTakesOnlyAReply() {
        let method = description("quitWithReply:")
        #expect(method.name != nil, "HelperProtocol must declare quit(reply:)")
        // One colon: the reply block is the only parameter — no argument chooses anything.
        #expect("quitWithReply:".filter { $0 == ":" }.count == 1)
        let types = method.types.map { String(cString: $0) } ?? ""
        #expect(types.filter { $0 == "@" }.count == 2, "self (@) and one block (@?) — nothing else: \(types)")
    }

    @Test func theInterfaceVersionCoversQuit() {
        #expect(HelperInterface.version >= HelperInterface.quitVersion)
        #expect(HelperInterface.quitVersion == 5, "quit() arrived in version 5; bump this only with the interface")
    }

    @Test func theHelperStaysOnDemand() throws {
        // Restart relies on launchd starting the helper again on the next request: that holds only
        // while the plist has no KeepAlive (which would respawn at once) — and no RunAtLoad either.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let plist = url.appendingPathComponent("Resources/\(HelperInterface.plistName)")
        let dictionary = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect(dictionary["KeepAlive"] == nil)
        #expect(dictionary["RunAtLoad"] == nil)
        #expect((dictionary["MachServices"] as? [String: Any])?[HelperInterface.label] != nil)
    }
}
