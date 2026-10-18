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

    private func metadata(_ data: Data) -> LibraryIcon {
        .init(file: "icons/test.png", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
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

    @Test func distributionAndRegistryLogosResolveAndFallBackToTux() throws {
        let alpineBytes = try png(width: 2, height: 2)
        let tuxBytes = try png(width: 4, height: 4)
        let k8sBytes = try png(width: 6, height: 6)
        let alpineIcon = metadata(alpineBytes)
        let tuxIcon = metadata(tuxBytes)
        let k8sIcon = metadata(k8sBytes)
        let library = SuggestionLibrary(
            version: "2026.10.18.2",
            entries: [],
            artwork: [
                LibraryArtwork(id: "distro.alpine", icon: alpineIcon),
                LibraryArtwork(id: "distro.fallback", icon: tuxIcon,
                               attribution: "Tux by Larry Ewing, Simon Budig and Garrett LeSage (CC0)"),
                LibraryArtwork(id: "registry.registry.k8s.io", icon: k8sIcon,
                               attribution: "Kubernetes logo — The Linux Foundation"),
            ]
        )
        let icons = [
            alpineIcon.sha256: alpineBytes,
            tuxIcon.sha256: tuxBytes,
            k8sIcon.sha256: k8sBytes,
        ]

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

        #expect(AppModel.distributionLogo(for: alpineMachine, in: library, icons: icons) == alpineBytes)
        #expect(AppModel.distributionLogo(for: unknownMachine, in: library, icons: icons) == tuxBytes)
        #expect(AppModel.distributionLogo(for: uninspectedMachine, in: library, icons: icons) == tuxBytes)
        #expect(AppModel.distributionLogo(for: unknownMachine, in: library, icons: [:]) == nil)

        #expect(AppModel.registryLogo(for: "registry.k8s.io", in: library, icons: icons) == k8sBytes)
        #expect(AppModel.registryLogo(for: "REGISTRY.K8S.IO", in: library, icons: icons) == k8sBytes)
        #expect(AppModel.registryLogo(for: "docker.io", in: library, icons: icons) == nil)

        #expect(AboutView.logoLines(for: library) == [
            "Logos are trademarks of their owners and identify the software they name.",
            "Tux by Larry Ewing, Simon Budig and Garrett LeSage (CC0)",
            "Kubernetes logo — The Linux Foundation",
        ])
    }
}
