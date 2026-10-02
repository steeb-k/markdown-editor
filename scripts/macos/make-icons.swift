// Draws the app icon and the document icon with CoreGraphics and writes iconsets, then (with
// `--icns`) runs iconutil on them. Reproducible: the .icns files in apps/macos/Resources are
// this script's output.
//
//   swift scripts/macos/make-icons.swift <out-dir>             iconsets (Markdown.iconset, MarkdownDocument.iconset)
//   swift scripts/macos/make-icons.swift <out-dir> --icns      also Markdown.icns and MarkdownDocument.icns
//   swift scripts/macos/make-icons.swift <out-dir> --png 1024  one master PNG per icon, for looking at
//
// Design: Apple's icon grid (a 824 pt rounded plate on a 1024 pt canvas, 100 pt of margin that holds
// the shadow), a calm paper-coloured plate, and a mark in the app's own blue that says "writing in
// Markdown": a bold heading hash beside a text caret. At 32 px and below the strokes thicken and
// the mark grows so that it still reads.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The app's blues (crates/markdown-core/themes/light.toml: link and caret).
let hashBlue = CGColor(srgbRed: 0x18 / 255, green: 0x59 / 255, blue: 0xC9 / 255, alpha: 1)
let caretBlue = CGColor(srgbRed: 0x1E / 255, green: 0x78 / 255, blue: 0xF0 / 255, alpha: 1)
let paperTop = CGColor(srgbRed: 0xFD / 255, green: 0xFC / 255, blue: 0xF8 / 255, alpha: 1)
let paperBottom = CGColor(srgbRed: 0xEC / 255, green: 0xEA / 255, blue: 0xE2 / 255, alpha: 1)
let ink = CGColor(srgbRed: 0.15, green: 0.16, blue: 0.17, alpha: 1)

func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1])!
}

/// A superellipse-cornered rounded rectangle (Apple's continuous corners, close enough).
func plate(_ r: CGRect, corner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    // Continuous corner: the curve starts 1.528 * radius from the corner, as in Apple's template.
    let k = min(corner * 1.2, r.width / 2)
    let c = corner
    p.move(to: CGPoint(x: r.minX + k, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + k), control1: CGPoint(x: r.maxX - k + c * 0.75, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + k - c * 0.75))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
    p.addCurve(to: CGPoint(x: r.maxX - k, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - k + c * 0.75), control2: CGPoint(x: r.maxX - k + c * 0.75, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - k), control1: CGPoint(x: r.minX + k - c * 0.75, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - k + c * 0.75))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
    p.addCurve(to: CGPoint(x: r.minX + k, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + k - c * 0.75), control2: CGPoint(x: r.minX + k - c * 0.75, y: r.minY))
    p.closeSubpath()
    return p
}

/// The hash and the caret, drawn in 1024-unit coordinates around `center`. `scale` and `weight`
/// grow for small renderings.
func drawMark(_ g: CGContext, center: CGPoint, scale: CGFloat, weight: CGFloat, caret: Bool) {
    g.saveGState()
    g.translateBy(x: center.x, y: center.y)
    g.scaleBy(x: scale, y: scale)
    // The hash: two slanted verticals and two horizontals with round ends.
    let half: CGFloat = 178
    let slant: CGFloat = 0.13
    let gap: CGFloat = 122          // half the distance between the verticals, at the middle
    let bar: CGFloat = 92           // half the distance between the horizontals
    let reach: CGFloat = 160        // half the length of a horizontal
    let hashX: CGFloat = caret ? -112 : 0
    g.setLineCap(.round)
    g.setLineWidth(weight)
    g.setStrokeColor(hashBlue)
    for sx in [-gap, gap] {
        g.move(to: CGPoint(x: hashX + sx - slant * half, y: -half))
        g.addLine(to: CGPoint(x: hashX + sx + slant * half, y: half))
    }
    for y in [-bar, bar] {
        g.move(to: CGPoint(x: hashX - reach + slant * y, y: y))
        g.addLine(to: CGPoint(x: hashX + reach + slant * y, y: y))
    }
    g.strokePath()
    if caret {
        // The caret: a rounded vertical bar with a little serif at each end, like an I-beam.
        let x: CGFloat = 205, ch: CGFloat = 190
        g.setStrokeColor(caretBlue)
        g.setLineWidth(weight * 0.8)
        g.move(to: CGPoint(x: x, y: -ch)); g.addLine(to: CGPoint(x: x, y: ch))
        g.strokePath()
    }
    g.restoreGState()
}

