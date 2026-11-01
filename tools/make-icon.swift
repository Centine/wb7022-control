// Draws the app icon: the webcam in profile as a line sketch, clipped over a
// monitor edge. Original artwork, no Dell assets.
//
//   swift tools/make-icon.swift Resources/AppIcon.icns
//
// Writes an .iconset next to the output and converts it with iconutil.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")

/// Draws at 1024×1024 points; the context is scaled for smaller sizes.
func draw(in ctx: CGContext) {
    // Background: macOS icon grid, 824 pt rounded square centred on 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.20, green: 0.24, blue: 0.30, alpha: 1),
                                       CGColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let ink = CGColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
    let faint = CGColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 0.3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Monitor: the top of a display panel, seen from the side, running off the tile.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
    let panel = CGPath(roundedRect: CGRect(x: 340, y: 40, width: 160, height: 348), cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.addPath(panel)
    ctx.fillPath()
    ctx.setStrokeColor(faint)
    ctx.setLineWidth(12)
    ctx.addPath(panel)
    ctx.strokePath()

    // Field of view, fanning out from the lens.
    ctx.setLineWidth(12)
    ctx.setLineDash(phase: 0, lengths: [2, 34])
    ctx.move(to: CGPoint(x: 770, y: 640))
    ctx.addLine(to: CGPoint(x: 960, y: 760))
    ctx.move(to: CGPoint(x: 770, y: 560))
    ctx.addLine(to: CGPoint(x: 960, y: 440))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.restoreGState()

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(24)

    // Clip: plate on the panel's top edge, leg down behind it, short lip in front.
    let clip = CGMutablePath()
    clip.move(to: CGPoint(x: 316, y: 250))
    clip.addLine(to: CGPoint(x: 316, y: 400))
    clip.addLine(to: CGPoint(x: 524, y: 400))
    clip.addLine(to: CGPoint(x: 524, y: 336))
    ctx.addPath(clip)
    ctx.strokePath()

    // Hinge and neck up to the camera.
    ctx.move(to: CGPoint(x: 420, y: 400))
    ctx.addLine(to: CGPoint(x: 420, y: 426))
    ctx.strokePath()
    ctx.addEllipse(in: CGRect(x: 396, y: 426, width: 48, height: 48))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 420, y: 474))
    ctx.addLine(to: CGPoint(x: 420, y: 500))
    ctx.strokePath()

    // Camera body: a rounded capsule, lens end facing right.
    let body = CGPath(roundedRect: CGRect(x: 220, y: 500, width: 420, height: 200), cornerWidth: 100, cornerHeight: 100, transform: nil)
    ctx.addPath(body)
    ctx.strokePath()

    // Lens: a short barrel at the front, the glass as a curved face.
    let barrel = CGMutablePath()
    barrel.move(to: CGPoint(x: 628, y: 548))
    barrel.addLine(to: CGPoint(x: 700, y: 548))
    barrel.addQuadCurve(to: CGPoint(x: 700, y: 652), control: CGPoint(x: 758, y: 600))
    barrel.addLine(to: CGPoint(x: 628, y: 652))
    ctx.addPath(barrel)
    ctx.strokePath()

    // A seam along the body, and the status light.
    ctx.setStrokeColor(faint)
    ctx.setLineWidth(14)
    ctx.move(to: CGPoint(x: 300, y: 600))
    ctx.addLine(to: CGPoint(x: 520, y: 600))
    ctx.strokePath()
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 560, y: 640, width: 20, height: 20))
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(output.path)")
