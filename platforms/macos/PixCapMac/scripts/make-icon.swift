#!/usr/bin/env swift
//
// Generates PixCap's application icon.
//
// The mark is drawn from primitives — a rounded gradient tile, four viewfinder
// brackets, and a lens — rather than an SF Symbol, because Apple's SF Symbols
// licence forbids using the symbols in app icons.
//
// Usage:  swift scripts/make-icon.swift <output.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.icns"

/// Optional second argument: a directory to also receive raw PNG renditions,
/// used to build the Windows .ico from the same drawing.
let pngDirectory: URL? = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : nil

/// Draws the icon at an arbitrary size. All metrics are proportional so every
/// rendition is crisp rather than a scaled bitmap.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inside a rounded square with a margin, per the HIG grid.
    let margin = size * 0.09
    let tile = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = tile.width * 0.2237 // matches the macOS squircle proportion

    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background gradient — the violet/blue used across PixCap's UI.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let colors = [
        NSColor(srgbRed: 0.35, green: 0.28, blue: 0.92, alpha: 1).cgColor,
        NSColor(srgbRed: 0.42, green: 0.48, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.31, green: 0.72, blue: 0.95, alpha: 1).cgColor
    ] as CFArray

    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors,
        locations: [0.0, 0.55, 1.0]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }

    // Subtle top highlight so the tile reads as a physical surface.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            NSColor(white: 1, alpha: 0.22).cgColor,
            NSColor(white: 1, alpha: 0).cgColor
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.midY),
            options: []
        )
    }
    context.restoreGState()

    // Viewfinder brackets.
    let inset = tile.width * 0.20
    let frame = tile.insetBy(dx: inset, dy: inset)
    let arm = frame.width * 0.30
    let line = max(1, size * 0.045)

    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(line)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        // (corner, horizontal arm end, vertical arm end)
        (CGPoint(x: frame.minX, y: frame.maxY),
         CGPoint(x: frame.minX + arm, y: frame.maxY),
         CGPoint(x: frame.minX, y: frame.maxY - arm)),
        (CGPoint(x: frame.maxX, y: frame.maxY),
         CGPoint(x: frame.maxX - arm, y: frame.maxY),
         CGPoint(x: frame.maxX, y: frame.maxY - arm)),
        (CGPoint(x: frame.minX, y: frame.minY),
         CGPoint(x: frame.minX + arm, y: frame.minY),
         CGPoint(x: frame.minX, y: frame.minY + arm)),
        (CGPoint(x: frame.maxX, y: frame.minY),
         CGPoint(x: frame.maxX - arm, y: frame.minY),
         CGPoint(x: frame.maxX, y: frame.minY + arm))
    ]

    for (corner, horizontal, vertical) in corners {
        context.move(to: horizontal)
        context.addLine(to: corner)
        context.addLine(to: vertical)
    }
    context.strokePath()

    // Lens.
    let lensRadius = frame.width * 0.21
    let lens = CGRect(
        x: frame.midX - lensRadius,
        y: frame.midY - lensRadius,
        width: lensRadius * 2,
        height: lensRadius * 2
    )
    context.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor)
    context.fillEllipse(in: lens)

    // Aperture highlight, offset like a catch-light.
    let dot = lens.insetBy(dx: lensRadius * 0.52, dy: lensRadius * 0.52)
        .offsetBy(dx: -lensRadius * 0.16, dy: lensRadius * 0.16)
    context.setFillColor(NSColor(srgbRed: 0.35, green: 0.30, blue: 0.92, alpha: 0.85).cgColor)
    context.fillEllipse(in: dot)

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    representation.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

// Build a .iconset, then let iconutil compile it.
let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("PixCap.iconset")
try? FileManager.default.removeItem(at: workDirectory)
try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

// (point size, scale) pairs required by iconutil.
let renditions: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]

for (points, scale) in renditions {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    // Render at the target pixel size so small sizes stay legible.
    let image = drawIcon(size: CGFloat(pixels))
    try writePNG(image, to: workDirectory.appendingPathComponent(name), pixelSize: pixels)
}

if let pngDirectory {
    try? FileManager.default.createDirectory(at: pngDirectory, withIntermediateDirectories: true)
    // Sizes Windows uses in Explorer, the taskbar, and Alt-Tab.
    for size in [16, 20, 24, 32, 40, 48, 64, 96, 128, 256] {
        let image = drawIcon(size: CGFloat(size))
        try writePNG(image, to: pngDirectory.appendingPathComponent("icon_\(size).png"), pixelSize: size)
    }
    print("✅ Wrote PNG renditions to \(pngDirectory.path)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", workDirectory.path, "-o", outputPath]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: workDirectory)
print("✅ Wrote \(outputPath)")
