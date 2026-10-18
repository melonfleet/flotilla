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
}
