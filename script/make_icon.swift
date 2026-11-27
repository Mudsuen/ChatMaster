// Renders Packaging/AppIcon.icns for ChatMaster: deep obsidian-emerald squircle,
// frosted background bubble, sculpted primary bubble with mastery 4-point star + dialogue bars.
// Usage: swift script/make_icon.swift <output.icns> [--preview <preview512.png>]
import AppKit

var out = "Packaging/AppIcon.icns"
var previewPath: String?
var it = CommandLine.arguments.dropFirst().makeIterator()
var positional: [String] = []
while let arg = it.next() {
    if arg == "--preview" {
        previewPath = it.next()
    } else {
        positional.append(arg)
    }
}
if let first = positional.first { out = first }

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChatMaster.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func fourPointStar(cx: CGFloat, cy: CGFloat, r: CGFloat, pinch: CGFloat = 0.22) -> NSBezierPath {
    let p = NSBezierPath()
    let c = r * pinch
    p.move(to: NSPoint(x: cx, y: cy + r))
    p.curve(to: NSPoint(x: cx + r, y: cy),
            controlPoint1: NSPoint(x: cx + c, y: cy + c),
            controlPoint2: NSPoint(x: cx + c, y: cy + c))
    p.curve(to: NSPoint(x: cx, y: cy - r),
            controlPoint1: NSPoint(x: cx + c, y: cy - c),
            controlPoint2: NSPoint(x: cx + c, y: cy - c))
    p.curve(to: NSPoint(x: cx - r, y: cy),
            controlPoint1: NSPoint(x: cx - c, y: cy - c),
            controlPoint2: NSPoint(x: cx - c, y: cy - c))
    p.curve(to: NSPoint(x: cx, y: cy + r),
            controlPoint1: NSPoint(x: cx - c, y: cy + c),
            controlPoint2: NSPoint(x: cx - c, y: cy + c))
    p.close()
    return p
}

