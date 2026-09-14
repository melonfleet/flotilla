import Foundation
import Testing
@testable import FlotillaCore

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt",
                                             subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - The real output

@Test func oneClusterParsesFromCapturedOutput() throws {
    let nodes = K8sClusterList.parse(try fixture("k8s-list-one-cluster"))
    #expect(nodes.count == 1)
    let node = try #require(nodes.first)
    #expect(node.node == "k8s-dev")
    #expect(node.roles == ["control-plane", "worker"])
    #expect(node.state == "running")
    #expect(node.isRunning)
    #expect(node.cpus == 3)
    #expect(node.memory == "16384 MB")
    #expect(node.address == "192.168.64.75")
    #expect(node.ports == ["6445->6443"])
}

/// The finding this parser is built around: `container k8s list` reports an **empty** CLUSTER
/// for a cluster created with `--name k8s-dev`, and puts the name under NODE. Captured from two
/// real clusters on 1.4.1, so it is not one cluster being odd.
@Test func theClusterColumnIsEmptyEvenWithTwoClusters() throws {
    for name in ["k8s-list-one-cluster", "k8s-list-two-clusters"] {
        for node in K8sClusterList.parse(try fixture(name)) {
            #expect(node.cluster.isEmpty, "\(name): CLUSTER unexpectedly populated — re-check the parser's assumption")
        }
    }
}

/// The table's widths are recomputed per render: adding `flotilla-probe` moved every column
/// after NODE to the right. Both captures are parsed correctly, which is only possible because
/// the offsets come from each output's own header.
@Test func columnOffsetsAreTakenFromTheOutputsOwnHeader() throws {
    let one = try fixture("k8s-list-one-cluster")
    let two = try fixture("k8s-list-two-clusters")
    // Proof the layouts really do differ, so this test cannot pass by both being identical.
    #expect(one.split(separator: "\n")[0] != two.split(separator: "\n")[0])

    let nodes = K8sClusterList.parse(two)
    #expect(nodes.map(\.node) == ["flotilla-probe", "k8s-dev"])
    #expect(nodes.map(\.memory) == ["2048 MB", "16384 MB"])
    #expect(nodes.map(\.cpus) == [2, 3])
    #expect(nodes.map(\.address) == ["192.168.64.76", "192.168.64.75"])
}

/// The negative control, and the reason the parser does not split on whitespace.
///
/// An empty CLUSTER removes one token and a MEMORY of `16384 MB` adds one, so a naive split
/// yields exactly eight tokens for eight columns. Nothing errors; every value from NODE to
/// MEMORY lands one column to the left. This test pins that the trap is real, so nobody
/// "simplifies" the parser back into it.
@Test func splittingOnWhitespaceWouldSilentlyMisalignEveryColumn() throws {
    let line = try #require(try fixture("k8s-list-one-cluster")
        .split(separator: "\n").dropFirst().first.map(String.init))
    let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)

    #expect(tokens.count == 8, "the trap is that the count looks right")
    // Zipped against the headers, a split parser would believe all of this:
    #expect(tokens[0] == "k8s-dev")              // as CLUSTER — actually the node
    #expect(tokens[1] == "control-plane,worker") // as NODE — actually the role
    #expect(tokens[2] == "running")              // as ROLE — actually the state
    #expect(tokens[5] == "MB")                   // as MEMORY — actually half of it

    // What the real parser returns instead.
    let node = try #require(K8sClusterList.parse(try fixture("k8s-list-one-cluster")).first)
    #expect(node.cluster.isEmpty)
    #expect(node.node == "k8s-dev")
    #expect(node.roles == ["control-plane", "worker"])
    #expect(node.memory == "16384 MB")
}

// MARK: - Shapes the CLI has not produced for us
//
// Hand-written, and labelled as such: these are the parser's contract under output we have not
// seen, not claims about what `container` emits. Every assertion about real output above reads
// from a captured fixture, per the fixture rule in CLAUDE.md.

@Test func outputWithNoRecognisableHeaderYieldsNothingRatherThanGuesses() {
    #expect(K8sClusterList.parse("").isEmpty)
    #expect(K8sClusterList.parse("Error: something went wrong\n").isEmpty)
    // A plausible-looking but differently-named table must not be read as this one.
    #expect(K8sClusterList.parse("NAME  STATUS\nfoo   up\n").isEmpty)
}

@Test func aHeaderWithNoRowsIsAnEmptyListNotAFailure() {
    let header = "CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS\n"
    #expect(K8sClusterList.parse(header).isEmpty)
}

@Test func aRowMissingItsTrailingColumnsStillParses() {
    let table = """
        CLUSTER  NODE     ROLE   STATE    CPUS  MEMORY  ADDR  PORTS
                 partial  worker  stopped
        """
    let node = try? #require(K8sClusterList.parse(table).first)
    #expect(node?.node == "partial")
    #expect(node?.state == "stopped")
    #expect(node?.cpus == nil, "an absent CPU count is not zero CPUs")
    #expect(node?.memory == "")
    #expect(node?.ports == [])
}

@Test func aRowWithNoNodeNameIsNotANode() {
    let table = """
        CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS

        """
    #expect(K8sClusterList.parse(table).isEmpty)
}

/// A column inserted by a future release must not shift the ones this parser knows, because
/// columns are matched by name rather than counted.
@Test func anUnknownColumnIsIgnoredRatherThanShiftingTheOthers() {
    let table = """
        CLUSTER  NODE   VERSION  ROLE    STATE    CPUS  MEMORY   ADDR       PORTS
                 alpha  v1.35.5  worker  running  4     2048 MB  10.0.0.1   6443->6443
        """
    let node = try? #require(K8sClusterList.parse(table).first)
    #expect(node?.node == "alpha")
    #expect(node?.roles == ["worker"])
    #expect(node?.state == "running")
    #expect(node?.cpus == 4)
    #expect(node?.memory == "2048 MB")
}
