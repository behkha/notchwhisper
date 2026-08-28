import AppKit
import CoreGraphics

// Renders the NotchWhisper app icon: a black squircle (the notch) with a
// white→ice-blue waveform ribbon across the middle and a red record dot —
// the same visual language as the in-app island.

let canvas: CGFloat = 1024

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }
    let s = size / canvas   // scale factor vs the 1024 design space

    // Transparent background (macOS draws the squircle shape itself in
    // Finder; we draw our own squircle with proper icon margins).
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Squircle body — Apple icon-template margins (~82% of canvas).
    let inset: CGFloat = 92 * s
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius: CGFloat = 190 * s
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Subtle vertical gradient so the black isn't flat-dead.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1),
        CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
    ]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // Hairline inner highlight along the top edge (glass read).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(2.5 * s)
    ctx.strokePath()
    ctx.restoreGState()

    // --- Waveform ribbon (mirrored, tapered at the ends) ---
    let midY = size * 0.52
    let ribbonW: CGFloat = 600 * s
    let x0 = (size - ribbonW) / 2
    let maxAmp: CGFloat = 150 * s
    let n = 48
    // A pleasing frozen speech envelope: arch + two ripples.
    func height(_ i: Int) -> CGFloat {
        let x = CGFloat(i) / CGFloat(n - 1)
        let arch = pow(sin(.pi * x), 0.85)
        let w1 = sin(Double(i) * 0.42 + 0.8)
        let w2 = sin(Double(i) * 0.23 + 2.4)
        let ripple = 0.5 + 0.24 * w1 + 0.16 * w2
        return (0.10 + 0.90 * ripple) * arch
    }
    func topPt(_ i: Int) -> CGPoint {
        CGPoint(x: x0 + CGFloat(i) * ribbonW / CGFloat(n - 1),
                y: midY + height(i) * maxAmp)
    }
    func botPt(_ i: Int) -> CGPoint {
        CGPoint(x: x0 + CGFloat(i) * ribbonW / CGFloat(n - 1),
                y: midY - height(i) * maxAmp * 0.28)
    }
    let ribbon = CGMutablePath()
    ribbon.move(to: topPt(0))
    for i in 1..<n {
        let p = topPt(i - 1), c = topPt(i)
        let mx = (p.x + c.x) / 2
        ribbon.addCurve(to: c, control1: CGPoint(x: mx, y: p.y), control2: CGPoint(x: mx, y: c.y))
    }
    for i in stride(from: n - 1, through: 1, by: -1) {
        let p = botPt(i), c = botPt(i - 1)
        let mx = (p.x + c.x) / 2
        ribbon.addCurve(to: c, control1: CGPoint(x: mx, y: p.y), control2: CGPoint(x: mx, y: c.y))
    }
    ribbon.closeSubpath()

    // Glow pass (soft, wide, low alpha) then the crisp gradient fill.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26 * s,
                  color: CGColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.55))
    ctx.addPath(ribbon)
    ctx.setFillColor(CGColor(red: 0.75, green: 0.9, blue: 1.0, alpha: 0.35))
    ctx.fillPath()
    ctx.restoreGState()

    let ribbonColors = [
        CGColor(red: 0.55, green: 0.82, blue: 1.0, alpha: 0.75),
        CGColor(red: 0.85, green: 0.94, blue: 1.0, alpha: 0.95),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    ]
    let ribbonGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: ribbonColors as CFArray, locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.addPath(ribbon)
    ctx.clip()
    ctx.drawLinearGradient(ribbonGrad,
                           start: CGPoint(x: 0, y: midY - maxAmp),
                           end: CGPoint(x: 0, y: midY + maxAmp * 0.3),
                           options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    // Red record dot, left of the ribbon.
    let dotR: CGFloat = 22 * s
    let dotC = CGPoint(x: x0 - 70 * s, y: midY)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14 * s,
                  color: CGColor(red: 0.93, green: 0.27, blue: 0.27, alpha: 0.8))
    ctx.setFillColor(CGColor(red: 0.93, green: 0.27, blue: 0.27, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

// Build the iconset
let iconset = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let slots: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for slot in slots {
    let img = drawIcon(size: CGFloat(slot.px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/\(slot.name)"))
}
print("iconset written to \(iconset)")
