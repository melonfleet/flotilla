import SwiftUI
import FlotillaCore

/// Which pane of the network detail is showing. Two, for the reason `VolumeDetailTab` gives:
/// the CLI has nothing else to back a tab with.
enum NetworkDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inspect = "Inspect"
    var id: Self { self }

    var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .inspect: "curlybraces"
        }
    }
}

/// Detail for one network, embedded like every other detail screen. See `VolumeDetailView` for
/// why this replaced a floating sheet.
struct NetworkDetailView: View {
    let model: AppModel
    let network: ContainerNetwork

    /// A tab the caller asked for — "Inspect" from the row menu — which wins over the default.
    let requestedTab: NetworkDetailTab?

    @State private var tab: NetworkDetailTab

    init(model: AppModel, network: ContainerNetwork, requestedTab: NetworkDetailTab? = nil) {
        self.model = model
        self.network = network
        self.requestedTab = requestedTab
        _tab = State(initialValue: requestedTab ?? .overview)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(items: NetworkDetailTab.allCases.map {
                .init(tab: $0, title: $0.rawValue, systemImage: $0.systemImage)
            }, selection: $tab)

            Group {
                switch tab {
                case .overview: overview
                case .inspect:
                    InspectPane(command: "container network inspect \(network.id)",
                                failureTitle: "Couldn't inspect this network") {
                        try await model.fetchNetworkInspectJSON(for: network.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          alignment: .leading, spacing: 12) {
                    DetailCard(title: "Network", minHeight: 112) {
                        row("Name", network.name)
                        row("Mode", network.mode ?? "—")
                        row("Plugin", network.plugin ?? "—")
                        row("Built in", network.isBuiltin ? "Yes" : "No")
                    }

                    DetailCard(title: "Addressing", minHeight: 112) {
                        // From `status`, which is assigned by the network plugin at creation —
                        // observed state rather than declared intent, and the part `network ls`
                        // does not always return.
                        row("Subnet", network.subnet ?? "—")
                        row("Gateway", network.gateway ?? "—")
                        row("IPv6 subnet", network.ipv6Subnet ?? "—")
                        row("Created", RelativeDate.relative(network.configuration.creationDate))
                    }
                }

                DetailCard(title: "Attached containers", minHeight: nil) {
                    // The question you actually arrive with, and one no `network inspect` answers:
                    // the attachment is recorded on the *container*, so it is read from the
                    // container list rather than from this network's own record.
                    let attached = model.containers.filter {
                        $0.status.networks?.contains { $0.network == network.id } == true
                    }
                    if attached.isEmpty {
                        Text("No containers are attached to this network.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(attached) { container in
                            HStack(spacing: 8) {
                                Circle().fill(container.stateColor).frame(width: 6, height: 6)
                                Button(container.id) {
                                    model.requestDetail(kind: .container, subject: container.id)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accentText)
                                Spacer()
                                Text(container.status.networks?
                                    .first { $0.network == network.id }?.ipv4Address ?? "—")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                DetailCard(title: "Recent events", minHeight: nil) {
                    let events = model.events(for: network.id, kind: .network)
                    if events.isEmpty {
                        Text("Nothing has changed since Flotilla started. Changes appear here as "
                             + "they happen; history from before launch is not recorded.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(events.prefix(8)) { event in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Theme.color(forEventEndingIn: event.to))
                                    .frame(width: 6, height: 6)
                                Text(event.summary).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
