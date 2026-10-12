import Foundation
import Network
import OSLog
import FlotillaCore

/// This Mac's restart policies and health checks (DECISIONS Q53), and what the engine knows about
/// each container — kept on disk, so a relaunch neither forgets a policy nor its history.
@MainActor
@Observable
final class PolicyStore {
    private(set) var policies: [String: ContainerPolicy] = [:]
    private(set) var engine = PolicyEngine()
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let log = Logger(subsystem: SettingsPersistence.domain, category: "policies")

    private struct Saved: Codable {
        var policies: [String: ContainerPolicy]
        var watches: [String: PolicyEngine.Watch]
    }

    init(file: URL? = PolicyStore.defaultFile) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            policies = saved.policies
            // A check in flight when Flotilla quit never finished: it starts over.
            var watches = saved.watches
            for id in watches.keys { watches[id]?.probing = false }
            engine = PolicyEngine(watches: watches)
        }
    }

    static var defaultFile: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(SettingsPersistence.domain).appendingPathComponent("policies.json")
    }

    func policy(for id: String) -> ContainerPolicy { policies[id] ?? ContainerPolicy() }

    func watch(for id: String) -> PolicyEngine.Watch? { engine.watches[id] }

    /// Sets a container's policy. An empty one is removed, with what the engine knew.
    func set(_ policy: ContainerPolicy, for id: String) {
        if policy.isEmpty {
            policies[id] = nil
            engine.forget(id)
        } else {
            policies[id] = policy
        }
        save()
    }

    /// Changes the engine, then saves.
    func update<T>(_ change: (inout PolicyEngine) -> T) -> T {
        let result = change(&engine)
        save()
        return result
    }

    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Saved(policies: policies, watches: engine.watches)).write(to: file, options: .atomic)
        } catch {
            log.error("Couldn't save policies: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The two checks that don't run anything in the container: a port that answers, and an HTTP
/// status from a container's own published port on this Mac. Plain TCP, so `http://127.0.0.1`
/// needs no App Transport Security exception, and nothing but loopback is ever dialled.
enum PolicyProbe {
    /// Whether `127.0.0.1:port` accepts a connection within `timeout` seconds.
    static func port(_ port: Int, timeout: Int) async -> (ok: Bool, detail: String) {
        await exchange(port: port, timeout: timeout, request: nil)
    }

    /// `GET path` on `127.0.0.1:port`: OK on a 2xx or 3xx status line.
    static func http(port: Int, path: String, timeout: Int) async -> (ok: Bool, detail: String) {
        let request = "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1:\(port)\r\nUser-Agent: Flotilla-health\r\nConnection: close\r\n\r\n"
        return await exchange(port: port, timeout: timeout, request: Data(request.utf8))
    }

    private static func exchange(port: Int, timeout: Int, request: Data?) async -> (ok: Bool, detail: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return (false, "Not a port: \(port)") }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "dev.melonfleet.Flotilla.probe")
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            queue.asyncAfter(deadline: .now() + .seconds(max(1, timeout))) {
                connection.cancel()
                once.resume((false, "No answer within \(timeout)s"))
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let request else {
                        connection.cancel()
                        once.resume((true, "Port \(port) answered"))
                        return
                    }
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                        connection.cancel()
                        guard let data, let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else {
                            once.resume((false, error.map { "No HTTP answer: \($0.localizedDescription)" } ?? "No HTTP answer"))
                            return
                        }
                        // "HTTP/1.1 200 OK" — the status is the second word.
                        let parts = line.split(separator: " ")
                        let code = parts.count > 1 ? Int(parts[1]) : nil
                        if let code, (200..<400).contains(code) {
                            once.resume((true, "HTTP \(code)"))
                        } else {
                            once.resume((false, code.map { "HTTP \($0)" } ?? "Not an HTTP answer"))
                        }
                    }
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    once.resume((false, "Port \(port): \(error.localizedDescription)"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Resumes a continuation once, whichever of the timeout and the answer comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(ok: Bool, detail: String), Never>?
        init(_ continuation: CheckedContinuation<(ok: Bool, detail: String), Never>) { self.continuation = continuation }
        func resume(_ value: (Bool, String)) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: (ok: value.0, detail: value.1))
        }
    }
}
