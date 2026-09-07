import Foundation
import Testing
@testable import FlotillaCore

/// The in-flight registry is here rather than in `AppModel` for the reason `DeletePolicyTests`
/// gives: the app target has no test target, and "does the wrong row grey out" should not be in
/// the untested half. These are the tests that would have failed on the shipped code.

/// The bug, stated directly.
///
/// `busy` was a `Set<String>` shared by containers, images, volumes and networks, so a slow
/// `container stop web` disabled the delete button on volume `web`. Machines escaped it only by
/// keeping a second set of their own.
@Test func aBusyIdOfOneKindIsNotBusyForAnyOther() {
    var busy = BusySet()
    busy.mark("web", kind: .container)

    #expect(busy.contains("web", kind: .container))
    // `allCases` rather than a written-out list: a sixth kind added later is covered the day it
    // is added, instead of the day someone remembers to extend this test.
    for kind in ActivityKind.allCases where kind != .container {
        #expect(!busy.contains("web", kind: kind), "\(kind) named web read as busy")
    }
}

/// The same in every direction, not just outward from containers. The old shared set was
/// symmetrical: deleting volume `web` disabled the container's Stop button too.
@Test func noPairOfKindsBleedsIntoEachOther() {
    for marked in ActivityKind.allCases {
        var busy = BusySet()
        busy.mark("web", kind: marked)
        for other in ActivityKind.allCases where other != marked {
            #expect(!busy.contains("web", kind: other), "\(marked) leaked into \(other)")
        }
    }
}

/// Machines are in the one set now. They used to have `busyMachines` precisely *because* the
/// shared set collided — the collision was understood and fixed for one kind out of five. This
/// asserts the separation survived the merge, so folding the second mechanism in did not
/// reintroduce what it was built to avoid.
@Test func aMachineAndAContainerOfTheSameNameStayIndependent() {
    var busy = BusySet()
    busy.mark("web", kind: .machine)
    #expect(!busy.contains("web", kind: .container))

    busy.mark("web", kind: .container)
    #expect(busy.contains("web", kind: .machine))
    #expect(busy.contains("web", kind: .container))
    #expect(busy.count == 2)

    // Clearing one must not clear the other. A `defer` in one action's path releasing another
    // action's row would leave live controls on something still in flight — the dangerous
    // direction, since that is a second click that reaches the CLI rather than a greyed-out row.
    busy.clear("web", kind: .container)
    #expect(busy.contains("web", kind: .machine))
    #expect(!busy.contains("web", kind: .container))
}

/// The multi-selection bars read `containsAny`, so it needs the same guarantee as `contains` —
/// otherwise the bulk bar is disabled by an unrelated kind sharing one name.
@Test func containsAnyIsKindedToo() {
    var busy = BusySet()
    busy.mark("cache", kind: .image)

    #expect(busy.containsAny(of: ["web", "cache", "db"], kind: .image))
    #expect(!busy.containsAny(of: ["web", "cache", "db"], kind: .volume))
    // An empty selection is not busy; the bars ask before there is anything selected.
    #expect(!busy.containsAny(of: [String](), kind: .image))
}

/// Marking twice is not an error and clearing once is enough. Both matter because the callers are
/// inconsistent by design: the single-row paths guard with `contains` first and the bulk loop
/// skips ids already in flight, so a key must never end up needing two clears.
@Test func markIsIdempotentAndOneClearIsEnough() {
    var busy = BusySet()
    busy.mark("web", kind: .volume)
    busy.mark("web", kind: .volume)
    #expect(busy.count == 1)

    busy.clear("web", kind: .volume)
    #expect(!busy.contains("web", kind: .volume))
    #expect(busy.isEmpty)

    // Clearing something that was never marked is a no-op, not a crash: `defer` blocks run on
    // paths that returned before marking.
    busy.clear("nothing", kind: .volume)
    #expect(busy.isEmpty)
}

/// Ids still have to tell each other apart within one kind — the original purpose of the set,
/// which the kinding must not have flattened.
@Test func differentIdsOfTheSameKindStayDistinct() {
    var busy = BusySet()
    busy.mark("web", kind: .container)
    #expect(!busy.contains("db", kind: .container))
}

/// A fresh set is empty. The views ask `isBusy` on every row of every refresh, before anything
/// has ever been marked.
@Test func aNewBusySetIsEmpty() {
    let busy = BusySet()
    #expect(busy.isEmpty)
    for kind in ActivityKind.allCases {
        #expect(!busy.contains("web", kind: kind))
    }
}
