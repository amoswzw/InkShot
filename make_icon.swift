#!/usr/bin/env swift
// Generates AppIcon.iconset/ for Inkshot.app (then build.sh runs `iconutil`) and the same
// images as Assets.xcassets/AppIcon.appiconset for the Xcode build.
// Pure CoreGraphics, fully offline, in Chinese ink-painting style: rice paper, four
// calligraphic brush strokes as a capture viewfinder, an ensō circle, and a red seal.
// Run: swift make_icon.swift

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers
import CoreText

// Deterministic RNG so the hand-drawn jitter is identical at every icon size.
struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func sym(_ a: CGFloat) -> CGFloat { CGFloat(unit() * 2 - 1) * a }
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let inkColor = CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
let paperTop = CGColor(red: 0.97, green: 0.94, blue: 0.87, alpha: 1)
let paperBottom = CGColor(red: 0.91, green: 0.86, blue: 0.75, alpha: 1)

/// Catmull-Rom resampling, so a few control points become a smooth stroke spine.
func smooth(_ c: [CGPoint], samples: Int) -> [CGPoint] {
    var out: [CGPoint] = []
    for i in 0..<samples {
        let f = CGFloat(i) / CGFloat(samples - 1) * CGFloat(c.count - 1)
        let k = min(Int(f), c.count - 2), t = f - CGFloat(k)
        let p0 = c[max(k - 1, 0)], p1 = c[k], p2 = c[k + 1], p3 = c[min(k + 2, c.count - 1)]
        func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
        }
        out.append(CGPoint(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y)))
    }
    return out
}

