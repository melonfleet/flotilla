import Foundation
import Testing
@testable import FlotillaCore

// `container` 1.5.0 changed the experimental `k8s` family (to-do item 2, 2026-10-05):
// - `k8s start` is gone (apple/container#2290). Recovery is delete-then-create, which Flotilla now
//   offers as Recreate, keeping the name, CPUs and memory.
// - `--node-image` must name a tag (apple/container#2271): untagged and digest-only references fail
//   with `invalidArgument` before anything is provisioned.

@Test func k8sStartIsNoLongerAllowed() {
    // Default-deny: a grammar for a subcommand that no longer exists is a promise the allowlist
    // cannot keep, so the spec went with the command.
    #expect(throws: AllowlistError.self) {
        try Allowlist.validate(["k8s", "start", "--name", "k8s-dev"], mountPolicy: .unrestricted).get()
    }
}

@Test func aNodeImageMustNameATag() throws {
    func create(_ image: String) -> Result<ValidatedCommand, AllowlistError> {
        Allowlist.validate(["k8s", "create", "--name", "dev", "--node-image", image], mountPolicy: .unrestricted)
    }
    // Tagged, with or without a digest after the tag — the CLI's own default has both.
    #expect((try? create("docker.io/kindest/node:v1.35.5").get()) != nil)
    #expect((try? create("docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95").get()) != nil)
    #expect((try? create("localhost:5000/node:v1").get()) != nil)
    // Refused by 1.5.0, so refused here first: untagged, digest-only, and a registry port that
    // only looks like a tag.
    #expect((try? create("docker.io/kindest/node").get()) == nil)
    #expect((try? create("docker.io/kindest/node@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95").get()) == nil)
    #expect((try? create("localhost:5000/node").get()) == nil)
}

@Test func otherImageFieldsStillAcceptAnUntaggedReference() throws {
    // The tag rule is node-image only. `image pull alpine` is fine and means `:latest`.
    _ = try Allowlist.validate(["image", "pull", "docker.io/library/alpine"], mountPolicy: .unrestricted).get()
}

@Test func namesTagLooksOnlyAtTheLastComponent() {
    #expect(Allowlist.namesTag("alpine:3.22"))
    #expect(Allowlist.namesTag("registry.example.com:5000/team/app:1.0"))
    #expect(!Allowlist.namesTag("registry.example.com:5000/team/app"))
    #expect(!Allowlist.namesTag("app@sha256:abc"))
    #expect(!Allowlist.namesTag("app:"))
}

@Test func aNodesMemoryBecomesTheFlagCreateTakes() {
    func node(memory: String) -> K8sNode {
        K8sNode(cluster: "", node: "dev", roles: ["control-plane"], state: "stopped",
                cpus: 2, memory: memory, address: "", ports: [])
    }
    // `k8s list` prints `4096 MB`; `k8s create --memory` takes `4096M`.
    #expect(node(memory: "4096 MB").memoryFlag == "4096M")
    #expect(node(memory: "8 GB").memoryFlag == "8G")
    // Anything else falls back to the CLI's default rather than sending a refused value.
    #expect(node(memory: "").memoryFlag == nil)
    #expect(node(memory: "4096MB").memoryFlag == nil)
    #expect(node(memory: "lots of MB").memoryFlag == nil)
}

@Test func aRecreateWithTheNodesSizeIsAValidCreate() throws {
    let node = K8sNode(cluster: "", node: "k8s-dev", roles: ["control-plane", "worker"], state: "stopped",
                       cpus: 2, memory: "4096 MB", address: "", ports: ["6445->6443"])
    let memory = try #require(node.memoryFlag)
    _ = try Allowlist.validate(["k8s", "create", "--name", node.node, "--cpus", String(try #require(node.cpus)),
                                "--memory", memory], mountPolicy: .unrestricted).get()
}
