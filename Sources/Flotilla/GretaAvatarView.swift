import SwiftUI
import FlotillaCore

/// Greta's face (the owner, 12 October): six drawn styles in the watermelon palette — the flower
/// by default, the rest in Settings. Drawn rather than shipped as images, like the wordmark, so one
/// view serves a 16pt button and a 64pt header.
struct GretaAvatarView: View {
    let style: GretaAvatar
    var size: CGFloat = 32

    /// The drawings are made on a 140pt canvas and scaled.
    private static let canvas: CGFloat = 140

    var body: some View {
        drawing
            .frame(width: Self.canvas, height: Self.canvas)
            .scaleEffect(size / Self.canvas)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Greta")
    }

    @ViewBuilder
    private var drawing: some View {
        switch style {
        case .flower:
            VStack(spacing: 0) {
                Antenna { Daisy() }
                GretaFace(fill: Palette.mint, lashes: true, stroke: Palette.rind)
            }
        case .bow:
            VStack(spacing: -6) { Bow(); GretaFace(fill: Palette.fleshLight) }
        case .heart:
            VStack(spacing: 0) {
                Antenna { Heart().fill(Palette.flesh).frame(width: 22, height: 20) }
                GretaFace(fill: .white, lashes: true, stroke: Palette.rind)
            }
        case .lashes:
            GretaFace(fill: Palette.blush.opacity(0.9), lashes: true, happy: true)
        case .sailor:
            VStack(spacing: -10) {
                ZStack {
                    Capsule().fill(.white).frame(width: 96, height: 30).overlay(Capsule().stroke(Palette.seed, lineWidth: 3))
                    Rectangle().fill(Palette.rind).frame(width: 92, height: 7).offset(y: 8)
                    Circle().fill(Palette.fleshDeep).frame(width: 12).offset(y: -15)
                }
                .zIndex(1)
                GretaFace(fill: Palette.fleshLight, lashes: true)
            }
        case .watermelon:
            ZStack {
                RoundedRectangle(cornerRadius: 40).fill(Palette.rind).frame(width: 122, height: 104)
                RoundedRectangle(cornerRadius: 34).fill(Palette.stripe).frame(width: 114, height: 96)
                RoundedRectangle(cornerRadius: 30).fill(Palette.flesh).frame(width: 102, height: 84)
                VStack(spacing: 6) {
                    HStack(spacing: 30) {
                        Ellipse().fill(Palette.seed).frame(width: 11, height: 17)
                        Ellipse().fill(Palette.seed).frame(width: 11, height: 17)
                    }
                    Smile(colour: .white)
                }
                .offset(y: 4)
                HStack(spacing: 56) {
                    Circle().fill(Palette.fleshLight).frame(width: 12)
                    Circle().fill(Palette.fleshLight).frame(width: 12)
                }
                .offset(y: 16)
            }
        }
    }
}

/// The watermelon palette (design/branding.md), plus the face's own blush and the daisy's centre.
private enum Palette {
    static let flesh = Color(red: 0xFC / 255, green: 0x4A / 255, blue: 0x6B / 255)
    static let fleshLight = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0xA3 / 255)
    static let fleshDeep = Color(red: 0xE6 / 255, green: 0x39 / 255, blue: 0x56 / 255)
    static let rind = Color(red: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255)
    static let stripe = Color(red: 0x7C / 255, green: 0xB3 / 255, blue: 0x42 / 255)
    static let seed = Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)
    static let blush = Color(red: 0xFF / 255, green: 0xC2 / 255, blue: 0xCF / 255)
    static let mint = Color(red: 0xE8 / 255, green: 0xF5 / 255, blue: 0xE9 / 255)
    static let daisyCentre = Color(red: 0xFF / 255, green: 0xC9 / 255, blue: 0x4D / 255)
}

