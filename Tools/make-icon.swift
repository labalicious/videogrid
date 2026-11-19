// Draws the app icon: a monitor whose screen is a 2×2 grid, top-left cell pink.
// Run:  swift Tools/make-icon.swift   (writes Resources/AppIcon.icns)
import AppKit

let pink = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.68, alpha: 1)
let ink = NSColor(white: 0.08, alpha: 1)

func draw(_ s: CGFloat) {
    // macOS icon grid: an 824-pt rounded square inside a 1024 canvas.
    let k = s / 1024
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let bg = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.88, alpha: 1))!
        .draw(in: bg, angle: -90)

    // Monitor body
    let line = 34 * k
    let body = NSRect(x: 196 * k, y: 352 * k, width: 632 * k, height: 440 * k)
    let screen = body.insetBy(dx: line, dy: line)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 36 * k, yRadius: 36 * k)
    ink.setFill(); bodyPath.fill()
    NSColor.white.setFill(); NSBezierPath(rect: screen).fill()

    // 2×2 grid; top-left is pink (AppKit's y axis points up).
    let half = line * 0.6
    let cw = (screen.width - half) / 2, ch = (screen.height - half) / 2
    pink.setFill()
    NSBezierPath(rect: NSRect(x: screen.minX, y: screen.maxY - ch, width: cw, height: ch)).fill()
    ink.setFill()
    NSBezierPath(rect: NSRect(x: screen.minX + cw, y: screen.minY, width: half, height: screen.height)).fill()
    NSBezierPath(rect: NSRect(x: screen.minX, y: screen.minY + ch, width: screen.width, height: half)).fill()

    // Neck and foot
    NSBezierPath(rect: NSRect(x: 472 * k, y: 262 * k, width: 80 * k, height: 92 * k)).fill()
    NSBezierPath(roundedRect: NSRect(x: 352 * k, y: 228 * k, width: 320 * k, height: 44 * k),
                 xRadius: 14 * k, yRadius: 14 * k).fill()
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                                  to: root.appendingPathComponent("build/icon-preview.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
