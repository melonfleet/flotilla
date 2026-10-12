import SwiftUI

/// A line drawing of a flotilla on a calm sea, behind Get started (the owner, 12 October): thin
/// outlines in a faint grey, so the text and buttons in front read exactly as before. Drawn rather
/// than shipped as an image, like the wordmark — it stays sharp at any size and follows light and
/// dark from the one colour.
struct FlotillaSeascape: View {
    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(.secondary.opacity(0.22))
            let thin = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            let w = size.width, h = size.height

            // The sea: three long, gentle swells, the nearest lowest and fullest.
            let swells: [(y: CGFloat, amplitude: CGFloat, length: CGFloat, phase: CGFloat)] = [
                (0.70, 3, 140, 0), (0.80, 4, 180, 1.3), (0.91, 5, 230, 2.4),
            ]
            for swell in swells {
                context.stroke(wave(width: w, y: h * swell.y, amplitude: swell.amplitude,
                                    length: swell.length, phase: swell.phase), with: ink, style: thin)
            }

            // The flotilla: near boats larger and lower, far ones small and higher, spread across.
            let boats: [(x: CGFloat, y: CGFloat, scale: CGFloat, flip: Bool)] = [
                // Either side of the middle, where the text and buttons are.
                (0.06, 0.80, 1.00, false), (0.16, 0.70, 0.62, true), (0.245, 0.66, 0.45, false),
                (0.765, 0.67, 0.50, true), (0.855, 0.71, 0.70, false), (0.95, 0.81, 0.95, true),
            ]
            for boat in boats {
                let base = CGPoint(x: w * boat.x, y: h * boat.y)
                context.stroke(sailboat(at: base, scale: boat.scale * min(1.4, max(0.7, h / 220)), flip: boat.flip),
                               with: ink, style: thin)
            }

            // Two birds, far off.
            for bird in [(x: 0.58, y: 0.18, s: 1.0), (x: 0.63, y: 0.24, s: 0.7)] {
                context.stroke(gull(at: CGPoint(x: w * bird.x, y: h * bird.y), span: 9 * bird.s), with: ink, style: thin)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func wave(width: CGFloat, y: CGFloat, amplitude: CGFloat, length: CGFloat, phase: CGFloat) -> Path {
        var path = Path()
        let step: CGFloat = 4
        path.move(to: CGPoint(x: 0, y: y + amplitude * sin(phase)))
        var x: CGFloat = step
        while x <= width {
            path.addLine(to: CGPoint(x: x, y: y + amplitude * sin(phase + x / length * 2 * .pi)))
            x += step
        }
        return path
    }

    /// A small sailboat: a hull with a sheer, a mast, a mainsail and a jib. `base` is the waterline.
    private func sailboat(at base: CGPoint, scale s: CGFloat, flip: Bool) -> Path {
        var path = Path()
        let d: CGFloat = flip ? -1 : 1
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x * s * d, y: base.y + y * s) }
        // Hull.
        path.move(to: p(-26, -6))
        path.addLine(to: p(28, -6))
        path.addQuadCurve(to: p(16, 2), control: p(26, 1))
        path.addLine(to: p(-18, 2))
        path.addQuadCurve(to: p(-26, -6), control: p(-24, 1))
        // Mast.
        path.move(to: p(0, -6))
        path.addLine(to: p(0, -58))
        // Mainsail, aft of the mast.
        path.move(to: p(-2, -55))
        path.addQuadCurve(to: p(-22, -10), control: p(-16, -34))
        path.addLine(to: p(-2, -10))
        // Jib, forward.
        path.move(to: p(2, -52))
        path.addLine(to: p(22, -9))
        path.addLine(to: p(2, -9))
        // A pennant.
        path.move(to: p(0, -58))
        path.addLine(to: p(7, -55))
        path.addLine(to: p(0, -53))
        return path
    }

    private func gull(at center: CGPoint, span: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - span, y: center.y))
        path.addQuadCurve(to: center, control: CGPoint(x: center.x - span / 2, y: center.y - span / 2))
        path.addQuadCurve(to: CGPoint(x: center.x + span, y: center.y), control: CGPoint(x: center.x + span / 2, y: center.y - span / 2))
        return path
    }
}
