import SwiftUI

/// A small, general-purpose line chart. It knows nothing about containers, CPU, or memory —
/// just a series of optional doubles, oldest first.
///
/// Three rules make a sparkline honest rather than decorative noise, and this view exists to
/// hold them in one place so every caller gets them for free:
///
/// - **A `nil` is a gap, not a zero.** The line breaks across it rather than drawing through,
///   because closing the gap would claim a continuity that was never measured.
/// - **Fewer points than the frame renders as a shorter line, not a stretched one.** Sample
///   spacing is fixed, so a short history simply occupies less width rather than being
///   smeared across the whole view.
/// - **Zero or one point draws nothing.** A single sample cannot describe a trend, and a flat
///   line across an empty frame would imply one anyway.
struct Sparkline: View {
    /// Oldest → newest. `nil` is a gap in the data, not a zero.
    let values: [Double?]
    /// The value that maps to the top of the frame. `nil` scales to the data's own peak —
    /// the honest choice when the caller has no fixed ceiling to compare against (e.g. a
    /// per-core CPU percentage, which can run past 100).
    let maximum: Double?

    /// Fixed horizontal distance between adjacent samples. Deriving spacing from the view's
    /// width instead would stretch three points to fill the same frame as thirty, turning a
    /// sparse history into a misleadingly smooth-looking line.
    private static let pointSpacing: CGFloat = 3
    private static let lineWidth: CGFloat = 1.25

    var body: some View {
        Canvas { context, size in
            for run in Self.segments(values, maximum: maximum, size: size) {
                var path = Path()
                path.move(to: run[0])
                for point in run.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(path, with: .color(.secondary), lineWidth: Self.lineWidth)
            }
        }
        // The number beside a sparkline carries the meaning; the shape itself is
        // decoration and would just be noise read out to VoiceOver.
        .accessibilityHidden(true)
    }

    /// `values` normalised into `0...1`, `nil` preserved as a gap. Pulled out as a pure
    /// function so the normalising logic — the part most worth getting right — is testable
    /// independent of `Canvas` layout.
    static func normalized(_ values: [Double?], maximum: Double?) -> [Double?] {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return values }

        let peak = maximum ?? known.max() ?? 0
        // All-equal (including all-zero) data has no range to normalise against; every
        // known sample maps to the bottom of the frame rather than dividing by zero.
        guard peak > 0 else { return values.map { $0 == nil ? nil : 0 } }

        return values.map { value in
            guard let value else { return nil }
            return min(max(value / peak, 0), 1)
        }
    }

    /// Lays the most recent samples that fit `size` out as one or more contiguous point
    /// runs, split wherever a `nil` falls — the mechanism that keeps a gap from being drawn
    /// through. Anchored to the trailing edge, so the newest sample always sits flush with
    /// whatever value label the caller places beside the sparkline, and older samples fall
    /// off the leading edge once there are more than fit rather than being squeezed to fit.
    static func segments(_ values: [Double?], maximum: Double?, size: CGSize) -> [[CGPoint]] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }

        let capacity = max(2, Int(size.width / pointSpacing) + 1)
        let visible = Array(values.suffix(capacity))
        let scaled = normalized(visible, maximum: maximum)
        guard scaled.count >= 2 else { return [] }

        let usedWidth = CGFloat(scaled.count - 1) * pointSpacing
        let leadingOffset = size.width - usedWidth

        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, value) in scaled.enumerated() {
            guard let value else {
                if current.count > 1 { runs.append(current) }
                current = []
                continue
            }
            let x = leadingOffset + CGFloat(index) * pointSpacing
            let y = size.height * (1 - CGFloat(value))
            current.append(CGPoint(x: x, y: y))
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }
}
