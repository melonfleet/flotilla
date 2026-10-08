import Foundation

/// Björn Ottosson's OKLab, as much of it as the themes need: sRGB `0xRRGGBB` in and out.
///
/// It is here for **the matte finish** (the owner, 5 October): every theme's bar and body are the
/// brand colour with 15% of its OKLCH chroma taken out. OKLCH's chroma is the length of OKLab's
/// (a, b), so scaling a and b together scales chroma and leaves lightness and hue alone, which is
/// what made it the finish that kept contrast. The colours stay the brand's hues, only softer.
///
/// In `FlotillaCore` rather than beside the palette because it is arithmetic with rules worth
/// pinning, and the app target has no tests; it knows nothing about drawing.
public struct OKLab: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    public init(hex: Int) {
        func linear(_ c: Int) -> Double {
            let x = Double(c) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = linear((hex >> 16) & 0xFF), g = linear((hex >> 8) & 0xFF), bl = linear(hex & 0xFF)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    /// Back to sRGB, clamped into gamut and rounded to the nearest 8-bit value.
    public var hex: Int {
        let lc = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let mc = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let sc = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        func gamma(_ x: Double) -> Int {
            let c = min(max(x, 0), 1)
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return Int((v * 255).rounded())
        }
        return gamma(r) << 16 | gamma(g) << 8 | gamma(bl)
    }

    /// `hex` with its chroma scaled by `kept` (0…1), lightness and hue unchanged.
    public static func scalingChroma(of hex: Int, by kept: Double) -> Int {
        var lab = OKLab(hex: hex)
        lab.a *= kept
        lab.b *= kept
        return lab.hex
    }

    /// The share of chroma the matte finish keeps. Chosen by the owner from screenshots of 0.85
    /// and 0.70, with and without grain (5 October): 0.85, no grain.
    public static let matteChromaKept = 0.85

    /// A theme colour with the matte finish.
    public static func matte(_ hex: Int) -> Int {
        scalingChroma(of: hex, by: matteChromaKept)
    }
}
