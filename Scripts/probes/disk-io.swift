// Host-wide disk I/O — the evidence behind `HostMetricsSampler`'s disk rate fields.
//
// Walks the IOService registry for every `IOBlockStorageDriver` node (one per physical
// drive), reads its `Statistics` dictionary, and sums `Bytes (Read)` / `Bytes (Write)`
// across drives. Those are cumulative counters since boot, so a rate needs two samples one
// second apart — same shape as the CPU tick and network byte counters already in
// `HostMetrics.swift`.
//
// Run while generating real disk load and cross-check against `iostat -d 1`:
//
//   swiftc -O -o /tmp/diskio Scripts/probes/disk-io.swift && /tmp/diskio
//
// in one terminal, and in another:
//
//   iostat -d 1
//
// and in a third, to generate load:
//
//   dd if=/dev/zero of=/tmp/probe bs=1m count=2000; sync; rm /tmp/probe
import Foundation
import IOKit
import IOKit.storage

func readDiskBytes() -> (read: UInt64, written: UInt64) {
    var read: UInt64 = 0
    var written: UInt64 = 0

    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching(kIOBlockStorageDriverClass)
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return (0, 0)
    }
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

setvbuf(stdout, nil, _IOLBF, 0)

print("Sampling host-wide disk I/O once a second. Ctrl-C to stop.")
print("Cross-check with `iostat -d 1` in another terminal.")
print("")

var previous = readDiskBytes()
var previousDate = Date()

while true {
    Thread.sleep(forTimeInterval: 1.0)
    let now = Date()
    let current = readDiskBytes()
    let elapsed = now.timeIntervalSince(previousDate)

    if elapsed > 0, current.read >= previous.read, current.written >= previous.written {
        let readRate = Double(current.read - previous.read) / elapsed
        let writeRate = Double(current.written - previous.written) / elapsed
        print(String(format: "disk:  read %8.2f MB/s   write %8.2f MB/s",
                     readRate / 1_000_000, writeRate / 1_000_000))
    } else {
        print("disk:  (counters wrapped or reset)")
    }

    previous = current
    previousDate = now
}
