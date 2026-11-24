// Draws the OMNIS icons: the Halo mark.
//
//   swift macos/scripts/make-icon.swift macos/Resources
//
// Writes AppIcon.icns (the Dock icon) and MenuIcon.png / MenuIcon@2x.png (the
// menu-bar glyph, drawn in black so macOS can tint it). The results are kept
// in the repo, so this only needs running again when the design changes.
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)

/// The three arcs of the mark, in a 200-unit square: radius, sweep in degrees, and where each starts.
let arcs: [(radius: CGFloat, sweep: CGFloat, start: CGFloat)] = [(72, 238.7, -110), (50, 229.2, 40), (28, 225.1, 170)]

func context(_ pixels: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flipped, so angles run the same way as in the design drawing.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func arcPath(_ arc: (radius: CGFloat, sweep: CGFloat, start: CGFloat), centre: CGPoint, scale: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let from = arc.start * .pi / 180
    path.addArc(center: centre, radius: arc.radius * scale, startAngle: from, endAngle: from + arc.sweep * .pi / 180, clockwise: false)
    return path
}

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func save(_ ctx: CGContext, to url: URL) {
    let image = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! image.representation(using: .png, properties: [:])!.write(to: url)
}

/// The Dock icon at one size.
func appIcon(_ pixels: Int) -> CGContext {
    let ctx = context(pixels)
    let size = CGFloat(pixels)
    // The rounded square macOS icons sit on, with the usual margin around it.
    let inset = size * 0.098
    let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let plateShape = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.225, cornerHeight: plate.width * 0.225, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    let ground = CGGradient(colorsSpace: space, colors: [colour(0x1A222D), colour(0x06080B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: plate.minX, y: plate.minY), end: CGPoint(x: plate.maxX, y: plate.maxY), options: [])
    // A faint warm light behind the mark.
    let warm = CGGradient(colorsSpace: space, colors: [colour(0xF2C14E, 0.16), colour(0xF2C14E, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(warm, startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: plate.width * 0.5, options: [])
    ctx.restoreGState()
    ctx.addPath(plateShape)
    ctx.setStrokeColor(colour(0xFFFFFF, 0.10))
    ctx.setLineWidth(max(1, size / 512))
    ctx.strokePath()

    let centre = CGPoint(x: size / 2, y: size / 2)
    let scale = plate.width / 200 * 0.86
    let stroke = 8.6 * scale
    ctx.setLineCap(.round)

    // The glow, drawn first.
    if pixels >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 7 * scale, color: colour(0xF2C14E, 0.75))
        ctx.setStrokeColor(colour(0xF2C14E, 0.5))
        ctx.setLineWidth(stroke)
        for arc in arcs { ctx.addPath(arcPath(arc, centre: centre, scale: scale)) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The arcs themselves, in graded gold.
    let gold = CGGradient(colorsSpace: space, colors: [colour(0xFFF1C2), colour(0xF2C14E), colour(0x9C6E12)] as CFArray, locations: [0, 0.45, 1])!
    for arc in arcs {
        ctx.saveGState()
        ctx.addPath(arcPath(arc, centre: centre, scale: scale))
        ctx.setLineWidth(stroke)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let reach = 80 * scale
        ctx.drawLinearGradient(gold, start: CGPoint(x: centre.x - reach, y: centre.y - reach),
                               end: CGPoint(x: centre.x + reach, y: centre.y + reach), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // The bright centre.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 9 * scale, color: colour(0xF2C14E, 0.9))
    ctx.setFillColor(colour(0xFFF1C2))
    ctx.fillEllipse(in: CGRect(x: centre.x - 8 * scale, y: centre.y - 8 * scale, width: 16 * scale, height: 16 * scale))
    ctx.restoreGState()
    ctx.setFillColor(colour(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: centre.x - 4 * scale, y: centre.y - 4 * scale, width: 8 * scale, height: 8 * scale))
    return ctx
}

/// The menu-bar glyph: the same mark in solid black, heavier so it holds at 18 points.
func menuIcon(_ pixels: Int) -> CGContext {
    let ctx = context(pixels)
    let size = CGFloat(pixels)
    let centre = CGPoint(x: size / 2, y: size / 2)
    let scale = size / 200 * 1.18
    ctx.setLineCap(.round)
    ctx.setStrokeColor(colour(0x000000))
    ctx.setLineWidth(15 * scale)
    for arc in arcs { ctx.addPath(arcPath(arc, centre: centre, scale: scale)) }
    ctx.strokePath()
    ctx.setFillColor(colour(0x000000))
    ctx.fillEllipse(in: CGRect(x: centre.x - 9 * scale, y: centre.y - 9 * scale, width: 18 * scale, height: 18 * scale))
    return ctx
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("OMNIS-\(UUID().uuidString).iconset", isDirectory: true)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    save(appIcon(points * scale), to: iconset.appendingPathComponent(name))
}
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try! convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

save(menuIcon(18), to: output.appendingPathComponent("MenuIcon.png"))
save(menuIcon(36), to: output.appendingPathComponent("MenuIcon@2x.png"))
print(convert.terminationStatus == 0 ? "Wrote the icons to \(output.path)" : "iconutil failed")
