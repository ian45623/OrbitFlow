#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the backdrop of the installer window `make dmg` opens: the app on the left,
// Applications on the right, an arrow between. Run: swift Tools/makedmgbackground.swift
//
// The icon positions in the Makefile's `dmg` target are the centers these are drawn
// around. Change together.

let width: CGFloat = 600
let height: CGFloat = 380
let iconCenterY: CGFloat = 190  // Finder measures from the top; symmetric here, so same value.

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Light, whatever the system appearance: Finder draws icon labels over it in its own
    // color, and a pale backdrop is what keeps them readable in the common case.
    NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let ink = NSColor(srgbRed: 0.55, green: 0.56, blue: 0.60, alpha: 1)
    ink.setStroke()
    ink.setFill()

    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: 250, y: iconCenterY))
    arrow.line(to: NSPoint(x: 346, y: iconCenterY))
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 356, y: iconCenterY))
    head.line(to: NSPoint(x: 340, y: iconCenterY + 10))
    head.line(to: NSPoint(x: 340, y: iconCenterY - 10))
    head.close()
    head.fill()

    let caption = NSAttributedString(
        string: "Drag Orbit Flow into Applications",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
        ])
    let captionSize = caption.size()
    caption.draw(at: NSPoint(x: (width - captionSize.width) / 2, y: 48))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// One TIFF carrying both resolutions, so the window is sharp on Retina and still right
// on a 1x display.
let image = NSImage(size: NSSize(width: width, height: height))
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let out = URL(filePath: "Resources/DMGBackground.tiff")
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: out)
print("wrote \(out.path)")
