// make_icon.swift — render PortKit's app icon and emit a .icns. No art deps.
// Calm aesthetic: matte squircle, soft fog→sage→slate gradient, a soft "port"
// ring (a gateway opening) above a still water line.
// Usage: swift scripts/make_icon.swift [out.icns]
import AppKit
import CoreGraphics
import ImageIO
import Foundation

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Rounded-rect body (macOS squircle proportion), slightly inset.
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = (s - 2 * inset) * 0.235
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [rgb(237, 241, 244), rgb(168, 192, 160), rgb(107, 127, 148)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.55, 1.0])!
    // top (fog) → bottom (slate); CG y-axis points up
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Soft port ring — the "gateway" the extension passes through.
    let center = CGPoint(x: s * 0.5, y: s * 0.60)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.92))
    ctx.setLineWidth(s * 0.035)
    ctx.addArc(center: center, radius: s * 0.20, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Still water — two calm lines below.
    ctx.setStrokeColor(rgb(255, 255, 255, 0.55))
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.028)
    ctx.move(to: CGPoint(x: s * 0.30, y: s * 0.33)); ctx.addLine(to: CGPoint(x: s * 0.70, y: s * 0.33)); ctx.strokePath()
    ctx.move(to: CGPoint(x: s * 0.36, y: s * 0.26)); ctx.addLine(to: CGPoint(x: s * 0.64, y: s * 0.26)); ctx.strokePath()

    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PortKit.icns"
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = NSTemporaryDirectory() + "PortKit.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in sizes {
    let url = URL(fileURLWithPath: "\(iconset)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, drawIcon(size: px), nil)
    CGImageDestinationFinalize(dest)
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
