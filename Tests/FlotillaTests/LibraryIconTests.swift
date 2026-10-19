import AppKit
import CryptoKit
import Foundation
import Testing
import FlotillaCore
@testable import Flotilla

@Suite struct LibraryIconTests {
    private func png(width: Int = 2, height: Int = 2) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func metadata(_ data: Data, file: String = "icons/test.png") -> LibraryIcon {
        .init(file: file, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
              bytes: data.count)
    }

    @Test func onlyMatchingDecodableBoundedPNGsPass() throws {
        let data = try png()
        let icon = metadata(data)
        #expect(LibraryUpdater.validIcon(data, metadata: icon))
        var corrupt = data; corrupt[corrupt.startIndex] ^= 1
        #expect(!LibraryUpdater.validIcon(corrupt, metadata: icon))
        var wrongSize = icon; wrongSize.bytes += 1
        #expect(!LibraryUpdater.validIcon(data, metadata: wrongSize))
        var wrongHash = icon; wrongHash.sha256 = String(repeating: "0", count: 64)
        #expect(!LibraryUpdater.validIcon(data, metadata: wrongHash))
        for invalid in [Data("not a PNG".utf8), Data(data.prefix(24)), try png(width: 513), try png(height: 513)] {
            #expect(!LibraryUpdater.validIcon(invalid, metadata: metadata(invalid)))
        }
        let maximum = try png(width: 512, height: 512)
        #expect(LibraryUpdater.validIcon(maximum, metadata: metadata(maximum)))
    }

    @Test @MainActor func everyCategoryHasAnAvailableFallbackSymbol() {
        #expect(Set(SuggestionLogo.categorySymbols.keys) == Set(SuggestionLibrary.categories))
        for symbol in SuggestionLogo.categorySymbols.values {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test @MainActor func distributionAndRegistryLogosDownloadReloadAndSurviveCacheSweep() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let staleURL = folder.appendingPathComponent("icon-\(String(repeating: "0", count: 64)).png")
        try Data("stale".utf8).write(to: staleURL)

        let entryBytes = try png(width: 3, height: 3)
        let alpineBytes = try png(width: 2, height: 2)
        let tuxBytes = try png(width: 4, height: 4)
        let k8sBytes = try png(width: 6, height: 6)
        let entryIcon = metadata(entryBytes, file: "icons/redis.png")
        let alpineIcon = metadata(alpineBytes, file: "icons/alpine.png")
        let tuxIcon = metadata(tuxBytes, file: "icons/tux.png")
        let k8sIcon = metadata(k8sBytes, file: "icons/k8s.png")

        let entry = LibraryEntry(
            id: "redis", title: "Redis", summary: "In-memory store.",
            categories: ["Databases"], kind: .container,
            tested: .init(date: "2026-10-18", macs: 1),
            container: .init(image: "docker.io/library/redis:7.4", name: "redis"),
            icon: entryIcon
        )
        let library = SuggestionLibrary(
            version: "2026.10.18.2",
            entries: [entry],
            artwork: [
                LibraryArtwork(id: "distro.alpine", icon: alpineIcon),
                LibraryArtwork(id: "distro.fallback", icon: tuxIcon,
                               attribution: "Tux by Larry Ewing, Simon Budig and Garrett LeSage (CC0)"),
                LibraryArtwork(id: "registry.registry.k8s.io", icon: k8sIcon,
                               attribution: "Kubernetes logo — The Linux Foundation"),
            ]
        )

        let served: [String: Data] = [
            entryIcon.file: entryBytes,
            alpineIcon.file: alpineBytes,
            tuxIcon.file: tuxBytes,
            k8sIcon.file: k8sBytes,
        ]
        let suite = "dev.melonfleet.Flotilla.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let updater = LibraryUpdater(defaults: defaults, cacheDirectory: folder)
        updater.fetchOverride = { name, _ in
            guard let bytes = served[name] else {
                throw LibraryUpdater.Failure("GitHub didn't have \(name) (HTTP 404).")
            }
            return bytes
        }
        await updater.updateIcons(library)

        let alpineMachine = ContainerMachine(
            id: "fx-machine", status: "running", cpus: 8, memory: 34_359_738_368, diskSize: 1_169_276_928,
            image: .init(reference: "docker.io/library/alpine:3.22")
        )
        let unknownMachine = ContainerMachine(
            id: "custom", status: "running", cpus: 2, memory: 2_147_483_648, diskSize: 1_073_741_824,
            image: .init(reference: "scratch:latest")
        )
        let uninspectedMachine = ContainerMachine(
            id: "thin", status: "stopped", cpus: 2, memory: 2_147_483_648, diskSize: 1_073_741_824
        )

        #expect(updater.icons[entryIcon.sha256] == entryBytes)
        #expect(AppModel.distributionLogo(for: alpineMachine, in: library, icons: updater.icons) == alpineBytes)
        #expect(AppModel.distributionLogo(for: unknownMachine, in: library, icons: updater.icons) == tuxBytes)
        #expect(AppModel.distributionLogo(for: uninspectedMachine, in: library, icons: updater.icons) == tuxBytes)
        #expect(AppModel.distributionLogo(for: unknownMachine, in: library, icons: [:]) == nil)

        #expect(AppModel.registryLogo(for: "registry.k8s.io", in: library, icons: updater.icons) == k8sBytes)
        #expect(AppModel.registryLogo(for: "REGISTRY.K8S.IO", in: library, icons: updater.icons) == k8sBytes)
        #expect(AppModel.registryLogo(for: "docker.io", in: library, icons: updater.icons) == nil)

        // Cache retention keeps both entry and artwork PNGs and removes unreferenced ones.
        let cachedFiles = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        let expectedFiles = Set([entryIcon, alpineIcon, tuxIcon, k8sIcon].map { "icon-\($0.sha256).png" })
        #expect(cachedFiles == expectedFiles)
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))