func render(kind: String, size: Int) -> CGImage {
    let s = CGFloat(size)
    let k = s / 1024
    let g = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    g.interpolationQuality = .high
    g.scaleBy(x: k, y: k)
    // Strokes thicken, and the mark grows, as the icon shrinks.
    let small = size <= 32
    let weight = max(72, 1.45 / k)
    let scale: CGFloat = small ? 1.0 : (size <= 64 ? 1.0 : 1)

    if kind == "app" {
        let r = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = plate(r, corner: 186)
        // Shadow under the plate.
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -10 / 1), blur: size >= 64 ? 28 : 12, color: CGColor(gray: 0, alpha: 0.30))
        g.addPath(path)
        g.setFillColor(paperBottom)
        g.fillPath()
        g.restoreGState()
        // Paper.
        g.saveGState()
        g.addPath(path)
        g.clip()
        g.drawLinearGradient(gradient(paperTop, paperBottom), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        // A hairline of light along the top edge, and a fine edge all round.
        g.restoreGState()
        if size >= 64 {
            g.addPath(path)
            g.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
            g.setLineWidth(3)
            g.strokePath()
        }
        // Two quiet lines of text under the mark, big sizes only.
        if size >= 128 {
            g.setLineCap(.round)
            g.setStrokeColor(CGColor(gray: 0.62, alpha: 0.55))
            g.setLineWidth(30)
            g.move(to: CGPoint(x: 262, y: 262)); g.addLine(to: CGPoint(x: 762, y: 262))
            g.move(to: CGPoint(x: 262, y: 188 + 6)); g.addLine(to: CGPoint(x: 585, y: 188 + 6))
            g.strokePath()
        }
        let lift: CGFloat = size >= 128 ? 70 : 0
        drawMark(g, center: CGPoint(x: 512 + 36 * scale, y: 512 + lift), scale: size >= 128 ? 0.92 : scale, weight: size >= 128 ? 68 : weight, caret: true)
    } else {
        // A page with a folded corner and a hash on it.
        let w: CGFloat = 640, h: CGFloat = 820, fold: CGFloat = 170
        let x0 = (1024 - w) / 2, y0 = (1024 - h) / 2
        let page = CGMutablePath()
        page.move(to: CGPoint(x: x0, y: y0 + 40))
        page.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + 40, y: y0), radius: 40)
        page.addArc(tangent1End: CGPoint(x: x0 + w, y: y0), tangent2End: CGPoint(x: x0 + w, y: y0 + 40), radius: 40)
        page.addLine(to: CGPoint(x: x0 + w, y: y0 + h - fold))
        page.addLine(to: CGPoint(x: x0 + w - fold, y: y0 + h))
        page.addArc(tangent1End: CGPoint(x: x0, y: y0 + h), tangent2End: CGPoint(x: x0, y: y0 + h - 40), radius: 40)
        page.closeSubpath()
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -8), blur: size >= 64 ? 22 : 8, color: CGColor(gray: 0, alpha: 0.28))
        g.addPath(page); g.setFillColor(paperBottom); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.addPath(page); g.clip()
        g.drawLinearGradient(gradient(paperTop, paperBottom), start: CGPoint(x: 512, y: y0 + h), end: CGPoint(x: 512, y: y0), options: [])
        g.restoreGState()
        g.addPath(page); g.setStrokeColor(CGColor(gray: 0, alpha: 0.16)); g.setLineWidth(max(3, 1 / k)); g.strokePath()
        // The fold.
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: x0 + w - fold, y: y0 + h))
        corner.addLine(to: CGPoint(x: x0 + w - fold, y: y0 + h - fold))
        corner.addLine(to: CGPoint(x: x0 + w, y: y0 + h - fold))
        corner.closeSubpath()
        g.addPath(corner); g.setFillColor(CGColor(gray: 0.86, alpha: 1)); g.fillPath()
        g.addPath(corner); g.setStrokeColor(CGColor(gray: 0, alpha: 0.16)); g.setLineWidth(max(3, 1 / k)); g.strokePath()
        drawMark(g, center: CGPoint(x: 512, y: 470), scale: small ? 0.85 : 0.8, weight: small ? max(80, 1.6 / k) : 70, caret: false)
        if size >= 128 {
            g.setLineCap(.round)
            g.setStrokeColor(CGColor(gray: 0.62, alpha: 0.55))
            g.setLineWidth(28)
            g.move(to: CGPoint(x: x0 + 110, y: y0 + 120)); g.addLine(to: CGPoint(x: x0 + w - 110, y: y0 + 120))
            g.strokePath()
        }
    }
    return g.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("cannot write \(url.path)") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let outPath = args.first else { print("usage: make-icons.swift <out-dir> [--icns] [--png size]"); exit(2) }
let out = URL(fileURLWithPath: outPath, isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

if let i = args.firstIndex(of: "--png"), i + 1 < args.count, let size = Int(args[i + 1]) {
    for (kind, name) in [("app", "Markdown"), ("document", "MarkdownDocument")] {
        writePNG(render(kind: kind, size: size), to: out.appendingPathComponent("\(name)-\(size).png"))
    }
    exit(0)
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
for (kind, name) in [("app", "Markdown"), ("document", "MarkdownDocument")] {
    let set = out.appendingPathComponent("\(name).iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: set)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for (label, px) in sizes {
        writePNG(render(kind: kind, size: px), to: set.appendingPathComponent("icon_\(label).png"))
    }
    if args.contains("--icns") {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("\(name).icns").path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { fatalError("iconutil failed for \(name)") }
    }
}