/// A calligraphic brush stroke: pressed down wide at the start, lifting toward a thin
/// tip, with dry-brush streaks (飞白) where the ink runs out near the end.
func brush(_ ctx: CGContext, _ control: [CGPoint], width: CGFloat, dry: Bool, rng: inout RNG) {
    let pts = smooth(control, samples: 120)
    func profile(_ t: CGFloat) -> CGFloat {
        if t < 0.07 { return 0.55 + 0.45 * sin(t / 0.07 * .pi / 2) }   // the press
        if t < 0.62 { return 1 - 0.18 * ((t - 0.07) / 0.55) }          // the pull
        return 0.82 * pow(1 - (t - 0.62) / 0.38, 1.3) + 0.03           // the lift to a point
    }
    // Low-frequency edge noise: ink soaking unevenly into paper, not a sawtooth.
    func wobble() -> [CGFloat] {
        let raw = (0..<pts.count).map { _ in rng.sym(1) }
        return raw.indices.map { i in
            let win = raw[max(i - 4, 0)...min(i + 4, raw.count - 1)]
            return win.reduce(0, +) / CGFloat(win.count) * 0.12
        }
    }
    let nl = wobble(), nr = wobble()
    var left: [CGPoint] = [], right: [CGPoint] = []
    for (i, p) in pts.enumerated() {
        let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
        let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
        let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
        let w = width * profile(CGFloat(i) / CGFloat(pts.count - 1)) / 2
        let wl = w * (1 + nl[i]), wr = w * (1 + nr[i])
        left.append(CGPoint(x: p.x + nx * wl, y: p.y + ny * wl))
        right.append(CGPoint(x: p.x - nx * wr, y: p.y - ny * wr))
    }
    let shape = CGMutablePath()
    shape.addLines(between: left + right.reversed())
    shape.closeSubpath()
    ctx.addPath(shape); ctx.setFillColor(inkColor); ctx.fillPath()

    guard dry else { return }
    // Dry brush: paper-colored streaks running along the last part of the stroke.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.setStrokeColor(CGColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 0.9)); ctx.setLineCap(.butt)
    for _ in 0..<9 {
        let off = rng.sym(0.4), from = 0.66 + rng.unit() * 0.16
        let streak = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let t = CGFloat(i) / CGFloat(pts.count - 1)
            guard t >= CGFloat(from) else { continue }
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let q = CGPoint(x: p.x - (b.y - a.y) / len * width * off, y: p.y + (b.x - a.x) / len * width * off)
            if streak.isEmpty { streak.move(to: q) } else { streak.addLine(to: q) }
        }
        ctx.addPath(streak); ctx.setLineWidth(1.5 + CGFloat(rng.unit()) * 3)
        ctx.setLineDash(phase: CGFloat(rng.unit()) * 40, lengths: [18 + CGFloat(rng.unit()) * 40, 4 + CGFloat(rng.unit()) * 14])
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func draw(px: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    // Fine detail (fibers, dry brush, the seal's character) turns to noise at tiny sizes,
    // and strokes need extra weight there to stay legible.
    let small = px <= 64
    let boost: CGFloat = px <= 32 ? 1.35 : (px <= 64 ? 1.15 : 1)
    var rng = RNG(state: 0x1A4C_5EED_2026)   // fixed seed → identical at all sizes

    // Rice-paper squircle.
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let bg = CGPath(roundedRect: rect, cornerWidth: 230, cornerHeight: 230, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [paperTop, paperBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 300, y: 1024), end: CGPoint(x: 724, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Pale ink wash (淡墨) bleeding into the paper behind the frame.
    for (cx, cy, r, a) in [(430.0, 470.0, 400.0, 0.13), (600.0, 600.0, 300.0, 0.08), (380.0, 330.0, 260.0, 0.07)] {
        let wash = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: a),
            CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(wash, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [])
    }
    if !small {   // paper fibers
        ctx.setLineCap(.round)
        for _ in 0..<260 {
            let p = CGPoint(x: rng.unit() * 1024, y: rng.unit() * 1024)
            let ang = rng.unit() * 2 * .pi, len = 14 + rng.unit() * 40
            let f = CGMutablePath()
            f.move(to: p)
            f.addQuadCurve(to: CGPoint(x: p.x + cos(ang) * len, y: p.y + sin(ang) * len),
                           control: CGPoint(x: p.x + cos(ang + 0.6) * len / 2, y: p.y + sin(ang + 0.6) * len / 2))
            ctx.addPath(f)
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.47, blue: 0.33, alpha: 0.06 + rng.unit() * 0.06))
            ctx.setLineWidth(1.5 + rng.unit() * 2)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Inner hairline, like most macOS icons.
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerWidth: 227, cornerHeight: 227, transform: nil))
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.38, blue: 0.27, alpha: 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // Viewfinder: four corner brackets, each one turning stroke (横折) — entering on one
    // arm, rounding the corner, and lifting off dry along the other.
    let lo: CGFloat = 238, hi: CGFloat = 786, arm: CGFloat = 210, w: CGFloat = 62 * boost
    for (cx, cy, sx, sy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (hi, lo, -1.0, 1.0), (lo, lo, 1.0, 1.0)] {
        let h = CGFloat(sx) * arm, v = CGFloat(sy) * arm
        let start = CGPoint(x: cx + h, y: cy + rng.sym(8)), end = CGPoint(x: cx + rng.sym(8), y: cy + v)
        brush(ctx, [start, CGPoint(x: cx + h * 0.5, y: cy + rng.sym(5)), CGPoint(x: cx + h * 0.12, y: cy),
                    CGPoint(x: cx, y: cy), CGPoint(x: cx, y: cy + v * 0.12),
                    CGPoint(x: cx + rng.sym(5), y: cy + v * 0.5), end],
              width: w, dry: !small, rng: &rng)
    }

    // An ensō (圆相) in the middle of the frame: one brush circle, left open where the
    // brush lifts — ink-painting's classic single stroke, and a camera lens here.
    let ec = CGPoint(x: 512, y: 512), er: CGFloat = 148
    let a0 = Double.pi * 0.15, sweep = -Double.pi * 1.8
    let ring = (0...16).map { i -> CGPoint in
        let a = a0 + sweep * Double(i) / 16
        let r = er * (1 + rng.sym(0.025))
        return CGPoint(x: ec.x + r * CGFloat(cos(a)), y: ec.y + r * CGFloat(sin(a)))
    }
    brush(ctx, ring, width: 58 * boost, dry: !small, rng: &rng)

    // Vermilion seal (朱印) stamped in the lower right, reading 墨 ("ink").
    let seal = CGRect(x: 812, y: 112, width: 118, height: 118)
    ctx.addPath(CGPath(roundedRect: seal, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(CGColor(red: 0.78, green: 0.17, blue: 0.13, alpha: 1)); ctx.fillPath()
    if !small {
        let font = CTFontCreateWithName("STKaitiSC-Bold" as CFString, 92, nil)
        let text = NSAttributedString(string: "墨", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: seal.midX - b.midX, y: seal.midY - b.midY)
        CTLineDraw(line, ctx)
    }

    return ctx.makeImage()
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in sizes {
    guard let img = draw(px: px),
          let dest = CGImageDestinationCreateWithURL(
              iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("render failed for \(name)") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
print("wrote \(iconset.path)/")

// The same images as an asset catalog app icon, which the Xcode (App Store) build compiles.
let appiconset = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset")
try? fm.removeItem(at: appiconset)
try! fm.createDirectory(at: appiconset, withIntermediateDirectories: true)
var images: [String] = []
for (name, _) in sizes {
    try! fm.copyItem(at: iconset.appendingPathComponent(name), to: appiconset.appendingPathComponent(name))
    let base = name.replacingOccurrences(of: "icon_", with: "").replacingOccurrences(of: ".png", with: "")
    let scale = base.hasSuffix("@2x") ? "2x" : "1x"
    let pt = base.replacingOccurrences(of: "@2x", with: "")
    images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)", "size" : "\#(pt)" }"#)
}
try! ("{\n  \"images\" : [\n    " + images.joined(separator: ",\n    ")
      + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n")
    .write(to: appiconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
    .write(to: URL(fileURLWithPath: "Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(appiconset.path)/")