        // Cache loading on a fresh updater reloads both entry and artwork PNGs from disk.
        let reloaded = LibraryUpdater(defaults: defaults, cacheDirectory: folder)
        await reloaded.loadIcons(for: library)
        #expect(reloaded.icons == updater.icons)
        #expect(AppModel.distributionLogo(for: alpineMachine, in: library, icons: reloaded.icons) == alpineBytes)
        #expect(AppModel.distributionLogo(for: unknownMachine, in: library, icons: reloaded.icons) == tuxBytes)
        #expect(AppModel.registryLogo(for: "registry.k8s.io", in: library, icons: reloaded.icons) == k8sBytes)

        #expect(AboutView.logoLines(for: library) == [
            "Logos are trademarks of their owners and identify the software they name.",
            "Tux by Larry Ewing, Simon Budig and Garrett LeSage (CC0)",
            "Kubernetes logo — The Linux Foundation",
        ])
    }
}

private final class ScriptedMachineHost: ContainerHost, @unchecked Sendable {
    private let lock = NSLock()
    var listedIDs: [String]
    var inspectOutcomes: [String: [Result<String, ContainerCLIError>]]
    var inspectGate: DispatchSemaphore?
    var inspectEntered: DispatchSemaphore?
    var concurrencyBarrierCount = 0
    private let barrierEntered = DispatchSemaphore(value: 0)
    private let barrierRelease = DispatchSemaphore(value: 0)
    private(set) var inspectCounts: [String: Int] = [:]
    private var activeInspections = 0
    private(set) var maxConcurrentInspections = 0

    init(listedIDs: [String], inspectOutcomes: [String: [Result<String, ContainerCLIError>]]) {
        self.listedIDs = listedIDs
        self.inspectOutcomes = inspectOutcomes
    }

    func waitForBarrierEntries(_ count: Int) {
        for _ in 0..<count { barrierEntered.wait() }
    }

    func releaseBarrier(_ count: Int) {
        for _ in 0..<count { barrierRelease.signal() }
    }

    func run(_ args: [String]) throws -> CommandResult {
        if args == ["machine", "list", "--format", "json"] {
            let ids = lock.withLock { listedIDs }
            let rows = ids.map { id in
                #"{"id":"\#(id)","status":"running","cpus":2,"memory":2147483648,"diskSize":1073741824,"default":false}"#
            }.joined(separator: ",")
            return CommandResult(stdout: "[\(rows)]", stderr: "", exitCode: 0)
        }
        if args.count == 3, args[0] == "machine", args[1] == "inspect" {
            let id = args[2]
            let (gate, entered, useBarrier, outcome): (DispatchSemaphore?, DispatchSemaphore?, Bool, Result<String, ContainerCLIError>) = lock.withLock {
                activeInspections += 1
                maxConcurrentInspections = max(maxConcurrentInspections, activeInspections)
                let attempt = inspectCounts[id, default: 0]
                inspectCounts[id] = attempt + 1
                let list = inspectOutcomes[id] ?? [.failure(.commandFailed(command: "machine inspect \(id)", exitCode: 1, message: "unconfigured"))]
                let picked = list[min(attempt, list.count - 1)]
                let barrier = concurrencyBarrierCount > 0
                if barrier { concurrencyBarrierCount -= 1 }
                return (inspectGate, inspectEntered, barrier, picked)
            }
            defer {
                lock.withLock { activeInspections -= 1 }
            }
            entered?.signal()
            gate?.wait()
            if useBarrier {
                barrierEntered.signal()
                barrierRelease.wait()
            }
            let image = try outcome.get()
            let json = #"[{"id":"\#(id)","status":"running","cpus":2,"memory":2147483648,"diskSize":1073741824,"image":{"reference":"\#(image)"}}]"#
            return CommandResult(stdout: json, stderr: "", exitCode: 0)
        }
        return CommandResult(stdout: "[]", stderr: "", exitCode: 0)
    }
}

