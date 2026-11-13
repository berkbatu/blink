// Renders Blink's 1024px app icon: flat, solid colors only — a white bell ringing on coral.
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
let coral: UInt32 = 0xFF5C61

// Soft drop shadow (neutral), then a solid coral body
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.3))
ctx.addPath(shape); ctx.setFillColor(rgb(coral)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let center = CGPoint(x: 512, y: 492)

// Flat concentric rings
for (r, a) in [(410.0, 0.07), (330.0, 0.09), (250.0, 0.12)] as [(CGFloat, CGFloat)] {
    ctx.setFillColor(rgb(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
}

// Bell, mid-ring
let cfg = NSImage.SymbolConfiguration(pointSize: 340, weight: .bold).applying(.init(paletteColors: [.white]))
if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = bell.size
    let rect = CGRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2 + 6, width: sz.width, height: sz.height)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: rect.maxY); ctx.rotate(by: -0.1); ctx.translateBy(x: -center.x, y: -rect.maxY)
    bell.draw(in: rect)
    let b = CGRect(x: rect.maxX - 92, y: rect.maxY - 108, width: 100, height: 100)
    ctx.setFillColor(rgb(coral)); ctx.fillEllipse(in: b.insetBy(dx: -16, dy: -16))
    ctx.setFillColor(rgb(0xFFD166)); ctx.fillEllipse(in: b)
    ctx.restoreGState()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
