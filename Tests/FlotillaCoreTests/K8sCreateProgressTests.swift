import Foundation
import Testing
@testable import FlotillaCore

@Test func aCountedProgressLineIsParsed() {
    let progress = try? #require(K8sCreateProgress.parse("[2/2] Waiting for cluster to be ready [12m 3s]"))
    #expect(progress?.step == 2)
    #expect(progress?.total == 2)
    #expect(progress?.phase == "Waiting for cluster to be ready")
    #expect(progress?.elapsed == "12m 3s")
    #expect(progress?.summary == "Waiting for cluster to be ready · 2 of 2 · 12m 3s")
}

@Test func aPlainSentenceIsAPhaseWithNoCounterOrClock() {
    let progress = try? #require(K8sCreateProgress.parse("Waiting for kube-system pods to become ready"))
    #expect(progress?.step == nil)
    #expect(progress?.elapsed == nil)
    #expect(progress?.phase == "Waiting for kube-system pods to become ready")
    #expect(progress?.summary == "Waiting for kube-system pods to become ready")
}

/// The CLI leaks a Swift dictionary literal into two of its lines. The useful half is kept.
@Test func aLoggedDictionaryIsTrimmedToItsSentence() {
    #expect(K8sCreateProgress.parse("Fetching kubeconfig: [\"cluster\": k8s-dev]")?.phase
            == "Fetching kubeconfig")
    #expect(K8sCreateProgress.parse("Writing kubeconfig: [\"cluster\": k8s-dev, \"path\": /Users/someone/.kube/config]")?.phase
            == "Writing kubeconfig")
}

/// `container k8s create` prints the cluster's name on success. It is the command's result, not
/// a phase, and a bare word where a sentence belongs reads as the panel having lost its place.
@Test func theClusterNameOnSuccessIsNotProgress() {
    #expect(K8sCreateProgress.parse("k8s-dev") == nil)
    #expect(K8sCreateProgress.parse("") == nil)
    #expect(K8sCreateProgress.parse("   \n") == nil)
}

/// Every line of a real twelve-minute create parses to something showable or to nothing, and
/// nothing is only ever the trailing name.
@Test func everyLineOfARealCreateIsAccountedFor() throws {
    let url = try #require(Bundle.module.url(forResource: "k8s-create-progress",
                                             withExtension: "txt", subdirectory: "Fixtures"))
    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(lines.count == 20)

    let unparsed = lines.filter { K8sCreateProgress.parse($0) == nil }
    #expect(unparsed == ["k8s-dev"], "only the result line should yield nothing")

    // The clock the CLI keeps is what makes the panel believable during a long wait.
    let last = try #require(K8sCreateProgress.parse("[2/2] Writing kubeconfig [12m 18s]"))
    #expect(last.summary == "Writing kubeconfig · 2 of 2 · 12m 18s")
}
