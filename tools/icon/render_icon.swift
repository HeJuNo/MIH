// Renders the MyHockey Data app icon (1024×1024, opaque) with CoreGraphics.
//   swift tools/icon/render_icon.swift swift_space/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Concept: a hockey puck on deep "night ice", with a rising data line
// that ends in a red live-alert pulse: hockey + data + change notifications.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work in top-left origin coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { c($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

// 1. Background: deep navy → ice blue diagonal, with a soft spotlight.
ctx.drawLinearGradient(gradient([(0x06122B, 1, 0), (0x0B2F63, 1, 0.55), (0x1A6FB3, 1, 1)]),
                       start: CGPoint(x: 120, y: 0), end: CGPoint(x: 900, y: size),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.drawRadialGradient(gradient([(0x7FD3FF, 0.35, 0), (0x7FD3FF, 0, 1)]),
                       startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 430), endRadius: 560, options: [])

// 2. Rink marking: faint centre-ice circle.
ctx.saveGState()
ctx.setLineWidth(10)
ctx.setStrokeColor(c(0xFFFFFF, 0.07))
ctx.strokeEllipse(in: CGRect(x: 512 - 380, y: 470 - 380, width: 760, height: 760))
ctx.restoreGState()

// 3. Puck (cylinder in 3/4 view) with soft shadow.
let puckCenter = CGPoint(x: 512, y: 690)
let rx: CGFloat = 300, ry: CGFloat = 104, depth: CGFloat = 112
let top = CGRect(x: puckCenter.x - rx, y: puckCenter.y - ry, width: rx * 2, height: ry * 2)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -34), blur: 70, color: c(0x000814, 0.65))
let body = CGMutablePath()
body.addEllipse(in: top.offsetBy(dx: 0, dy: depth))
body.addRect(CGRect(x: top.minX, y: puckCenter.y, width: rx * 2, height: depth))
ctx.addPath(body); ctx.setFillColor(c(0x0B0D12)); ctx.fillPath()
ctx.restoreGState()

// Side band with metallic sheen.
ctx.saveGState()
ctx.addPath(body); ctx.clip()
ctx.drawLinearGradient(gradient([(0x14171E, 1, 0), (0x3A4150, 1, 0.22), (0x171A21, 1, 0.5), (0x0A0C10, 1, 1)]),
                       start: CGPoint(x: top.minX, y: 0), end: CGPoint(x: top.maxX, y: 0), options: [])
// Grip texture: vertical ribs.
ctx.setStrokeColor(c(0xFFFFFF, 0.05)); ctx.setLineWidth(6)
var x = top.minX + 18
while x < top.maxX { ctx.move(to: CGPoint(x: x, y: puckCenter.y)); ctx.addLine(to: CGPoint(x: x, y: puckCenter.y + depth + ry)); x += 26 }
ctx.strokePath()
ctx.restoreGState()

// Top face.
ctx.saveGState()
ctx.addEllipse(in: top); ctx.clip()
ctx.drawLinearGradient(gradient([(0x2B313D, 1, 0), (0x181C24, 1, 0.6), (0x111419, 1, 1)]),
                       start: CGPoint(x: 0, y: top.minY), end: CGPoint(x: 0, y: top.maxY), options: [])
ctx.restoreGState()
// Rim highlight + inner ice-blue ring.
ctx.setLineWidth(5); ctx.setStrokeColor(c(0xAFC6E0, 0.35)); ctx.strokeEllipse(in: top.insetBy(dx: 2, dy: 2))
ctx.setLineWidth(7); ctx.setStrokeColor(c(0x4FC3F7, 0.55)); ctx.strokeEllipse(in: top.insetBy(dx: 64, dy: 22))

// 4. Data line rising out of the puck.
let pts = [CGPoint(x: 236, y: 520), CGPoint(x: 360, y: 430), CGPoint(x: 470, y: 470),
           CGPoint(x: 590, y: 330), CGPoint(x: 744, y: 250)]
let line = CGMutablePath()
line.move(to: pts[0])
for i in 1..<pts.count {
    let p0 = pts[i - 1], p1 = pts[i], mx = (p0.x + p1.x) / 2
    line.addCurve(to: p1, control1: CGPoint(x: mx, y: p0.y), control2: CGPoint(x: mx, y: p1.y))
}
// Glow + crisp stroke.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 36, color: c(0x5AD1FF, 0.9))
ctx.addPath(line); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.setStrokeColor(c(0xBFEFFF)); ctx.strokePath()
ctx.restoreGState()
ctx.addPath(line); ctx.setLineWidth(14); ctx.setLineCap(.round); ctx.setStrokeColor(c(0xFFFFFF)); ctx.strokePath()

for p in pts.dropLast() {
    ctx.setFillColor(c(0x0B2F63)); ctx.fillEllipse(in: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
    ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
}

// 5. Live alert: red pulse at the newest data point.
let alert = pts.last!
for (r, a) in [(118.0, 0.12), (88.0, 0.22)] as [(CGFloat, CGFloat)] {
    ctx.setFillColor(c(0xFF3B47, a)); ctx.fillEllipse(in: CGRect(x: alert.x - r, y: alert.y - r, width: r * 2, height: r * 2))
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: c(0x7A0010, 0.6))
ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: alert.x - 62, y: alert.y - 62, width: 124, height: 124))
ctx.restoreGState()
ctx.drawRadialGradient(gradient([(0xFF6670, 1, 0), (0xE5232F, 1, 1)]),
                       startCenter: CGPoint(x: alert.x - 14, y: alert.y - 16), startRadius: 0,
                       endCenter: alert, endRadius: 50, options: [])
// Clip the red to a disc (radial gradient fills outward otherwise).
ctx.saveGState()
let ring = CGMutablePath()
ring.addRect(CGRect(x: alert.x - 62, y: alert.y - 62, width: 124, height: 124))
ring.addEllipse(in: CGRect(x: alert.x - 50, y: alert.y - 50, width: 100, height: 100))
ctx.addPath(ring); ctx.clip(using: .evenOdd)
ctx.setFillColor(c(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: alert.x - 62, y: alert.y - 62, width: 124, height: 124))
ctx.restoreGState()
// Exclamation glyph.
ctx.setFillColor(c(0xFFFFFF))
ctx.addPath(CGPath(roundedRect: CGRect(x: alert.x - 8, y: alert.y - 30, width: 16, height: 38), cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()
ctx.fillEllipse(in: CGRect(x: alert.x - 9, y: alert.y + 14, width: 18, height: 18))

// 6. Vignette + subtle top sheen for depth.
ctx.drawRadialGradient(gradient([(0x000000, 0, 0.55), (0x000614, 0.45, 1)]),
                       startCenter: CGPoint(x: 512, y: 480), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 480), endRadius: 760, options: [.drawsAfterEndLocation])
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.08, 0), (0xFFFFFF, 0, 0.45)]),
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