@Suite @MainActor struct MachineInspectionPollingTests {
    @Test(.timeLimit(.minutes(1))) func failingInspectionDoesNotDelayMachineList() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let host = ScriptedMachineHost(
            listedIDs: ["alpine-vm", "broken-vm"],
            inspectOutcomes: [
                "alpine-vm": [.success("docker.io/library/alpine:3.22")],
                "broken-vm": [.failure(.timedOut(command: "machine inspect broken-vm", seconds: 30))],
            ]
        )
        host.inspectGate = gate
        host.inspectEntered = entered

        let model = AppModel(cli: ContainerCLI(host: host, wirePolicy: .localOwner),
                             settingsStore: SettingsStore())
        await model.refreshMachines()

        // The list is published immediately, while both inspections are still blocked on `gate`.
        #expect(model.machinesState == .loaded)
        #expect(model.machines.map(\.id) == ["alpine-vm", "broken-vm"])
        #expect(model.machines.allSatisfy { $0.image == nil })

        await Blocking.run {
            entered.wait()
            entered.wait()
            gate.signal()
            gate.signal()
        }
        await model.machineImageTask?.value

        #expect(model.machines.first { $0.id == "alpine-vm" }?.distribution == .alpine)
        #expect(model.machines.first { $0.id == "broken-vm" }?.image == nil)
    }

    @Test(.timeLimit(.minutes(1))) func inspectionsAreBoundedCachedPerMachineAndBackedOffOnFailure() async throws {
        let host = ScriptedMachineHost(
            listedIDs: ["m1", "m2", "m3", "m4"],
            inspectOutcomes: [
                "m1": [.success("docker.io/library/alpine:3.22")],
                "m2": [.success("docker.io/library/debian:12")],
                "m3": [.success("docker.io/library/ubuntu:24.04")],
                "m4": [
                    .failure(.commandFailed(command: "machine inspect m4", exitCode: 1, message: "busy")),
                    .success("registry.fedoraproject.org/fedora:41"),
                ],
            ]
        )
        host.concurrencyBarrierCount = AppModel.maxConcurrentMachineInspections

        var now = Date(timeIntervalSince1970: 1_792_000_000)
        let model = AppModel(cli: ContainerCLI(host: host, wirePolicy: .localOwner),
                             settingsStore: SettingsStore())
        model.machineImageNow = { now }

        await model.refreshMachines()
        #expect(model.machines.map(\.id) == ["m1", "m2", "m3", "m4"])

        await Blocking.run {
            host.waitForBarrierEntries(AppModel.maxConcurrentMachineInspections)
            host.releaseBarrier(AppModel.maxConcurrentMachineInspections)
        }
        await model.machineImageTask?.value

        #expect(host.maxConcurrentInspections == AppModel.maxConcurrentMachineInspections)
        #expect(host.inspectCounts == ["m1": 1, "m2": 1, "m3": 1, "m4": 1])
        #expect(model.machines.first { $0.id == "m1" }?.distribution == .alpine)
        #expect(model.machines.first { $0.id == "m2" }?.distribution == .debian)
        #expect(model.machines.first { $0.id == "m3" }?.distribution == .ubuntu)
        #expect(model.machines.first { $0.id == "m4" }?.image == nil)

        // Next poll 10s later: cached machines are not re-inspected, and `m4` is in backoff.
        now = now.addingTimeInterval(10)
        await model.refreshMachines()
        await model.machineImageTask?.value
        #expect(host.inspectCounts == ["m1": 1, "m2": 1, "m3": 1, "m4": 1])
        #expect(model.machines.first { $0.id == "m1" }?.distribution == .alpine)

        // Past the 60s first-failure backoff: only `m4` is retried, and now succeeds.
        now = now.addingTimeInterval(60)
        await model.refreshMachines()
        await model.machineImageTask?.value
        #expect(host.inspectCounts == ["m1": 1, "m2": 1, "m3": 1, "m4": 2])
        #expect(model.machines.first { $0.id == "m4" }?.distribution == .fedora)

        // Removing machines drops their cached image entries.
        host.listedIDs = ["m2", "m3"]
        await model.refreshMachines()
        #expect(model.machines.map(\.id) == ["m2", "m3"])
        #expect(model.machineImages.keys.sorted() == ["m2", "m3"])
    }
}
