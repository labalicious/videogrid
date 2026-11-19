// Draws the installer window background: a pink arrow from the app to the Applications folder.
// Run:  swift Tools/make-dmg-background.swift   (writes Resources/dmg-background.tiff, 1x + 2x)
//
// The window is 640×400 pt. build.sh places the icons to match: the app centered at (160, 190)
// and Applications at (480, 190), measured from the top-left like Finder does.
import AppKit

let size = NSSize(width: 640, height: 400)
let pink = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.68, alpha: 1)
let iconY: CGFloat = 400 - 190          // Finder measures from the top, AppKit from the bottom

func draw() {
    let all = NSRect(origin: .zero, size: size)
    NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!
        .draw(in: all, angle: -90)

    // Arrow between the two icons, bowing slightly upward. The shaft stops where the head begins.
    let tip = NSPoint(x: 392, y: iconY + 6)
    let c2 = NSPoint(x: 350, y: iconY + 22)
    let dir = atan2(tip.y - c2.y, tip.x - c2.x)          // the curve's direction at its end
    let len: CGFloat = 30, spread: CGFloat = 0.5
    let shaftEnd = NSPoint(x: tip.x - cos(dir) * len * 0.7, y: tip.y - sin(dir) * len * 0.7)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 248, y: iconY + 6))
    shaft.curve(to: shaftEnd, controlPoint1: NSPoint(x: 290, y: iconY + 22), controlPoint2: c2)
    shaft.lineWidth = 9
    shaft.lineCapStyle = .round
    pink.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: tip)
    head.line(to: NSPoint(x: tip.x - cos(dir - spread) * len, y: tip.y - sin(dir - spread) * len))
    head.line(to: NSPoint(x: tip.x - cos(dir + spread) * len, y: tip.y - sin(dir + spread) * len))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 4
    pink.setFill(); head.fill()
    head.stroke()

    // Instruction under the icons.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let text = NSAttributedString(string: "Drag Video Grid onto the Applications folder to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(white: 0.35, alpha: 1),
        .paragraphStyle: para,
    ])
    text.draw(in: NSRect(x: 0, y: 62, width: size.width, height: 22))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size                     // point size, so the 2x copy is marked as Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let tmp = FileManager.default.temporaryDirectory
let one = tmp.appendingPathComponent("dmg-bg.png"), two = tmp.appendingPathComponent("dmg-bg@2x.png")
try render(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try render(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
try? FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: root.appendingPathComponent("build/dmg-background-preview.png"))
try FileManager.default.copyItem(at: two, to: root.appendingPathComponent("build/dmg-background-preview.png"))

// One TIFF holding both sizes: Finder picks the sharp one on Retina screens.
let out = root.appendingPathComponent("Resources/dmg-background.tiff")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
p.arguments = ["-cathidpicheck", one.path, two.path, "-out", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "tiffutil failed")
