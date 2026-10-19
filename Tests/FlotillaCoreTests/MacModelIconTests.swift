import Foundation
import Testing
@testable import FlotillaCore

@Suite struct MacModelIconTests {
    @Test func classifiesVirtualRealAndUnknown() {
        // VirtualMac2,1 is what `hw.model` reports on a Virtualization-framework guest (measured).
        #expect(MacModelKind("VirtualMac2,1") == .virtual)
        #expect(MacModelKind("virtualmac2,1") == .virtual)
        #expect(MacModelKind("Macmini9,1") == .hardware("Macmini9,1"))
        #expect(MacModelKind("Mac14,13") == .hardware("Mac14,13"))
        #expect(MacModelKind(" Mac16,10\n") == .hardware("Mac16,10"))
        #expect(MacModelKind(nil) == .unknown)
        #expect(MacModelKind("") == .unknown)
        #expect(MacModelKind("  \n") == .unknown)
    }

    @Test func virtualPrefixIsNotMatchedMidString() {
        #expect(MacModelKind("NotVirtualMac1,1") == .hardware("NotVirtualMac1,1"))
    }

    @Test func cacheAsksOncePerKeyAndRemembersMisses() {
        let calls = Counter()
        let cache = ModelIconCache<Int> { key in
            calls.bump()
            return key == "known" ? 7 : nil
        }
        #expect(cache.value(for: "known") == 7)
        #expect(cache.value(for: "known") == 7)
        #expect(cache.value(for: "unknown") == nil)
        #expect(cache.value(for: "unknown") == nil)
        #expect(calls.value == 2)
        #expect(cache.count == 2)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
