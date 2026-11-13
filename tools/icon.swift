// Renders Blink's 1024px app icon: a warm glowing bell rippling out of a dark plum night.
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Apple icon grid: 824pt body, centered, continuous-ish corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0x14082A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Night background
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3A1260), rgb(0x1A0A33), rgb(0x0C0518)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

let center = CGPoint(x: 512, y: 492)

// Warm glow
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFC46B, 1), rgb(0xFF6A5E, 1), rgb(0xE0306F, 0.7), rgb(0x6A1B8A, 0)] as CFArray,
                      locations: [0, 0.3, 0.6, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 430, options: [])

// Ripple rings
for (r, a, w) in [(268.0, 0.30, 9.0), (338.0, 0.18, 7.0), (410.0, 0.09, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setStrokeColor(rgb(0xFFFFFF, a)); ctx.setLineWidth(w)
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
}

// Bell
let cfg = NSImage.SymbolConfiguration(pointSize: 360, weight: .bold).applying(.init(paletteColors: [.white]))
if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = bell.size
    let rect = CGRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2 + 6, width: sz.width, height: sz.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: rgb(0x7A0F3A, 0.55))
    // slight playful tilt, like it's mid-ring
    ctx.translateBy(x: center.x, y: rect.maxY); ctx.rotate(by: -0.1); ctx.translateBy(x: -center.x, y: -rect.maxY)
    bell.draw(in: rect)
    // badge
    let b = CGRect(x: rect.maxX - 92, y: rect.maxY - 112, width: 104, height: 104)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(rgb(0xFF4D6D)); ctx.fillEllipse(in: b.insetBy(dx: -14, dy: -14))
    ctx.setFillColor(rgb(0xFFD166)); ctx.fillEllipse(in: b)
    ctx.restoreGState()
}

// Top gloss + inner hairline
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
