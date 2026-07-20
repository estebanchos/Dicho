#!/usr/bin/env swift
// Renders the DMG installer background at 1x (600x400) and 2x (1200x800).
// Run from the repo root:  swift scripts/dmg/render_background.swift
// Then combine into a Retina multi-representation TIFF:
//   tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png \
//     -out scripts/dmg/background.tiff

import AppKit

// Layout constants — must match the icon coordinates in scripts/package_dmg.sh.
let canvasSize = NSSize(width: 600, height: 400)
let appIconCenterX: CGFloat = 150
let applicationsCenterX: CGFloat = 450
// Finder positions icons from the top; y=195 in window coords ≈ icon centers.
// In this bottom-left coordinate space the icon row sits around y = 175.
let iconRowCenterY: CGFloat = 175
let iconHalfWidth: CGFloat = 64 // 128 px icons

let backgroundColor = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1.0)
let textColor = NSColor(srgbRed: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0, alpha: 1.0)
// Green sampled from the Dicho app icon's shield (mid-tone between #124831 and #629072).
let arrowColor = NSColor(srgbRed: 0x2A / 255.0, green: 0x64 / 255.0, blue: 0x48 / 255.0, alpha: 1.0)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixelWidth = Int(canvasSize.width * scale)
    let pixelHeight = Int(canvasSize.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap rep at scale \(scale)")
    }

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)

    backgroundColor.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    // Instruction text, centered near the top.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .regular),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
    ]
    let title = "To install, drag Dicho to Applications"
    let titleRect = NSRect(x: 20, y: canvasSize.height - 100, width: canvasSize.width - 40, height: 60)
    (title as NSString).draw(in: titleRect, withAttributes: attributes)

    // Straight arrow from the app icon toward the Applications folder.
    let arrowStartX = appIconCenterX + iconHalfWidth + 24
    let arrowEndX = applicationsCenterX - iconHalfWidth - 24
    let arrowY = iconRowCenterY
    let lineWidth: CGFloat = 3
    let headLength: CGFloat = 16
    let headHalfHeight: CGFloat = 11

    let shaft = NSBezierPath()
    shaft.lineWidth = lineWidth
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: arrowStartX, y: arrowY))
    shaft.line(to: NSPoint(x: arrowEndX, y: arrowY))
    arrowColor.setStroke()
    shaft.stroke()

    // Open chevron head: two stroked lines meeting at the tip, no fill.
    let head = NSBezierPath()
    head.lineWidth = lineWidth
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: arrowEndX - headLength, y: arrowY + headHalfHeight))
    head.line(to: NSPoint(x: arrowEndX, y: arrowY))
    head.line(to: NSPoint(x: arrowEndX - headLength, y: arrowY - headHalfHeight))
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(path)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    } catch {
        fatalError("Could not write \(path): \(error)")
    }
}

let outputDirectory = "scripts/dmg"
write(render(scale: 1), to: "\(outputDirectory)/background.png")
write(render(scale: 2), to: "\(outputDirectory)/background@2x.png")
