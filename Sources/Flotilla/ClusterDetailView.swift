import SwiftUI
import FlotillaCore

/// A cluster's page, beside the Clusters list (Q58).
///
/// **New, and deliberately small.** Every other row section had a page to reuse; a cluster had
/// none, because `k8s list` is all `container` says about one and the row already carried it. The
/// split needs something on the right when a cluster is selected, and an empty state would say
/// "nothing to see" about a running Kubernetes. So this is the row's facts laid out as the other
/// pages lay theirs out — the same `DetailCard`s — and nothing the CLI does not print: no node
/// count, no Kubernetes version, no live usage (see `ClustersView` on why those are absent).
///
/// No tabs, because there is nothing for a second one to show yet; the header above it, drawn by
/// `ClustersView`, carries the row's actions.
struct ClusterDetailView: View {
    let row: HostedCluster

    var body: some View {
        let cluster = row.cluster
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DetailCard(title: "Cluster", minHeight: nil) {
                    fact("Name", cluster.name)
                    fact("State", cluster.state.capitalized)
                    if !cluster.roles.isEmpty { fact("Role", cluster.roles.joined(separator: ", ")) }
                    fact("Mac", row.hostName + (row.staleSince == nil ? "" : " — not answering"))
                }
                DetailCard(title: "Resources", minHeight: nil) {
                    fact("CPUs", cluster.cpus.map(String.init) ?? "—")
                    // As the CLI prints it: `k8s list` gives a string, not bytes.
                    fact("Memory", cluster.memory.isEmpty ? "—" : cluster.memory)
                }
                DetailCard(title: "Reach it", minHeight: nil) {
                    fact("Address", cluster.address.isEmpty ? "—" : cluster.address, monospaced: true)
                    fact("API", cluster.ports.isEmpty ? "—" : cluster.ports.joined(separator: ", "), monospaced: true)
                    fact("kubectl", "kubectl --context \(cluster.node)", monospaced: true)
                    Text(row.host.isLocal
                         ? "The API server is reachable on this Mac at the host port. Write Kubeconfig, in the row's menu, puts the context where kubectl looks."
                         : "The API server is on \(row.hostName), at the host port.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The label-and-value row the other pages' overview cards use.
    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }
}
