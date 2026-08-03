import Darwin
import Foundation

// --- host CPU: HOST_CPU_LOAD_INFO tick counters, delta over wall clock ---
func cpuTicks() -> (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
}

// --- host memory: vm_statistics64 + hw.memsize ---
func memory() -> (usedBytes: UInt64, totalBytes: UInt64)? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)
    // Apple's own definition of "used": everything that is not free or purgeable.
    let used = (UInt64(stats.active_count) + UInt64(stats.inactive_count)
                + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    var total: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &total, &size, nil, 0)
    return (used, total)
}

// --- host network: getifaddrs if_data byte counters ---
func networkBytes() -> (rx: UInt64, tx: UInt64) {
    var rx: UInt64 = 0, tx: UInt64 = 0
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
    defer { freeifaddrs(addrs) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
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

let a = cpuTicks()!, n0 = networkBytes()
Thread.sleep(forTimeInterval: 1.0)
let b = cpuTicks()!, n1 = networkBytes()

let du = Double(b.user - a.user), ds = Double(b.system - a.system)
let dn = Double(b.nice - a.nice), di = Double(b.idle - a.idle)
let busy = du + ds + dn, totalTicks = busy + di
print(String(format: "host CPU:      %.1f%% busy  (user %.1f%%, system %.1f%%)",
             busy / totalTicks * 100, du / totalTicks * 100, ds / totalTicks * 100))
print("cores:         \(ProcessInfo.processInfo.processorCount)")
if let m = memory() {
    let f = ByteCountFormatter()
    print("host memory:   \(f.string(fromByteCount: Int64(m.usedBytes))) of \(f.string(fromByteCount: Int64(m.totalBytes)))")
}
print(String(format: "host network:  down %.1f KB/s, up %.1f KB/s",
             Double(n1.rx - n0.rx) / 1024, Double(n1.tx - n0.tx) / 1024))
