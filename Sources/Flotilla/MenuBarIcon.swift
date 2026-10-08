import AppKit

/// What the menu-bar icon's badge says. Three states the owner asked for (8 October), plus none
/// while Flotilla is still finding out — a badge that guesses is worse than no badge.
enum MenuBarStatus: Equatable {
    /// Preflight hasn't answered yet.
    case checking
    /// `container` is running on This Mac and nothing needs attention.
    case running
    /// Something on This Mac or a host needs attention — the same list Overview shows.
    case attention
    /// `container` is stopped or not installed on This Mac.
    case off
}

/// Flotilla's menu-bar icon: the three sails inside the app icon's squircle, as an outline, with
/// a status badge in the corner (the owner, 8 October).
///
/// Drawn rather than loaded, for two reasons. The badge is colour — green, red, no-entry — and a
/// template image is one colour by definition, so the image cannot be a template; drawing it with a
/// handler lets the glyph take the menu bar's own label colour at draw time instead, so it still
/// follows a light or dark menu bar. And the sails come from the same geometry as the app icon
/// (`Scripts/make-icons.swift`), so the two cannot drift.
enum MenuBarIcon {
    /// The canvas, in points: the height macOS gives a status item's image.
    static let size = NSSize(width: 18, height: 18)

    /// The sails, in the brand SVG's 120×120 space — the same three triangles as the app icon.
    private static let sails: [[CGPoint]] = [
        [CGPoint(x: 40, y: 86), CGPoint(x: 40, y: 44), CGPoint(x: 23, y: 86)],
        [CGPoint(x: 64, y: 86), CGPoint(x: 64, y: 26), CGPoint(x: 43, y: 86)],
        [CGPoint(x: 92, y: 86), CGPoint(x: 92, y: 52), CGPoint(x: 73, y: 86)],
    ]

    static func image(for status: MenuBarStatus) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(status, in: rect, glyph: .labelColor)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityLabel(status)
        return image
    }

    static func accessibilityLabel(_ status: MenuBarStatus) -> String {
        switch status {
        case .checking: "Flotilla"
        case .running: "Flotilla, container running"
        case .attention: "Flotilla, something needs attention"
        case .off: "Flotilla, container is off"
        }
    }

    /// Draws into the current context. `glyph` is the outline-and-sails colour; the badge brings
    /// its own.
    static func draw(_ status: MenuBarStatus, in rect: NSRect, glyph: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let unit = rect.width / size.width

        // The squircle: the app icon's shape, outlined. A continuous-corner rounded rect at this
        // size is indistinguishable from the superellipse.
        let line: CGFloat = 1.2 * unit
        let squircleRect = rect.insetBy(dx: 1.5 * unit, dy: 1.5 * unit)
        let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: 4.6 * unit, yRadius: 4.6 * unit)
        squircle.lineWidth = line
        glyph.setStroke()
        squircle.stroke()

        // The sails, fitted inside with a little more room below than above, as a boat sits.
        let minX: CGFloat = 23, maxX: CGFloat = 92, minY: CGFloat = 26, maxY: CGFloat = 86
        let scale = (9.0 * unit) / (maxX - minX)
        let drawnWidth = (maxX - minX) * scale, drawnHeight = (maxY - minY) * scale
        // Nudged up and left, so the badge's cut-out never reaches the third sail.
        let originX = rect.midX - drawnWidth / 2 - 1.0 * unit
        let originY = rect.midY - drawnHeight / 2 + 0.8 * unit
        let sails = NSBezierPath()
        for sail in Self.sails {
            for (index, point) in sail.enumerated() {
                let mapped = NSPoint(x: originX + (point.x - minX) * scale,
                                     y: originY + (maxY - point.y) * scale)
                if index == 0 { sails.move(to: mapped) } else { sails.line(to: mapped) }
            }
            sails.close()
        }
        glyph.setFill()
        sails.fill()

        guard status != .checking else { return }

        // The badge, bottom right, with a clear ring cut out of the outline so it reads as a
        // badge on the icon and not a blot on it.
        let diameter: CGFloat = 6.4 * unit
        let badge = NSRect(x: rect.maxX - diameter, y: rect.minY,
                           width: diameter, height: diameter)
        let gap: CGFloat = 1.2 * unit
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: badge.insetBy(dx: -gap, dy: -gap))
        context.restoreGState()

        switch status {
        case .checking:
            break
        case .running:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: badge).fill()
        case .attention:
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
        case .off:
            // No entry: a red disc with a light bar across it, corner to corner.
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let bar = NSBezierPath()
            let inset = diameter * 0.26
            bar.move(to: NSPoint(x: badge.minX + inset, y: badge.maxY - inset))
            bar.line(to: NSPoint(x: badge.maxX - inset, y: badge.minY + inset))
            bar.lineWidth = 1.2 * unit
            bar.lineCapStyle = .round
            NSColor.white.setStroke()
            bar.stroke()
        }
    }
}
