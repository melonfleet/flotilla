import SwiftUI

/// A titled panel on a detail screen — the same panel the Dashboard draws.
///
/// There were two copies of this, one private to `ContainerDetailView` and one private to
/// `MachineDetailView`, identical line for line down to the corner radius. Both drew the app's
/// *other* panel style: the heading in small caps **inside** the box, on `.background.secondary`
/// with a `.separator` border, rather than the heading above a `Theme.raisedSurface` card with a
/// `Theme.hairline` border that every other screen uses.
///
/// That style was already ruled on once. The Dashboard's attention panel was "the last user of a
/// second panel style — small caps inside a box, on a different surface with a different border —
/// which is two ways of drawing a panel on one screen", and the utilisation panel's heading was
/// moved out of its box on the owner's instruction: *"remove it out of the box and put it above
/// the box just as the other sections have."* It was not the last user; these two were still
/// there, one screen away.
///
/// Shared rather than fixed twice, because two private copies is exactly how the two drifted from
/// everything else and then stayed there.
struct DetailCard<Content: View>: View {
    let title: String
    /// Squares off a grid of cards so neighbours in a row match. `nil` lets the card be as tall
    /// as its content — for the full-width ones whose height should follow what is in them.
    ///
    /// A parameter, because the container view decided this by comparing the title against the
    /// literal `"Recent events"`: a rename would have silently squared off the one card that must
    /// not be, and nothing would have failed.
    var minHeight: CGFloat? = 128
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // `.headline`, the same weight the Dashboard's Pressure/Throughput/Resources
            // headings use, so a panel title reads the same on every screen.
            Text(title).font(.headline)

            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Theme.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }
}
