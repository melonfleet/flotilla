import Foundation
import Testing
@testable import FlotillaCore

// The matte finish (`design/THEMES.md`, 5 October): every theme's bar and body are the brand colour
// with 15% of its OKLCH chroma removed. These pin the values THEMES.md documents, so the doc and the
// window cannot drift apart.

@Test func keepingAllTheChromaChangesNothing() {
    // A round trip through OKLab must be lossless at 8 bits, or every theme would shift a little
    // for no reason.
    for hex in [0x7CB342, 0xFC4A6B, 0xEE7B4D, 0xF2C94C, 0xFBF7F0, 0xE5F4DC, 0x241F1A, 0x000000, 0xFFFFFF] {
        #expect(OKLab.scalingChroma(of: hex, by: 1) == hex)
    }
}

@Test func theMatteBrandColoursAreTheOnesTheDocumentsName() {
    #expect(OKLab.matteChromaKept == 0.85)
    // Bars.
    #expect(OKLab.matte(0x7CB342) == 0x82B155)   // stripe
    #expect(OKLab.matte(0xFC4A6B) == 0xEF5C72)   // flesh
    #expect(OKLab.matte(0xEE7B4D) == 0xE4825C)   // cantaloupe
    #expect(OKLab.matte(0xF2C94C) == 0xEDCA67)   // canary
    // Bodies.
    #expect(OKLab.matte(0xFBF7F0) == 0xFAF7F1)   // cream
    #expect(OKLab.matte(0xE5F4DC) == 0xE6F3DF)   // honeydew wash
    #expect(OKLab.matte(0x241F1A) == 0x231F1B)   // seed
}

@Test func removingChromaKeepsLightnessAndLeavesGreyGrey() {
    let stripe = OKLab(hex: 0x7CB342), matte = OKLab(hex: OKLab.matte(0x7CB342))
    // Lightness within 8-bit rounding, which is why contrast does not move.
    #expect(abs(stripe.l - matte.l) < 0.005)
    // Less saturated, not a different colour.
    #expect(hypot(matte.a, matte.b) < hypot(stripe.a, stripe.b))
    // A neutral has no chroma to remove.
    #expect(OKLab.matte(0x808080) == 0x808080)
}
