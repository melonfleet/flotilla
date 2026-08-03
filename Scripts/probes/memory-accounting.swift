// Memory accounting on macOS — the evidence behind `HostMetrics.memoryUsage()`.
//
// The dashboard reported 66.9 GB of 68.72 GB used, permanently, on a Mac with 64 GB installed.
// Two separate bugs, both visible here:
//
//   1. "Used" summed `active + inactive + wired + compressed`. `inactive_count` is reclaimable
//      file-backed cache, which Activity Monitor's "Memory Used" excludes. Measured: inactive
//      26.0 GiB and external 19.9 GiB — enough to account for the entire discrepancy. The
//      honest figure was 44 GB / 64%.
//   2. `hw.memsize` is 68,719,476,736 bytes = 64 GiB, which `ByteCountFormatter.file` renders
//      as "68.72 GB" — a number that appears nowhere on the machine. Apple counts RAM in
//      binary units and calls them GB.
//
// Corroborated against `top -l 1` sampled at the same instant: compressor matched exactly
// (8.17 GiB both), wired within sampling drift. `top`'s "61G used" is the *inclusive*
// definition and is why that tool also looks near-full; it is not a contradiction.
//
//   swiftc -O -o /tmp/mem Scripts/probes/memory-accounting.swift && /tmp/mem
import Darwin
import Foundation

var total: UInt64 = 0
var sz = MemoryLayout<UInt64>.size
sysctlbyname("hw.memsize", &total, &sz, nil, 0)

var stats = vm_statistics64()
var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
let rc = withUnsafeMutablePointer(to: &stats) { p in
    p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
    }
}
guard rc == KERN_SUCCESS else { print("host_statistics64 failed"); exit(1) }

var ps: vm_size_t = 0
host_page_size(mach_host_self(), &ps)
let page = UInt64(ps)

func gb(_ bytes: UInt64) -> String {
    String(format: "%6.2f GB (%5.1f%%)", Double(bytes) / 1_000_000_000,
           Double(bytes) / Double(total) * 100)
}
func gib(_ bytes: UInt64) -> String {
    String(format: "%6.2f GiB", Double(bytes) / 1_073_741_824)
}

print("page size        \(page)")
print("hw.memsize       \(total)  = \(gib(total)) = \(Double(total)/1e9) GB decimal")
print("")
for (name, v) in [("free", stats.free_count), ("active", stats.active_count),
                  ("inactive", stats.inactive_count), ("speculative", stats.speculative_count),
                  ("wired", stats.wire_count), ("compressor", stats.compressor_page_count),
                  ("purgeable", stats.purgeable_count), ("external", stats.external_page_count),
                  ("internal", stats.internal_page_count)] {
    let label = name.padding(toLength: 12, withPad: " ", startingAt: 0)
    print("  \(label)\(String(format: "%10d", Int(v)))  \(gib(UInt64(v) * page))")
}
print("")
let current = (UInt64(stats.active_count) + UInt64(stats.inactive_count)
               + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
let appMem = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
let activityMonitor = appMem + UInt64(stats.wire_count) * page
                      + UInt64(stats.compressor_page_count) * page
let totalMinusFree = total - UInt64(stats.free_count) * page

print("CURRENT  (active+inactive+wired+compressed) \(gb(current))")
print("total - free                                \(gb(totalMinusFree))")
print("Activity Monitor (app+wired+compressed)     \(gb(activityMonitor))")
print("   of which app memory                      \(gb(appMem))")
print("   cached files (external+purgeable)        \(gb((UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page))")
