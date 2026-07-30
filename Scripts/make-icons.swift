#!/usr/bin/env swift
// Generates Flotilla's app icon and menu-bar glyph from the brand geometry.
//
// WHY GENERATE RATHER THAN RASTERISE THE SVG
//
// `design/brand/icons/flotilla.svg` is the source of truth for the shapes, but it cannot be
// embedded or rasterised as-is:
//
//   * the wordmark SVGs pull a webfont with `@import url('https://fonts.googleapis.com/…')`.
//     Flotilla promises no telemetry and no phone-home, and its About view is meant to list
//     every network destination — shipping an asset that fetches a font would make that false.
//   * no SVG rasteriser is installed here beyond QuickLook, which is a thumbnailer rather than
//     a build tool and gives no control over size or colour.
//
// The mark is a squircle, two bands, three sails and three seeds. Drawing it in CoreGraphics is
// deterministic, dependency-free, and lets the menu-bar glyph be derived from the *same*
// geometry instead of being a separate drawing that drifts.
//
// Run:  swift Scripts/make-icons.swift
// Out:  build/icons/Flotilla.icns  and  Resources/MenuBarIconTemplate{,@2x}.png

import AppKit
import CoreGraphics
import Foundation

// Brand palette, from design/brand/BRAND.md and the icon SVG.
let flesh = CGColor(red: 0xFC / 255, green: 0x4A / 255, blue: 0x6B / 255, alpha: 1)
let rind = CGColor(red: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255, alpha: 1)
let pith = CGColor(gray: 1, alpha: 1)
let seed = CGColor(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255, alpha: 1)

/// The three sails, in the SVG's 120×120 space. Shared by both outputs so the menu-bar glyph
/// can never drift from the app icon.
let sails: [[(CGFloat, CGFloat)]] = [
    [(40, 86), (40, 44), (23, 86)],
    [(64, 86), (64, 26), (43, 86)],
    [(92, 86), (92, 52), (73, 86)],
]
let seeds: [(CGFloat, CGFloat)] = [(32, 64), (80, 60), (54, 46)]

func context(_ size: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(size)×\(size) context") }
    // The SVG's origin is top-left; CoreGraphics is bottom-left. Flip once here rather than
    // inverting every y by hand.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 120, y: -CGFloat(size) / 120)
    return ctx
}

func addSails(_ ctx: CGContext) {
    for sail in sails {
        ctx.move(to: CGPoint(x: sail[0].0, y: sail[0].1))
        for point in sail.dropFirst() { ctx.addLine(to: CGPoint(x: point.0, y: point.1)) }
        ctx.closePath()
    }
}

/// The full-colour app icon.
func appIcon(_ size: Int) -> CGImage {
    let ctx = context(size)

    // Squircle, matching the SVG's rx=27 at 120pt.
    let squircle = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: 120, height: 120),
        cornerWidth: 27, cornerHeight: 27, transform: nil
    )
    ctx.addPath(squircle)
    ctx.clip()

    ctx.setFillColor(flesh)
    ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
    ctx.setFillColor(rind)
    ctx.fill(CGRect(x: 0, y: 96, width: 120, height: 24))
    ctx.setFillColor(pith)
    ctx.fill(CGRect(x: 0, y: 90, width: 120, height: 6))

    ctx.setFillColor(pith)
    addSails(ctx)
    ctx.fillPath()

    ctx.setFillColor(seed)
    for (x, y) in seeds {
        ctx.fillEllipse(in: CGRect(x: x - 2.2, y: y - 3.4, width: 4.4, height: 6.8))
    }
    return ctx.makeImage()!
}

/// The menu-bar glyph: **the sails only, solid black on transparent**.
///
/// A template image. macOS inverts it for a dark menu bar automatically, so one asset serves
/// light and dark — there is no need for two, and shipping two would guarantee they drift.
/// Colour is deliberately absent: `research/FEATURES.md` calls for a monochrome template with
/// state shown by shape or badge, which is also what every system menu-bar item does.
///
/// Just the sails, not the whole slice: at 16pt the bands and seeds collapse into mud, while
/// three sails stay legible and read as a flotilla.
func menuBarGlyph(_ size: Int) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(size)×\(size) context") }

    // Points are mapped explicitly rather than by stacking CTM transforms. The first attempt
    // chained translate/scale/flip calls and collapsed the sails into a two-pixel smudge —
    // easy to get wrong, and impossible to read back from the code. This is verifiable by eye.
    let minX: CGFloat = 23, maxX: CGFloat = 92
    let minY: CGFloat = 26, maxY: CGFloat = 86
    let sourceWidth = maxX - minX, sourceHeight = maxY - minY

    // A 1pt breathing space, then fit preserving aspect and centre what is left over.
    let inset: CGFloat = 1
    let box = CGFloat(size) - inset * 2
    let scale = min(box / sourceWidth, box / sourceHeight)
    let drawnWidth = sourceWidth * scale, drawnHeight = sourceHeight * scale
    let offsetX = (CGFloat(size) - drawnWidth) / 2
    let offsetY = (CGFloat(size) - drawnHeight) / 2

    // SVG y grows downward, CoreGraphics upward — flipped in the mapping itself.
    func map(_ point: (CGFloat, CGFloat)) -> CGPoint {
        CGPoint(
            x: offsetX + (point.0 - minX) * scale,
            y: offsetY + (maxY - point.1) * scale
        )
    }

    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    for sail in sails {
        ctx.move(to: map(sail[0]))
        for point in sail.dropFirst() { ctx.addLine(to: map(point)) }
        ctx.closePath()
    }
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/icons/Flotilla.iconset")
let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

// The sizes `iconutil` expects.
for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"),
                     (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
    write(appIcon(size), to: iconset.appendingPathComponent("\(name).png"))
}
print("✓ \(iconset.path)")

// Menu-bar template, at 1× and 2×. 18pt is the conventional menu-bar glyph box.
write(menuBarGlyph(18), to: resources.appendingPathComponent("MenuBarIconTemplate.png"))
write(menuBarGlyph(36), to: resources.appendingPathComponent("MenuBarIconTemplate@2x.png"))
print("✓ \(resources.path)/MenuBarIconTemplate.png (+@2x)")
