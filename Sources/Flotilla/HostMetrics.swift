import Foundation
import Darwin

/// The **machine's** CPU, memory and network — read from the OS, not from the container runtime.
///
/// This exists because of a correction. Reviewing Orchard's dashboard I claimed the CPU tile
/// could only ever show "CPU, all containers", on the grounds that `container stats` reports no
/// host-wide figure. The premise was true; the conclusion was not. A native Mac app does not
/// need the container runtime to tell it how busy the Mac is — the kernel will, which is where
/// Activity Monitor gets its numbers. The owner caught it.
///
/// Host and container metrics answer **different questions** and neither substitutes for the
/// other: host CPU answers "is my Mac struggling?", container CPU answers "which container is
/// doing it?". Both belong on the dashboard, labelled distinctly. What must never happen is
/// summed container CPU presented as machine CPU.
///
/// **Lives in the app target, not `FlotillaCore`.** `host_statistics` and `getifaddrs` are
/// Darwin-only, and the core stays Foundation-only so the VM agents can keep building and
/// testing it on Linux. Same rule that puts `Theme.swift` and the AppKit shims here.
///
/// No entitlement and no network: these are local kernel counters. Nothing here weakens the
/// no-phone-home promise the About view makes.
@MainActor
@Observable
final class HostMetricsSampler {

    /// One reading. Every field is optional for the usual reason: a rate needs two samples, so
    /// the first call cannot know one, and `nil` renders as an em dash rather than a false zero.
    struct Sample: Equatable {
        let date: Date
        /// 0–100 across all cores combined, matching what Activity Monitor's "% CPU" shows for
        /// the system as a whole.
        let cpuPercent: Double?
        let cpuUserPercent: Double?
        let cpuSystemPercent: Double?
        let memoryUsedBytes: Int64
        let memoryTotalBytes: Int64
        let networkRxBytesPerSecond: Double?
        let networkTxBytesPerSecond: Double?
    }

    private(set) var history: [Sample] = []
    var latest: Sample? { history.last }

    /// Physical cores, for the "N cores" readout. Distinct from the cores containers have
    /// *reserved*, which can exceed this — the screenshot that prompted this work showed
    /// "70 cores reserved" on a machine with far fewer, i.e. over-commit. Conflating the two
    /// would inherit that ambiguity.
    let coreCount = ProcessInfo.processInfo.processorCount

    /// Matches `StatsSampler.historyLimit`, so the host and container charts cover the same
    /// window and a range selector means the same thing on both.
    private static let historyLimit = 720

    private var previousTicks: CPUTicks?
    private var previousNetwork: (rx: UInt64, tx: UInt64, at: Date)?

    /// Takes a reading. Called from the same timer that polls container stats, so the two series
    /// share a cadence and can be plotted on one axis.
    func sample(at now: Date = Date()) {
        let cpu = cpuUsage(at: now)
        let memory = memoryUsage()
        let network = networkRates(at: now)

        history.append(Sample(date: now,
                              cpuPercent: cpu?.total,
                              cpuUserPercent: cpu?.user,
                              cpuSystemPercent: cpu?.system,
                              memoryUsedBytes: memory.used,
                              memoryTotalBytes: memory.total,
                              networkRxBytesPerSecond: network?.rx,
                              networkTxBytesPerSecond: network?.tx))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    // MARK: CPU

    private struct CPUTicks { let user, system, idle, nice: UInt32 }

    /// `HOST_CPU_LOAD_INFO` gives cumulative tick counters, so a percentage is the busy delta
    /// over the total delta — the same shape as `cpuUsageUsec`, and unknowable on a first
    /// sample for the same reason.
    private func cpuUsage(at now: Date) -> (total: Double, user: Double, system: Double)? {
        guard let ticks = readCPUTicks() else { return nil }
        defer { previousTicks = ticks }
        guard let last = previousTicks else { return nil }

        let user = Double(ticks.user &- last.user)
        let system = Double(ticks.system &- last.system)
        let nice = Double(ticks.nice &- last.nice)
        let idle = Double(ticks.idle &- last.idle)
        let busy = user + system + nice
        let total = busy + idle
        // A zero interval means the counters have not moved; reporting 0% busy would be a
        // guess dressed as a measurement.
        guard total > 0 else { return nil }

        return (busy / total * 100, user / total * 100, system / total * 100)
    }

    private func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                        idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    // MARK: Memory

    /// "Used" here is active + inactive + wired + compressed, which is what Activity Monitor
    /// counts as memory in use — free and purgeable pages are excluded. Reporting only `active`
    /// would understate it badly on a machine under pressure.
    private func memoryUsage() -> (used: Int64, total: Int64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, Int64(total)) }

        // `vm_kernel_page_size` is a mutable global, which Swift 6 rightly refuses to let a
        // concurrent context read. `vm_page_size` via `host_page_size` is the supported way to
        // ask, and it cannot change under us mid-process.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let used = (UInt64(stats.active_count) + UInt64(stats.inactive_count)
                    + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (Int64(used), Int64(total))
    }

    // MARK: Network

    /// Summed across every link-layer interface, from `if_data`'s cumulative byte counters.
    ///
    /// This is **whole-machine** traffic — it includes the container runtime's own vmnet
    /// interfaces, so it is not a measure of container traffic and is not labelled as one.
    private func networkRates(at now: Date) -> (rx: Double, tx: Double)? {
        let current = readNetworkBytes()
        defer { previousNetwork = (current.rx, current.tx, now) }
        guard let last = previousNetwork else { return nil }

        let elapsed = now.timeIntervalSince(last.at)
        // Counters are 32-bit on some interfaces and do wrap; a backwards delta is a wrap or a
        // reset, not negative throughput.
        guard elapsed > 0, current.rx >= last.rx, current.tx >= last.tx else { return nil }

        return (Double(current.rx - last.rx) / elapsed,
                Double(current.tx - last.tx) / elapsed)
    }

    private func readNetworkBytes() -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, addresses != nil else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var cursor = addresses
        while let node = cursor {
            if node.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = node.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
            cursor = node.pointee.ifa_next
        }
        return (rx, tx)
    }
}
