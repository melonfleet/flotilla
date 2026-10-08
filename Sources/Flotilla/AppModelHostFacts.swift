import Foundation
import FlotillaCore
import FlotillaNet

/// What Overview's Hosts table shows for each Mac (the owner, 8 October): chip, memory, disk, OS.
/// This Mac reads its own; a host answers the same question with a `.hostFacts` call.
extension AppModel {
    /// This Mac's facts, now. Memory and CPU come from the sampler the dashboard already runs;
    /// before its first sample, memory falls back to the installed total alone.
    func localHostFacts() -> HostFacts {
        let latest = hostMetrics.latest
        let root = URL(fileURLWithPath: "/")
        let volume = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey])
        return HostFacts(chip: Self.sysctlString("machdep.cpu.brand_string"),
                         cores: Self.sysctlInt("hw.ncpu"),
                         model: Self.sysctlString("hw.model"),
                         macOSVersion: Self.macOSVersion,
                         memoryTotalBytes: latest?.memoryTotalBytes ?? Self.sysctlInt64("hw.memsize"),
                         memoryUsedBytes: latest?.memoryUsedBytes,
                         cpuPercent: latest?.cpuPercent,
                         diskTotalBytes: volume?.volumeTotalCapacity.map(Int64.init),
                         diskFreeBytes: volume?.volumeAvailableCapacityForImportantUsage)
    }

    /// A Mac's facts: This Mac's own, or the last a host sent.
    func hostFacts(on host: HostRef) -> HostFacts? {
        switch host {
        case .local: localHostFacts()
        case .peer(let fingerprint): hostMode.facts[fingerprint]
        }
    }

    /// `26.6.2`, the way the Hosts table writes it.
    nonisolated static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    nonisolated private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    nonisolated private static func sysctlInt64(_ name: String) -> Int64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int64(clamping: value) : nil
    }
}
