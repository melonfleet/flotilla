import SwiftUI
import Testing
@testable import Flotilla

@Suite struct ResourceRowLayoutTests {
    // Name, chips, detail, optional third line, time. Taller chips exercise the height invariant.
    private let metrics = [CGSize(width: 150, height: 16), CGSize(width: 80, height: 19),
                           CGSize(width: 900, height: 14), CGSize(width: 200, height: 12),
                           CGSize(width: 60, height: 12)]

    @Test func dividerWidthSwitchesAndPreservesTheName() {
        let layout = ResourceTextLayout(reservesActions: true)
        let narrow = layout.frames(width: 659, ideal: metrics) { min($0, 80) }
        let wide = layout.frames(width: 660, ideal: metrics) { min($0, 80) }
        #expect(narrow[2].minY >= narrow[0].maxY)
        #expect(narrow[3].minY >= narrow[2].maxY)
        #expect(wide[2].minY < wide[0].maxY)
        #expect(wide[0].width == metrics[0].width)
        #expect(wide[4].maxX <= 660 - 80) // Room for the hover actions even at rest.
        for pair in zip(wide, wide.dropFirst()) {
            #expect(pair.0.maxX <= pair.1.minX)
        }
    }

    @Test func longNameWaitsForEnoughRoom() {
        var long = metrics
        long[0].width = 600
        let layout = ResourceTextLayout(reservesActions: true)
        let narrow = layout.frames(width: 760, ideal: long) { _ in 0 }
        let wide = layout.frames(width: 1000, ideal: long) { min($0, 80) }
        #expect(narrow[2].minY >= narrow[0].maxY)
        #expect(wide[2].minY < wide[0].maxY)
        #expect(wide[0].width == 600)
    }

    @Test func droppingChipsDoesNotChangeHeightWithinEitherLayout() {
        let layout = ResourceTextLayout(reservesActions: true)
        for width in [CGFloat(300), 660] {
            let shown = layout.frames(width: width, ideal: metrics) { min($0, 80) }
            let dropped = layout.frames(width: width + 20, ideal: metrics) { _ in 0 }
            #expect(shown.map(\.maxY).max() == dropped.map(\.maxY).max())
        }
    }

    @Test func absentThirdLineTakesNoHeight() {
        var twoLines = metrics
        twoLines[3] = .zero
        let frames = ResourceTextLayout(reservesActions: false)
            .frames(width: 300, ideal: twoLines) { min($0, 80) }
        #expect(frames[3].height == 0)
        #expect(frames.filter { $0.height > 0 }.map(\.maxY).max() == frames[2].maxY)
    }
}