private struct GretaFace: View {
    var fill: Color
    var lashes = false
    var happy = false
    var stroke: Color = Palette.seed

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34).fill(fill).frame(width: 110, height: 92)
                .overlay(RoundedRectangle(cornerRadius: 34).stroke(stroke, lineWidth: 3))
            VStack(spacing: 6) { Eyes(lashes: lashes, happy: happy); Smile(colour: Palette.seed) }.offset(y: 4)
            HStack(spacing: 56) {
                Ellipse().fill(Palette.blush).frame(width: 16, height: 10)
                Ellipse().fill(Palette.blush).frame(width: 16, height: 10)
            }
            .offset(y: 14)
        }
    }
}

private struct Eyes: View {
    var lashes: Bool
    var happy: Bool

    var body: some View {
        HStack(spacing: 30) {
            ForEach(0..<2, id: \.self) { side in
                ZStack {
                    if happy {
                        Path { $0.addArc(center: CGPoint(x: 9, y: 12), radius: 8, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false) }
                            .stroke(Palette.seed, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .frame(width: 18, height: 14)
                    } else {
                        Capsule().fill(Palette.seed).frame(width: 12, height: 18)
                        Circle().fill(.white).frame(width: 4).offset(x: 2, y: -4)
                    }
                    if lashes {
                        Path { path in
                            let dx: CGFloat = side == 0 ? -1 : 1
                            path.move(to: CGPoint(x: 9 + dx * 6, y: 2)); path.addLine(to: CGPoint(x: 9 + dx * 11, y: -4))
                            path.move(to: CGPoint(x: 9 + dx * 2, y: 0)); path.addLine(to: CGPoint(x: 9 + dx * 4, y: -7))
                        }
                        .stroke(Palette.seed, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 18, height: 20)
            }
        }
    }
}

private struct Smile: View {
    var colour: Color
    var body: some View {
        Path { $0.addArc(center: CGPoint(x: 12, y: 2), radius: 9, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false) }
            .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: 24, height: 12)
    }
}

private struct Antenna<Top: View>: View {
    @ViewBuilder var top: Top
    var body: some View {
        VStack(spacing: 0) { top; Rectangle().fill(Palette.seed).frame(width: 3, height: 16) }
    }
}

private struct Daisy: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { petal in
                Ellipse().fill(.white).overlay(Ellipse().stroke(Palette.seed, lineWidth: 1.5))
                    .frame(width: 9, height: 16).offset(y: -8)
                    .rotationEffect(.degrees(Double(petal) * 60))
            }
            Circle().fill(Palette.daisyCentre).frame(width: 10)
        }
        .frame(width: 30, height: 30)
    }
}

private struct Bow: View {
    var body: some View {
        ZStack {
            Path { $0.move(to: CGPoint(x: 30, y: 20)); $0.addCurve(to: CGPoint(x: 30, y: 20), control1: CGPoint(x: -4, y: -6), control2: CGPoint(x: -4, y: 46)) }
                .fill(Palette.fleshDeep)
            Path { $0.move(to: CGPoint(x: 30, y: 20)); $0.addCurve(to: CGPoint(x: 30, y: 20), control1: CGPoint(x: 64, y: -6), control2: CGPoint(x: 64, y: 46)) }
                .fill(Palette.fleshDeep)
            Circle().fill(Palette.flesh).frame(width: 14).position(x: 30, y: 20)
        }
        .frame(width: 60, height: 40)
    }
}

private struct Heart: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w / 2, y: h))
        path.addCurve(to: CGPoint(x: 0, y: h * 0.3), control1: CGPoint(x: w * 0.1, y: h * 0.75), control2: CGPoint(x: 0, y: h * 0.55))
        path.addArc(center: CGPoint(x: w * 0.25, y: h * 0.3), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addArc(center: CGPoint(x: w * 0.75, y: h * 0.3), radius: w * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: CGPoint(x: w / 2, y: h), control1: CGPoint(x: w, y: h * 0.55), control2: CGPoint(x: w * 0.9, y: h * 0.75))
        return path
    }
}
