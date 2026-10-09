import Foundation
import Network
import FlotillaCore

/// Flotilla's own DNS answers for other Macs' zones (PLAN.md Phase D, layer 2, Part C; DECISIONS
/// Q37): UDP on **127.0.0.1:7869 only**, so nothing off this Mac can ask it anything. The helper's
/// resolver files send `*.<other Mac's zone>` lookups here; `FleetDNSMessage` answers each from the
/// current table.
public final class FleetDNSResponder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.melonfleet.Flotilla.fleet-dns")
    private let lock = NSLock()
    private var table: FleetNameTable?
    private var listener: NWListener?
    public private(set) var lastError: String?

    public init() {}

    /// What to answer from. `nil` (or an empty table) stops the listener.
    public func update(_ table: FleetNameTable?) {
        let active = table.flatMap { $0.zones.isEmpty ? nil : $0 }
        lock.withLock { self.table = active }
        queue.async { [self] in
            if active == nil { stop() } else if listener == nil { start() }
        }
    }

    private func start() {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: FleetResolvers.port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.lastError = "flotilla couldn't answer names on port \(FleetResolvers.port): \(error.localizedDescription)"
                    self?.queue.async { self?.stop() }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            lastError = nil
        } catch {
            lastError = "flotilla couldn't answer names on port \(FleetResolvers.port): \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Each datagram is answered on its own; the flow is closed after a short idle.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            if let table = self.lock.withLock({ self.table }),
               let reply = FleetDNSMessage.respond(to: data, table: table) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
            self.receive(on: connection)
        }
    }
}
