// Renders docs/social-preview.png (1280 x 640, for the GitHub repo settings) and docs/pill.png
// (the recording pill at 2x, for the README). The pill matches App/Pill: a 32 pt capsule of
// white at 10% and 85% opacity holding seven white bars, 34 x 16 pt, 3 pt apart.
// Usage: swift scripts/make-social-preview.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let heights: [CGFloat] = [0.28, 0.5, 0.78, 1.0, 0.78, 0.5, 0.28]
let pillSize = NSSize(width: 14 + 34 + 14, height: 32)

/// Draws the pill in points with its bottom-left corner at `origin`, scaled by `scale`.
func drawPill(at origin: NSPoint, scale: CGFloat) {
    let body = NSRect(x: origin.x, y: origin.y, width: pillSize.width * scale, height: pillSize.height * scale)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.shadowBlurRadius = 6 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(white: 0.1, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    let gap = 3 * scale, barsHeight = 16 * scale
    let width = (34 * scale - gap * CGFloat(heights.count - 1)) / CGFloat(heights.count)
    NSColor.white.setFill()
    for (i, fraction) in heights.enumerated() {
        let h = max(width, barsHeight * fraction)
        let rect = NSRect(x: body.minX + 14 * scale + CGFloat(i) * (width + gap), y: body.midY - h / 2, width: width, height: h)
        NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

func render(width: Int, height: Int, to path: String, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func drawCentered(_ text: String, font: NSFont, color: NSColor, midY: CGFloat, canvasWidth: CGFloat) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let size = string.size()
    string.draw(at: NSPoint(x: (canvasWidth - size.width) / 2, y: midY - size.height / 2))
}

let canvas = NSSize(width: 1280, height: 640)
try render(width: Int(canvas.width), height: Int(canvas.height), to: "docs/social-preview.png") {
    NSGradient(
        starting: NSColor(srgbRed: 0x2E / 255, green: 0x2E / 255, blue: 0x2E / 255, alpha: 1),
        ending: NSColor(srgbRed: 0x0F / 255, green: 0x0F / 255, blue: 0x0F / 255, alpha: 1)
    )!.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)
    let scale: CGFloat = 5
    drawPill(at: NSPoint(x: (canvas.width - pillSize.width * scale) / 2, y: 362), scale: scale)
    drawCentered("just transcribe", font: .systemFont(ofSize: 84, weight: .semibold), color: .white,
                 midY: 262, canvasWidth: canvas.width)
    drawCentered("Press a key. Talk. It's typed.", font: .systemFont(ofSize: 36, weight: .regular),
                 color: NSColor(white: 1, alpha: 0.6), midY: 172, canvasWidth: canvas.width)
}

// A margin keeps the pill's shadow inside the image.
let margin: CGFloat = 12
try render(width: Int((pillSize.width + margin * 2) * 2), height: Int((pillSize.height + margin * 2) * 2),
           to: "docs/pill.png") {
    drawPill(at: NSPoint(x: margin * 2, y: margin * 2), scale: 2)
}
