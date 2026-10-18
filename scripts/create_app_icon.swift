import AppKit
import Foundation

// Deterministic 1024 px store icon. No bundled SDK art or third-party logos.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let canvas = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.26, blue: 0.44, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.18, blue: 0.41, alpha: 1)
])!.draw(in: canvas, angle: -35)

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func ellipse(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}
func line(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.move(to: from)
    path.line(to: to)
    color.setStroke()
    path.stroke()
}
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 42
shadow.shadowOffset = NSSize(width: 0, height: -32)
shadow.set()

// A physical remote is recognizable immediately at small icon sizes.
rounded(NSRect(x: 295, y: 120, width: 434, height: 782), radius: 145,
        color: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1))
NSShadow().set()
rounded(NSRect(x: 310, y: 132, width: 404, height: 752), radius: 138,
        color: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.27, alpha: 1))

// Top blue power key.
ellipse(NSRect(x: 456, y: 758, width: 112, height: 112),
        color: NSColor(calibratedRed: 0.45, green: 0.60, blue: 1.0, alpha: 1))
line(from: CGPoint(x: 512, y: 824), to: CGPoint(x: 512, y: 786),
     color: .white, width: 14)
let ring = NSBezierPath()
ring.lineWidth = 14
ring.lineCapStyle = .round
ring.appendArc(withCenter: CGPoint(x: 512, y: 814), radius: 30,
               startAngle: 130, endAngle: 410, clockwise: false)
NSColor.white.setStroke()
ring.stroke()

// Large directional disc with raised center.
ellipse(NSRect(x: 364, y: 378, width: 296, height: 296),
        color: NSColor(calibratedRed: 0.27, green: 0.30, blue: 0.40, alpha: 1))
ellipse(NSRect(x: 426, y: 440, width: 172, height: 172),
        color: NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.79, alpha: 1))
ellipse(NSRect(x: 471, y: 485, width: 82, height: 82),
        color: NSColor(calibratedRed: 0.80, green: 0.88, blue: 1, alpha: 1))

let white = NSColor.white.withAlphaComponent(0.85)
let stroke: CGFloat = 16
line(from: CGPoint(x: 500, y: 639), to: CGPoint(x: 512, y: 651), color: white, width: stroke)
line(from: CGPoint(x: 512, y: 651), to: CGPoint(x: 524, y: 639), color: white, width: stroke)
line(from: CGPoint(x: 500, y: 413), to: CGPoint(x: 512, y: 401), color: white, width: stroke)
line(from: CGPoint(x: 512, y: 401), to: CGPoint(x: 524, y: 413), color: white, width: stroke)
line(from: CGPoint(x: 401, y: 538), to: CGPoint(x: 389, y: 526), color: white, width: stroke)
line(from: CGPoint(x: 389, y: 526), to: CGPoint(x: 401, y: 514), color: white, width: stroke)
line(from: CGPoint(x: 623, y: 538), to: CGPoint(x: 635, y: 526), color: white, width: stroke)
line(from: CGPoint(x: 635, y: 526), to: CGPoint(x: 623, y: 514), color: white, width: stroke)

// Lower tactile buttons.
for x in [406.0, 512.0, 618.0] {
    ellipse(NSRect(x: x - 29, y: 258, width: 58, height: 58),
            color: NSColor(calibratedRed: 0.37, green: 0.41, blue: 0.54, alpha: 1))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let directory = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let output = directory.appendingPathComponent("CastDeckIcon.png")
try png.write(to: output, options: .atomic)
print("Wrote Store icon: \(output.path) (\(png.count) bytes)")
