import AppKit
import Darwin
import FlotillaCore
import SwiftUI

/// This Mac's IPv4 addresses, for `NetworkHealth`: a network's gateway should be one of them.
enum HostInterfaces {
    static func ipv4Addresses() -> Set<String> {
        var result = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.insert(String(cString: host))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}

extension AppModel {
    /// Networks with running containers whose gateway is missing from this Mac —
    /// apple/container#2051 (DECISIONS Q30). Empty until both lists have loaded, so a slow
    /// refresh never raises a false alarm.
    var disconnectedNetworks: [String] {
        guard state == .loaded, networksState == .loaded else { return [] }
        let running = Set(containers.filter(\.isRunning)
            .flatMap { $0.status.networks?.compactMap(\.network) ?? [] })
        guard !running.isEmpty else { return [] }
        return NetworkHealth.disconnected(
            networks: networks.map { .init(name: $0.id, gateway: Readiness.address(fromIPv4: $0.gateway)) },
            withRunningContainers: running,
            hostAddresses: HostInterfaces.ipv4Addresses())
    }
}

/// Said where the symptom shows: Networks and Containers. A container on such a network "is
/// running" and cannot be reached — the hardest kind of fault to read — so this names the
/// network, the cause and the one fix.
struct DisconnectedNetworksBanner: View {
    let model: AppModel
    @State private var confirmingRestart = false

    static let issueURL = URL(string: "https://github.com/apple/container/issues/2051")!

    var body: some View {
        let names = model.disconnectedNetworks
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "network.slash")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(names.count == 1
                         ? "\(names[0]) has lost its connection to this Mac."
                         : "\(names.joined(separator: ", ")) have lost their connection to this Mac.")
                        .font(.callout.weight(.medium))
                    Text("Its containers can reach each other but not this Mac or the internet, and "
                         + "their published ports don't answer. It's a known container bug; restarting "
                         + "container fixes it.")
                        .font(.caption).foregroundStyle(.secondary)
                        // A line limit, never `fixedSize(vertical:)`: in a section's top band that
                        // blanks the whole window (found twice on 6 October — see SuggestionsView).
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Button("About the Bug") { NSWorkspace.shared.open(Self.issueURL) }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.link)
                    .help(Self.issueURL.absoluteString)
                Button("Restart container…") { confirmingRestart = true }
                    .disabled(model.startingRuntime)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.warning.opacity(0.08))
            .confirmationDialog("Restart container?", isPresented: $confirmingRestart,
                                titleVisibility: .visible) {
                Button("Restart") { Task { await model.restartRuntime() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every running container stops, and isn't started again automatically. Start "
                     + "them afterwards — groups from their rows.")
            }
        }
    }
}
