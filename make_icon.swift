#!/usr/bin/env swift
// Generates AppIcon.iconset/ for LocalShot.app (then build.sh runs `iconutil`).
// Pure CoreGraphics, fully offline: squircle gradient + viewfinder brackets +
// a dashed "capture region" marquee. Run: swift make_icon.swift

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func draw(px: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    // thicken strokes at tiny sizes so the motif stays legible
    let boost: CGFloat = px <= 32 ? 1.6 : (px <= 64 ? 1.25 : 1)

    // Squircle background, diagonal indigo -> violet gradient.
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let bg = CGPath(roundedRect: rect, cornerWidth: 230, cornerHeight: 230, transform: nil)
    let grad = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        CGColor(red: 0.58, green: 0.32, blue: 0.99, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
    // faint sheen from the top
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.15),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 560), options: [])
    ctx.restoreGState()

    // Inner hairline, like most macOS icons.
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerWidth: 227, cornerHeight: 227, transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()

    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // Viewfinder corner brackets.
    let m: CGFloat = 236, arm: CGFloat = 160
    func bracket(_ cx: CGFloat, _ cy: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + dx * arm, y: cy))
        p.addLine(to: CGPoint(x: cx, y: cy))
        p.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
        ctx.addPath(p)
    }
    bracket(m, 1024 - m, 1, -1)         // top left
    bracket(1024 - m, 1024 - m, -1, -1) // top right
    bracket(m, m, 1, 1)                 // bottom left
    bracket(1024 - m, m, -1, 1)         // bottom right
    ctx.setStrokeColor(white)
    ctx.setLineWidth(44 * boost)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Dashed "capture region" marquee, the app's core gesture.
    let marquee = CGRect(x: 362, y: 362, width: 300, height: 300)
    ctx.addPath(CGPath(roundedRect: marquee, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(26 * boost)
    ctx.setLineDash(phase: 0, lengths: [64, 46])
    ctx.strokePath()

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
