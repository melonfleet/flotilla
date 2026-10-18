import Foundation

/// Runs blocking work — a `container` process waited on, a remote host call parked on a semaphore —
/// on GCD, never on Swift's cooperative pool.
///
/// **Why this exists (18 October):** Flotilla stopped quitting after a few section switches. A
/// sample of the hung app showed all 16 cooperative threads (one per core) parked in
/// `RemoteHost.run`'s semaphore, each from a `Task.detached { cli.versions() … }` in the live-status
/// refresh — three hosts were unreachable, and every Images, Volumes and Networks visit asked every
/// host again. `Task.detached` still runs on the cooperative pool, so each blocking call held a pool
/// thread for its whole timeout; with none left, nothing that needed the pool could run, and the
/// quit never arrived. GCD grows its threads for blocking work; the pool does not.
public enum Blocking {
    private static let queue = DispatchQueue(label: "dev.melonfleet.Flotilla.blocking", qos: .utility,
                                             attributes: .concurrent)

    /// `work` on a GCD thread; the caller suspends without holding a pool thread.
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
