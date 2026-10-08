import Foundation
import Darwin
import IOKit
import IOKit.storage

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
        /// Reclaimable file cache. Reported so the gap between "used" and "installed" is
        /// accounted for on screen rather than looking like memory that went missing.
        let memoryCachedBytes: Int64
        let networkRxBytesPerSecond: Double?
        let networkTxBytesPerSecond: Double?
        let diskReadBytesPerSecond: Double?
        let diskWriteBytesPerSecond: Double?
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
    private var previousDisk: (read: UInt64, written: UInt64, at: Date)?

    /// Takes a reading. Called from the same timer that polls container stats, so the two series
    /// share a cadence and can be plotted on one axis.
    func sample(at now: Date = Date()) {
        let cpu = cpuUsage(at: now)
        let memory = memoryUsage()
        let network = networkRates(at: now)
        let disk = diskRates(at: now)

        history.append(Sample(date: now,
                              cpuPercent: cpu?.total,
                              cpuUserPercent: cpu?.user,
                              cpuSystemPercent: cpu?.system,
                              memoryUsedBytes: memory.used,
                              memoryTotalBytes: memory.total,
                              memoryCachedBytes: memory.cached,
                              networkRxBytesPerSecond: network?.rx,
                              networkTxBytesPerSecond: network?.tx,
                              diskReadBytesPerSecond: disk?.read,
                              diskWriteBytesPerSecond: disk?.write))
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

    /// "Used" is **App Memory + Wired + Compressed**, which is what Activity Monitor means by
    /// "Memory Used".
    ///
    /// The previous version of this comment claimed the same thing and the code did not do it:
    /// it summed `active + inactive + wired + compressed`, and `inactive_count` is reclaimable
    /// file-backed cache that Activity Monitor deliberately excludes. On this Mac that put the
    /// gauge at **97.3% of 64 GB**, permanently, which is what a `total - free` calculation
    /// would also have shown — a reading that is always alarming is worse than no reading,
    /// because it tells you nothing and trains you to ignore the panel.
    ///
    /// Measured on 3 August with 64 GiB installed: inactive was 26.0 GiB and external
    /// (file-backed) 19.9 GiB. Counting those as used accounted for the entire discrepancy.
    /// The honest figure was 45.0 GB / 65.5%.
    ///
    /// - App Memory is `internal_page_count - purgeable_count` — anonymous pages a process
    ///   owns, less what the system may drop at will.
    /// - Wired is memory the kernel cannot page out.
    /// - Compressed is what the compressor holds; it is genuinely occupied, and a large value
    ///   here is the real signal that the machine is under pressure.
    ///
    /// `cached` is returned alongside so the UI can say where the remainder went.
    private func memoryUsage() -> (used: Int64, total: Int64, cached: Int64) {
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
        guard result == KERN_SUCCESS else { return (0, Int64(total), 0) }

        // `vm_kernel_page_size` is a mutable global, which Swift 6 rightly refuses to let a
        // concurrent context read. `vm_page_size` via `host_page_size` is the supported way to
        // ask, and it cannot change under us mid-process.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        // `internal_page_count` can in principle be smaller than `purgeable_count` between
        // samples; subtracting unsigned would wrap to an enormous number, so clamp.
        let appPages = UInt64(stats.internal_page_count)
            .subtractingReportingOverflow(UInt64(stats.purgeable_count))
        let app = appPages.overflow ? 0 : appPages.partialValue
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        return (Int64(used), Int64(total), Int64(cached))
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

    // MARK: Disk

    /// Summed across every physical drive's `IOBlockStorageDriver`, from its `Statistics`
    /// dictionary's cumulative byte counters.
    ///
    /// This is **whole-machine** I/O — every volume on every physical drive, including
    /// whatever the container runtime's own disk images are doing — not a measure of
    /// container disk usage and not labelled as one, matching the network rule above.
    private func diskRates(at now: Date) -> (read: Double, write: Double)? {
        // A failed registry read is **unknown, not zero** — and the baseline is deliberately left
        // untouched. Returning (0, 0) here would poison the next sample: the following good read
        // returns a cumulative since-boot figure, which diffed against zero reports hundreds of
        // gigabytes per second. Same rule the rest of this file follows, applied to the failure
        // path rather than only to the first sample.
        guard let current = readDiskBytes() else { return nil }
        defer { previousDisk = (current.read, current.written, now) }
        guard let last = previousDisk else { return nil }

        let elapsed = now.timeIntervalSince(last.at)
        // Same reasoning as the network counters: a backwards delta is a wrap or a driver
        // reset, not negative throughput, and is reported as unknown rather than as zero.
        guard elapsed > 0, current.read >= last.read, current.written >= last.written else {
            return nil
        }

        return (Double(current.read - last.read) / elapsed,
                Double(current.written - last.written) / elapsed)
    }

    /// Walks the IOService registry for `IOBlockStorageDriver` nodes — one per physical
    /// drive — and sums each one's reported bytes read/written since boot. Every service and
    /// the iterator itself are IOKit-owned objects this call must release; `IOIteratorNext`
    /// hands over a `+1` reference on each call, same as `IOServiceGetMatchingServices` does
    /// for the iterator.
    private func readDiskBytes() -> (read: UInt64, written: UInt64)? {
        var read: UInt64 = 0
        var written: UInt64 = 0

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOBlockStorageDriverClass)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(
                service, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            let statistics = property.takeRetainedValue()
            guard let stats = statistics as? [String: Any] else { continue }

            if let bytesRead = stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? UInt64 {
                read += bytesRead
            }
            if let bytesWritten = stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? UInt64 {
                written += bytesWritten
            }
        }
        return (read, written)
    }
}
