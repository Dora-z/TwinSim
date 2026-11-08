// Renders the TwinSim app icon into an .iconset directory: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.09
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(red: 0.10, green: 0.16, blue: 0.32, alpha: 1).cgColor,
                                       NSColor(red: 0.18, green: 0.42, blue: 0.86, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])
    ctx.restoreGState()

    func phone(_ center: CGPoint, color: NSColor, screen: NSColor, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let w = s * 0.30, h = s * 0.54
        let body = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: w * 0.2, cornerHeight: w * 0.2, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let glass = body.insetBy(dx: w * 0.07, dy: w * 0.07)
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: w * 0.14, cornerHeight: w * 0.14, transform: nil))
        ctx.setFillColor(screen.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    phone(CGPoint(x: s * 0.40, y: s * 0.50), color: NSColor(white: 0.92, alpha: 1),
          screen: NSColor(red: 0.36, green: 0.82, blue: 0.55, alpha: 1), angle: 0.16)
    phone(CGPoint(x: s * 0.60, y: s * 0.49), color: NSColor(white: 0.98, alpha: 1),
          screen: NSColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1), angle: -0.12)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