func bubblePath(rect b: NSRect, tailOnLeft: Bool) -> NSBezierPath {
    let r = b.height * 0.36
    let body = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
    let tail = NSBezierPath()
    if tailOnLeft {
        tail.move(to: NSPoint(x: b.minX + b.width * 0.21, y: b.minY + b.height * 0.12))
        tail.curve(to: NSPoint(x: b.minX + b.width * 0.08, y: b.minY - b.height * 0.16),
                   controlPoint1: NSPoint(x: b.minX + b.width * 0.15, y: b.minY - b.height * 0.04),
                   controlPoint2: NSPoint(x: b.minX + b.width * 0.10, y: b.minY - b.height * 0.12))
        tail.curve(to: NSPoint(x: b.minX + b.width * 0.40, y: b.minY + b.height * 0.02),
                   controlPoint1: NSPoint(x: b.minX + b.width * 0.20, y: b.minY - b.height * 0.10),
                   controlPoint2: NSPoint(x: b.minX + b.width * 0.30, y: b.minY - b.height * 0.02))
    } else {
        tail.move(to: NSPoint(x: b.maxX - b.width * 0.22, y: b.minY + b.height * 0.10))
        tail.curve(to: NSPoint(x: b.maxX - b.width * 0.08, y: b.minY - b.height * 0.18),
                   controlPoint1: NSPoint(x: b.maxX - b.width * 0.16, y: b.minY - b.height * 0.04),
                   controlPoint2: NSPoint(x: b.maxX - b.width * 0.10, y: b.minY - b.height * 0.14))
        tail.curve(to: NSPoint(x: b.maxX - b.width * 0.40, y: b.minY + b.height * 0.02),
                   controlPoint1: NSPoint(x: b.maxX - b.width * 0.20, y: b.minY - b.height * 0.11),
                   controlPoint2: NSPoint(x: b.maxX - b.width * 0.30, y: b.minY - b.height * 0.02))
    }
    tail.close()
    body.append(tail)
    return body
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = s * 0.088
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Outer drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.032,
                  color: NSColor.black.withAlphaComponent(0.32).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    ctx.restoreGState()

    // Clipped squircle background
    ctx.saveGState()
    squircle.addClip()

    let bgGrad = NSGradient(colors: [
        NSColor(red: 0.045, green: 0.145, blue: 0.130, alpha: 1.0), // #0B2521
        NSColor(red: 0.048, green: 0.345, blue: 0.255, alpha: 1.0), // #0C5841
        NSColor(red: 0.070, green: 0.650, blue: 0.435, alpha: 1.0), // #12A66F
    ], atLocations: [0.0, 0.52, 1.0], colorSpace: .deviceRGB)!
    bgGrad.draw(in: rect, angle: -42)

    // Subtle radial ambient glow in bottom-right & top-left
    if let glow = NSGradient(colors: [
        NSColor(red: 0.26, green: 0.94, blue: 0.66, alpha: 0.20),
        NSColor(red: 0.26, green: 0.94, blue: 0.66, alpha: 0.0),
    ]) {
        glow.draw(fromCenter: NSPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.18),
                  radius: 0,
                  toCenter: NSPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.18),
                  radius: rect.width * 0.62,
                  options: [])
    }

    // Back frosted bubble (upper right)
    let backRect = NSRect(
        x: rect.minX + rect.width * 0.36,
        y: rect.minY + rect.height * 0.44,
        width: rect.width * 0.48,
        height: rect.height * 0.35
    )
    let backBubble = bubblePath(rect: backRect, tailOnLeft: false)
    NSColor.white.withAlphaComponent(0.18).setFill()
    backBubble.fill()
    NSColor.white.withAlphaComponent(0.32).setStroke()
    backBubble.lineWidth = max(1, s * 0.008)
    backBubble.stroke()

    // Front primary bubble (lower-left / center-weighted)
    let frontRect = NSRect(
        x: rect.minX + rect.width * 0.155,
        y: rect.minY + rect.height * 0.23,
        width: rect.width * 0.61,
        height: rect.height * 0.45
    )
    let frontBubble = bubblePath(rect: frontRect, tailOnLeft: true)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.036,
                  color: NSColor(red: 0.01, green: 0.08, blue: 0.06, alpha: 0.28).cgColor)
    NSColor.white.setFill()
    frontBubble.fill()
    ctx.restoreGState()

    ctx.saveGState()
    frontBubble.addClip()
    NSGradient(colors: [
        NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        NSColor(red: 0.92, green: 0.965, blue: 0.945, alpha: 1.0),
    ])!.draw(in: frontRect, angle: -90)
    ctx.restoreGState()

    // Mastery emblem inside front bubble: 4-point star + two crisp dialogue bars
    let starCX = frontRect.minX + frontRect.width * 0.27
    let starCY = frontRect.midY
    let starR = frontRect.height * 0.235
    let star = fourPointStar(cx: starCX, cy: starCY, r: starR, pinch: 0.20)
    ctx.saveGState()
    star.addClip()
    NSGradient(colors: [
        NSColor(red: 0.04, green: 0.37, blue: 0.26, alpha: 1.0),
        NSColor(red: 0.08, green: 0.72, blue: 0.48, alpha: 1.0),
    ])!.draw(in: star.bounds, angle: -45)
    ctx.restoreGState()

    let barX = frontRect.minX + frontRect.width * 0.46
    let barH = frontRect.height * 0.105
    let barTop = NSRect(x: barX, y: frontRect.midY + frontRect.height * 0.055,
                        width: frontRect.width * 0.37, height: barH)
    let barBot = NSRect(x: barX, y: frontRect.midY - frontRect.height * 0.055 - barH,
                        width: frontRect.width * 0.26, height: barH)
    NSColor(red: 0.055, green: 0.43, blue: 0.305, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: barTop, xRadius: barH / 2, yRadius: barH / 2).fill()
    NSColor(red: 0.055, green: 0.43, blue: 0.305, alpha: 0.52).setFill()
    NSBezierPath(roundedRect: barBot, xRadius: barH / 2, yRadius: barH / 2).fill()

    // Warm champagne accent star centered neatly inside the exposed top-right of the back bubble
    let accent = fourPointStar(
        cx: backRect.maxX - backRect.width * 0.22,
        cy: backRect.maxY - backRect.height * 0.30,
        r: rect.width * 0.064,
        pinch: 0.22
    )
    NSColor(red: 1.0, green: 0.91, blue: 0.54, alpha: 1.0).setFill()
    accent.fill()

    // Crisp inner glass rim stroke
    squircle.lineWidth = max(1, s * 0.015)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    squircle.stroke()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
if let previewPath {
    let url = URL(fileURLWithPath: previewPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try render(512).write(to: url)
    print("wrote preview \(previewPath)")
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
