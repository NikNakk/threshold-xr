import AppKit
import CoreGraphics

// The Threshold app icon: a doorway (the threshold) opening onto a glowing
// virtual world. Threshold XR and its Threshold Home helper share it.
// Regenerate it from the repository root with:
//
//   swift Tools/Icons/make-icon.swift Tools/Icons/out
//
// then copy Threshold.png to Resources/AppIcon.png and to
// ThresholdHome/Resources/AppIcon.png. preview.png shows it at Dock sizes.

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

/// The macOS icon shape: an 824pt rounded square on a 1024 canvas.
func tilePath() -> CGPath {
    CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
}

/// Door opening: straight sides, rounded top corners.
func doorPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
    p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
    p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.closeSubpath()
    return p
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Core Graphics origin is bottom-left.

    // Soft drop shadow under the tile, as macOS icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath()); ctx.setFillColor(color(0x0b1430)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath()); ctx.clip()

    // Room: deep navy wall above, slightly lighter floor below.
    ctx.drawLinearGradient(gradient([(0, color(0x101c44)), (1, color(0x050a1e))]),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    let floorY: CGFloat = 330
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: size, height: floorY))
    ctx.drawLinearGradient(gradient([(0, color(0x0d1838)), (1, color(0x070d24))]),
                           start: CGPoint(x: 0, y: floorY), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    let door = CGRect(x: 342, y: floorY, width: 340, height: 470)
    let doorShape = doorPath(door, radius: 46)

    // Light spilling out of the doorway across the floor towards the viewer.
    ctx.saveGState()
    let spill = CGMutablePath()
    spill.move(to: CGPoint(x: door.minX, y: floorY))
    spill.addLine(to: CGPoint(x: door.maxX, y: floorY))
    spill.addLine(to: CGPoint(x: door.maxX + 250, y: 60))
    spill.addLine(to: CGPoint(x: door.minX - 250, y: 60))
    spill.closeSubpath()
    ctx.addPath(spill); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x7fe3ff, 0.55)), (0.55, color(0x3d8bff, 0.14)), (1, color(0x3d8bff, 0))]),
                           start: CGPoint(x: 0, y: floorY), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // Glow around the opening.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 90, color: color(0x52c8ff, 0.9))
    ctx.addPath(doorShape); ctx.setFillColor(color(0x52c8ff)); ctx.fillPath()
    ctx.restoreGState()

    // The world beyond: bright horizon, sky and a perspective grid floor.
    ctx.saveGState()
    ctx.addPath(doorShape); ctx.clip()
    let horizon = door.minY + door.height * 0.36
    ctx.drawLinearGradient(gradient([(0, color(0xffffff)), (0.12, color(0xc8f4ff)), (0.5, color(0x5cc2ff)), (1, color(0x2a5bd6))]),
                           start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: door.maxY), options: [])
    ctx.drawLinearGradient(gradient([(0, color(0xffffff)), (0.25, color(0x8fe0ff)), (1, color(0x2f74e8))]),
                           start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: door.minY), options: [])
    // Grid: lines converging on a vanishing point on the horizon.
    let vanish = CGPoint(x: door.midX, y: horizon)
    ctx.setStrokeColor(color(0xffffff, 0.75))
    ctx.setLineWidth(5)
    for i in -6...6 {
        ctx.move(to: vanish)
        ctx.addLine(to: CGPoint(x: door.midX + CGFloat(i) * 120, y: door.minY - 10))
    }
    ctx.strokePath()
    // Horizontal grid lines, closer together towards the horizon.
    for k in 1...5 {
        let t = pow(CGFloat(k) / 5, 1.8)
        let y = horizon - (horizon - door.minY) * t
        ctx.setLineWidth(2 + 4 * t)
        ctx.move(to: CGPoint(x: door.minX, y: y)); ctx.addLine(to: CGPoint(x: door.maxX, y: y))
        ctx.strokePath()
    }
    // Sun glow on the horizon.
    ctx.drawRadialGradient(gradient([(0, color(0xffffff, 0.95)), (1, color(0xffffff, 0))]),
                           startCenter: vanish, startRadius: 0, endCenter: vanish, endRadius: 150, options: [])
    ctx.restoreGState()

    // Door frame and bright sill: the threshold itself.
    ctx.addPath(doorShape)
    ctx.setStrokeColor(color(0xd9f6ff)); ctx.setLineWidth(14); ctx.strokePath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xaef0ff))
    ctx.setFillColor(color(0xffffff))
    ctx.fill(CGRect(x: door.minX - 34, y: floorY - 10, width: door.width + 68, height: 18))
    ctx.restoreGState()

    ctx.restoreGState()

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: name))
}

let icon = render()
write(icon, "Threshold.png")

// Preview sheet: the icon at large and Dock/Finder sizes, on light and dark.
let sheet = CGContext(data: nil, width: 1000, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(color(0xf2f2f5)); sheet.fill(CGRect(x: 0, y: 450, width: 1000, height: 450))
sheet.setFillColor(color(0x1e1e22)); sheet.fill(CGRect(x: 0, y: 0, width: 1000, height: 450))
sheet.interpolationQuality = .high
for y: CGFloat in [470, 20] {
    sheet.draw(icon, in: CGRect(x: 30, y: y, width: 400, height: 400))
    var x: CGFloat = 480
    for s: CGFloat in [128, 64, 32] {
        sheet.draw(icon, in: CGRect(x: x, y: y + 200 - s / 2, width: s, height: s))
        x += s + 40
    }
}
write(sheet.makeImage()!, "preview.png")
