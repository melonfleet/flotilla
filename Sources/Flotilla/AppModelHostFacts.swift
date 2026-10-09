import Foundation
import IOKit
import IOKit.ps
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
        var facts = HostFacts(chip: Self.sysctlString("machdep.cpu.brand_string"),
                              cores: Self.sysctlInt("hw.ncpu"),
                              model: Self.sysctlString("hw.model"),
                              macOSVersion: Self.macOSVersion,
                              memoryTotalBytes: latest?.memoryTotalBytes ?? Self.sysctlInt64("hw.memsize"),
                              memoryUsedBytes: latest?.memoryUsedBytes,
                              cpuPercent: latest?.cpuPercent,
                              diskTotalBytes: volume?.volumeTotalCapacity.map(Int64.init),
                              diskFreeBytes: volume?.volumeAvailableCapacityForImportantUsage)
        // The host page's inventory (the owner, 9 October): quick reads here, the rest from the
        // background cache.
        facts.readAt = Date()
        facts.bootTime = Self.bootTime
        let interfaces = Self.ipv4Interfaces
        facts.ipv4Addresses = interfaces.map { String($0.split(separator: "/")[0]) }
        facts.ipv4Interfaces = interfaces
        facts.timeZone = TimeZone.current.identifier
        facts.loginUser = NSUserName()
        let battery = Self.battery
        facts.hasBattery = battery.present
        facts.onBattery = battery.present ? battery.onBattery : nil
        facts.batteryPercent = battery.percent
        let app = Bundle.main.bundleURL
        facts.appPath = app.pathExtension == "app" ? app.path : nil
        facts.appOwnedByRoot = app.pathExtension == "app" ? !SelfUpdate.canReplaceItself : nil
        facts.role = hostMode.mode.rawValue
        facts.helper = Self.helperState
        facts.acceptsAdminUpdates = settingsStore[SettingsKeys.acceptAdminUpdates]
        facts.installsContainerItself = settingsStore[SettingsKeys.autoInstallRuntime]
        facts.kernelInstalled = preflight.map { if case .needsKernel = $0 { false } else { true } }
        if let slow = systemFacts {
            facts.serialNumber = slow.serialNumber
            facts.power = slow.power
            facts.fileVault = slow.fileVault
            facts.remoteLogin = slow.remoteLogin
            facts.screenSharing = slow.screenSharing
            facts.fileSharing = slow.fileSharing
            facts.helperVersion = slow.helperVersion
        }
        return facts
    }

    private static var helperState: HostDNSStatus.Helper {
        switch PrivilegedHelper.status {
        case .enabled: .enabled
        case .awaitingApproval: .awaitingApproval
        case .notInstalled: .notInstalled
        case .unavailable: .unavailable
        }
    }

    /// Reads the slower facts now, off the main actor.
    func refreshSystemFacts() async {
        var slow = await Task.detached { Self.readSlowSystemFacts() }.value
        slow.helperVersion = PrivilegedHelper.status == .enabled ? await PrivilegedHelper.runningVersion() : nil
        systemFacts = slow
    }

    func startSystemFactsWatch() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSystemFacts()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Serial number, power settings, FileVault, Remote Login and Screen Sharing — each from the
    /// tool that reports it without admin rights. Blocking: runs three short processes.
    nonisolated static func readSlowSystemFacts() -> HostFacts {
        var facts = HostFacts()
        facts.serialNumber = serialNumber
        facts.ipv4Interfaces = ipv4Interfaces
        facts.power = SystemReport.PowerSettings.parse(run("/usr/bin/pmset", ["-g"]))
        let vault = run("/usr/bin/fdesetup", ["isactive"]).trimmingCharacters(in: .whitespacesAndNewlines)
        facts.fileVault = vault == "true" ? true : vault == "false" ? false : nil
        facts.firewall = SystemReport.firewallEnabled(run(SystemReport.firewallTool, ["--getglobalstate"]))
        let services = run("/bin/launchctl", ["print-disabled", "system"])
        facts.remoteLogin = SystemReport.serviceEnabled(SystemReport.remoteLoginLabel, in: services) ?? false
        facts.screenSharing = SystemReport.serviceEnabled(SystemReport.screenSharingLabel, in: services) ?? false
        // File Sharing is absent from that list until it has been turned on once; a loaded SMB
        // service is the other sign it is on.
        facts.fileSharing = SystemReport.serviceEnabled(SystemReport.fileSharingLabel, in: services)
            ?? !run("/bin/launchctl", ["print", "system/\(SystemReport.fileSharingLabel)"]).isEmpty
        return facts
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data.prefix(64_000), as: UTF8.self)
    }

    nonisolated private static var serialNumber: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    nonisolated private static var bootTime: Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }

    /// IPv4 addresses on interfaces that are up, with their prefix (`10.20.4.17/23`) — loopback
    /// and virtual-machine bridges left out.
    nonisolated private static var ipv4Interfaces: [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var interfaces: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            // Not the bridges `container` and other virtual machines make for their guests: those
            // addresses are this Mac's own and no other Mac can reach them.
            let interface = String(cString: entry.ifa_name)
            if ["bridge", "vmenet", "anpi"].contains(where: { interface.hasPrefix($0) }) { continue }
            guard let text = numeric(address) else { continue }
            let prefix = entry.ifa_netmask.flatMap(prefixLength) ?? 24
            let item = "\(text)/\(prefix)"
            if !interfaces.contains(item) { interfaces.append(item) }
        }
        return interfaces
    }

    /// A netmask's prefix length. The kernel may trim a netmask's trailing zero bytes and say so
    /// in `sa_len`, so only that many bytes are copied over a zeroed address.
    nonisolated private static func prefixLength(_ mask: UnsafeMutablePointer<sockaddr>) -> Int? {
        var full = sockaddr_in()
        let length = min(Int(mask.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &full) { $0.copyMemory(from: UnsafeRawBufferPointer(start: mask, count: length)) }
        let bits = UInt32(bigEndian: full.sin_addr.s_addr)
        let ones = bits.nonzeroBitCount
        return bits == (ones == 0 ? 0 : ~UInt32(0) << UInt32(32 - ones)) ? ones : nil
    }

    nonisolated private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether there is a battery, whether the Mac is running on it, and its charge.
    nonisolated private static var battery: (present: Bool, onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, false, nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let percent = current.flatMap { c in maximum.map { m in m > 0 ? Int((Double(c) / Double(m) * 100).rounded()) : c } }
            return (true, onBattery, percent)
        }
        return (false, false, nil)
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
