import Foundation
import Testing
@testable import FlotillaCore

/// Kyle's P1 and P2 on beta 5 (19 October): an admin sets HTTP and port checks only, and a check
/// dials only the container's own published port.
@Suite struct ContainerPolicyRemoteTests {
    @Test func aCommandCheckIsNeverRemote() {
        let command = ContainerPolicy(health: HealthCheck(probe: .command(["sh", "-c", "id"])))
        #expect(command.remoteProblem != nil)
        #expect(ContainerPolicy(health: HealthCheck(probe: .port(8080))).remoteProblem == nil)
        #expect(ContainerPolicy(health: HealthCheck(probe: .http(port: 8080, path: "/"))).remoteProblem == nil)
        #expect(ContainerPolicy(restart: .unlessStopped).remoteProblem == nil)
    }

    @Test func checksDialOnlyTheContainersOwnPublishedPorts() {
        let http = ContainerPolicy(health: HealthCheck(probe: .http(port: 631, path: "/admin")))
        #expect(http.portProblem(published: [8080]) != nil)
        #expect(http.portProblem(published: []) != nil)
        #expect(ContainerPolicy(health: HealthCheck(probe: .port(8080))).portProblem(published: [8080, 9090]) == nil)
        // A command check dials nothing, and no check means nothing to dial.
        #expect(ContainerPolicy(health: HealthCheck(probe: .command(["true"]))).portProblem(published: []) == nil)
        #expect(ContainerPolicy().portProblem(published: []) == nil)
    }

    @Test func whoSetAPolicySurvivesSavingAndAnOldPolicyCountsAsLocal() throws {
        var policy = ContainerPolicy(health: HealthCheck(probe: .port(80)))
        policy.setByAdmin = true
        let decoded = try JSONDecoder().decode(ContainerPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded.setByAdmin == true)
        let old = #"{"restart":"never","restartWhenUnhealthy":false}"#
        #expect(try JSONDecoder().decode(ContainerPolicy.self, from: Data(old.utf8)).setByAdmin == nil)
    }
}
