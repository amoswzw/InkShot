// Inkshot — a private, local-only screenshot & annotation app for macOS.
// Capture and recording use ScreenCaptureKit; annotation is native AppKit.
// No networking anywhere.

import Cocoa
import CoreImage
import Carbon.HIToolbox
import UniformTypeIdentifiers
import ServiceManagement
import ScreenCaptureKit
import AVFoundation
import QuartzCore

// MARK: - Model

enum Tool: Int, CaseIterable {
    case select, rect, ellipse, arrow, line, pen, marker, text, number, mosaic, blur, crop
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rect: return "rectangle"; case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"; case .line: return "line.diagonal"
        case .pen: return "pencil.tip"; case .marker: return "highlighter"
        case .text: return "character"; case .number: return "number.circle"
        case .mosaic: return "square.grid.3x3.fill"; case .blur: return "drop.fill"
        case .crop: return "crop"
        }
    }
    var glyph: String {
        switch self {
        case .select: return "⌖"
        case .rect: return "▭"; case .ellipse: return "◯"; case .arrow: return "➔"
        case .line: return "╱"; case .pen: return "✎"; case .marker: return "▰"
        case .text: return "T"; case .number: return "①"; case .mosaic: return "▦"
        case .blur: return "☁"; case .crop: return "⌗"
        }
    }
    var help: String {
        switch self {
        case .select: return "Select / move"
        case .rect: return "Rectangle"; case .ellipse: return "Ellipse"; case .arrow: return "Arrow"
        case .line: return "Line"; case .pen: return "Pen"; case .marker: return "Highlighter"
        case .text: return "Text"; case .number: return "Numbered step"; case .mosaic: return "Mosaic (pixelate)"
        case .blur: return "Blur"
        case .crop: return "Crop — drag, then press Return"
        }
    }
}

struct Op {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    var rect: CGRect = .zero
    var p1: CGPoint = .zero
    var p2: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var fontSize: CGFloat = 28
    var origin: CGPoint = .zero
    var number: Int = 0
    // Stable per-shape seed so the hand-drawn jitter doesn't shimmer on redraw
    // (same idea as Excalidraw storing a seed per element).
    var seed: UInt64 = .random(in: .min ... .max)
}

/// Small deterministic RNG so each shape's sketchy perturbations are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - UI building blocks

/// Rice paper, ink and a vermilion seal: the palette every window shares with the app icon.
/// Dark mode flips to an ink-black ground with paper-colored ink.
enum Ink {
    private static func dyn(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat),
                            alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { ap in
            let c = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        }
    }
    private static let inkL = (0.11 as CGFloat, 0.105 as CGFloat, 0.10 as CGFloat)
    private static let inkD = (0.93 as CGFloat, 0.90 as CGFloat, 0.83 as CGFloat)
    static let paper = dyn((0.965, 0.945, 0.89), (0.12, 0.115, 0.11))
    static let wash = dyn((0.915, 0.89, 0.825), (0.175, 0.17, 0.16))     // grouped surfaces, canvas surround
    static let ink = dyn(inkL, inkD)
    static let inkSoft = dyn(inkL, inkD, alpha: 0.68)
    static let inkFaint = dyn(inkL, inkD, alpha: 0.09)
    static let inkGhost = dyn(inkL, inkD, alpha: 0.25)
    static let seal = dyn((0.76, 0.17, 0.13), (0.84, 0.29, 0.23))
    static let sealText = NSColor(srgbRed: 0.98, green: 0.95, blue: 0.88, alpha: 1)   // cream in both modes

    /// Gives a standard window the rice-paper ground, title bar included.
    static func dress(_ w: NSWindow) {
        w.backgroundColor = paper
        w.titlebarAppearsTransparent = true
    }
}

/// Keeps the editor's canvas centered when it is smaller than the viewport
/// (a plain NSClipView pins it to the bottom-left corner).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView?.frame else { return r }
        if r.width > doc.width { r.origin.x = doc.minX - (r.width - doc.width) / 2 }
        if r.height > doc.height { r.origin.y = doc.minY - (r.height - doc.height) / 2 }
        return r
    }
}

/// A plain surface filled with a (dynamic) theme color; follows light/dark changes.
final class InkSurface: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(color: NSColor, radius: CGFloat = 0) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}

/// A thin brush line, swelling in the middle and lifting at both ends.
final class BrushRule: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY, w = bounds.width, n = 48
        let p = NSBezierPath()
        var lower: [CGPoint] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let half = 0.25 + 0.9 * sin(t * .pi)
            lower.append(CGPoint(x: t * w, y: y - half))
            if i == 0 { p.move(to: CGPoint(x: 0, y: y + half)) } else { p.line(to: CGPoint(x: t * w, y: y + half)) }
        }
        for q in lower.reversed() { p.line(to: q) }
        p.close()
        Ink.inkGhost.setFill(); p.fill()
    }
}

/// Draws a hint chip the ink way: ink lettering on rice paper with a faint ink edge and a
/// soft shadow, so it reads over any screen content. `layout` turns the text size into the
/// chip's rect; the text is centered in it.
@discardableResult
func drawInkChip(_ text: String, font: NSFont, radius: CGFloat, layout: (NSSize) -> NSRect) -> NSRect {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ink.ink]
    let sz = (text as NSString).size(withAttributes: attrs)
    let box = layout(sz)
    let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.set()
    Ink.paper.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    Ink.inkGhost.setStroke(); path.lineWidth = 1; path.stroke()
    (text as NSString).draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2), withAttributes: attrs)
    return box
}

/// A text button drawn in ink: `.stamp` is a filled vermilion seal for the main action,
/// `.outline` is ink-bordered.
final class InkButton: NSButton {
    enum Style { case stamp, outline }
    private let style: Style
    private let text: String

    init(title: String, style: Style, target: AnyObject?, action: Selector) {
        self.style = style
        self.text = title
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 7
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 26, height: 34)
    }
    override var isHighlighted: Bool { didSet { layer?.opacity = isHighlighted ? 0.75 : 1 } }
    override func viewDidChangeEffectiveAppearance() { refresh() }
    // The keyboard focus ring follows the rounded shape instead of a square box around it.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (style == .stamp ? Ink.seal : NSColor.clear).cgColor
            layer?.borderWidth = style == .outline ? 1.3 : 0
            layer?.borderColor = Ink.inkSoft.cgColor
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: inkFont(15, bold: style == .stamp), .paragraphStyle: para,
            .foregroundColor: style == .stamp ? Ink.sealText : Ink.ink])
    }
}

/// Borderless, layer-backed icon button with hover and selection states.
final class IconButton: NSButton {
    var isSelectedTool = false { didSet { refresh() } }
    private var hovering = false

    init(symbol: String, fallbackGlyph: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 8
        title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.isTemplate = true
            image = img
            imagePosition = .imageOnly
        } else {
            title = fallbackGlyph
            imagePosition = .noImage
            font = .systemFont(ofSize: 18)
        }
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        refresh()
    }
    /// Build a button from a pre-rendered (hand-drawn) template image.
    init(toolImage: NSImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 8
        title = ""
        image = toolImage
        imagePosition = .imageOnly
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { refresh() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { refresh() }

    // The selected tool is a solid dab of ink with the glyph left in paper.
    private func refresh() {
        let (fill, tint): (NSColor, NSColor) =
            isSelectedTool ? (Ink.ink, Ink.paper)
            : !isEnabled ? (.clear, Ink.inkGhost)
            : hovering ? (Ink.inkFaint, Ink.ink)
            : (.clear, Ink.inkSoft)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
        contentTintColor = tint
    }
}

/// A round color swatch with a selection ring.
final class SwatchButton: NSButton {
    let swatch: NSColor
    var isSelectedSwatch = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        swatch = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 25).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 18
        let r = NSRect(x: (bounds.width - d)/2, y: (bounds.height - d)/2, width: d, height: d)
        let dot = NSBezierPath(ovalIn: r)
        swatch.setFill(); dot.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke(); dot.lineWidth = 1; dot.stroke()
        if isSelectedSwatch {
            let ring = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24))
            Ink.ink.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
    }
}

/// A rounded cluster of related toolbar controls on a paper-wash ground.
final class InkGroup: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Ink.wash.cgColor }
}

/// Groups related controls into one cluster. Every group is the same height, so
/// the toolbar's clusters line up top and bottom whatever they hold.
func pill(_ views: [NSView], spacing: CGFloat = 3) -> NSStackView {
    let s = InkGroup(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    s.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    s.translatesAutoresizingMaskIntoConstraints = false
    s.heightAnchor.constraint(equalToConstant: 44).isActive = true
    s.wantsLayer = true
    s.layer?.cornerRadius = 10
    return s
}

// MARK: - Hand-drawn UI helpers

/// Handwriting UI font (falls back to the system font if none is installed).
func inkFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
    let names = bold
        ? ["Bradley Hand Bold", "Noteworthy Bold", "Chalkboard SE Bold", "Bradley Hand", "Noteworthy"]
        : ["Bradley Hand", "Noteworthy", "Chalkboard SE", "Marker Felt"]
    for n in names { if let f = NSFont(name: n, size: size) { return f } }
    return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
}

func jittered(_ p: CGPoint, _ amp: CGFloat, _ rng: inout SplitMix64) -> CGPoint {
    CGPoint(x: p.x + .random(in: -amp...amp, using: &rng), y: p.y + .random(in: -amp...amp, using: &rng))
}

/// Two overlapping wobbly strokes between a and b — the core sketch primitive. The second
/// stroke wobbles `secondPass` times as much as the first.
func appendRoughLine(_ path: NSBezierPath, _ a: CGPoint, _ b: CGPoint, amp: CGFloat,
                     secondPass: CGFloat = 0.7, rng: inout SplitMix64) {
    let m1 = CGPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3)
    let m2 = CGPoint(x: a.x + 2 * (b.x - a.x) / 3, y: a.y + 2 * (b.y - a.y) / 3)
    for pass in 0..<2 {
        let o = amp * (pass == 0 ? 1 : secondPass)
        path.move(to: jittered(a, o, &rng))
        path.curve(to: jittered(b, o, &rng), controlPoint1: jittered(m1, o, &rng), controlPoint2: jittered(m2, o, &rng))
    }
}

/// Smooth curve through the points (Catmull-Rom → cubic Bézier).
func appendCatmullRom(_ path: NSBezierPath, _ p: [CGPoint]) {
    guard p.count >= 2 else { return }
    path.move(to: p[0])
    for i in 0..<p.count - 1 {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }
}

/// Appends a sketchy (hand-drawn) rectangle border — two wobbly strokes per edge.
func appendRoughRect(_ path: NSBezierPath, _ rect: NSRect, amp: CGFloat, seed: UInt64) {
    var rng = SplitMix64(seed)
    let tl = CGPoint(x: rect.minX, y: rect.maxY), tr = CGPoint(x: rect.maxX, y: rect.maxY)
    let br = CGPoint(x: rect.maxX, y: rect.minY), bl = CGPoint(x: rect.minX, y: rect.minY)
    for (a, b) in [(tl, tr), (tr, br), (br, bl), (bl, tl)] { appendRoughLine(path, a, b, amp: amp, rng: &rng) }
}

/// A hand-drawn template glyph for an editor tool (sketchy, matches the app icon).
func toolGlyphImage(_ tool: Tool) -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
        var rng = SplitMix64(UInt64(tool.rawValue) &* 0x9E3779B1 &+ 1)
        func j(_ p: CGPoint, _ a: CGFloat) -> CGPoint { jittered(p, a, &rng) }
        func rl(_ path: NSBezierPath, _ a: CGPoint, _ b: CGPoint, _ amp: CGFloat) { appendRoughLine(path, a, b, amp: amp, rng: &rng) }
        let curveThrough = appendCatmullRom
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        NSColor.black.setStroke(); NSColor.black.setFill()
        let p = NSBezierPath(); p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
        switch tool {
        case .rect:
            rl(p,P(4,5),P(16,5),0.6); rl(p,P(16,5),P(16,15),0.6); rl(p,P(16,15),P(4,15),0.6); rl(p,P(4,15),P(4,5),0.6); p.stroke()
        case .ellipse:
            var pts:[CGPoint]=[]; let st = Double.random(in: 0...1, using: &rng)
            for i in 0...16 { let a = st + Double(i)/14*2*Double.pi; pts.append(j(P(10+CGFloat(cos(a))*6, 10+CGFloat(sin(a))*5), 0.5)) }
            curveThrough(p, pts); p.stroke()
        case .line: rl(p,P(4,5),P(16,15),0.7); p.stroke()
        case .arrow:
            let tip = P(16,15); rl(p,P(4,5),tip,0.6); rl(p,tip,P(11,15.5),0.5); rl(p,tip,P(15.5,10),0.5); p.stroke()
        case .pen:
            let pts = [P(4,6),P(7,12),P(10,6),P(13,12),P(16,7)].map { j($0, 0.3) }
            curveThrough(p, pts); p.stroke()
        case .marker:
            let mp = NSBezierPath(); mp.lineWidth = 5; mp.lineCapStyle = .round; rl(mp,P(5,6),P(15,13),0.4)
            NSColor.black.withAlphaComponent(0.5).setStroke(); mp.stroke()
        case .text:
            let a: [NSAttributedString.Key: Any] = [.font: inkFont(17, bold: true), .foregroundColor: NSColor.black]
            let sz = ("A" as NSString).size(withAttributes: a)
            ("A" as NSString).draw(at: P((20 - sz.width) / 2, (20 - sz.height) / 2 - 1), withAttributes: a)
        case .number:
            var pts:[CGPoint]=[]; for i in 0...16 { let a = Double(i)/14*2*Double.pi; pts.append(j(P(10+CGFloat(cos(a))*6.5, 10+CGFloat(sin(a))*6.5), 0.5)) }
            curveThrough(p, pts); p.stroke()
            let a: [NSAttributedString.Key: Any] = [.font: inkFont(12, bold: true), .foregroundColor: NSColor.black]
            let sz = ("1" as NSString).size(withAttributes: a)
            ("1" as NSString).draw(at: P(10 - sz.width / 2, 10 - sz.height / 2), withAttributes: a)
        case .mosaic:
            for gx in 0..<3 { for gy in 0..<3 where (gx+gy)%2==0 {
                NSBezierPath(rect: NSRect(x: 4+CGFloat(gx)*4, y: 4+CGFloat(gy)*4, width: 3.4, height: 3.4)).fill() } }
        case .blur:
            for k in 0..<3 { let y = 6+CGFloat(k)*4; let wp = NSBezierPath(); wp.lineWidth = 1.4; wp.lineCapStyle = .round
                var pts:[CGPoint]=[]; for i in 0...8 { pts.append(P(4+CGFloat(i)/8*12, y+CGFloat(sin(Double(i)*0.9)))) }
                wp.move(to: pts[0]); for i in 1..<pts.count { wp.line(to: pts[i]) }
                NSColor.black.withAlphaComponent(0.75).setStroke(); wp.stroke() }
        case .crop:
            rl(p,P(6,3),P(6,14),0.4); rl(p,P(6,14),P(17,14),0.4)
            rl(p,P(3,6),P(14,6),0.4); rl(p,P(14,6),P(14,17),0.4); p.stroke()
        case .select:
            let c = NSBezierPath(); c.lineWidth = 1.4; c.lineJoinStyle = .round; c.lineCapStyle = .round
            c.move(to: P(5,16)); c.line(to: P(5,5)); c.line(to: P(8.5,8.3)); c.line(to: P(10.5,4))
            c.line(to: P(12,4.7)); c.line(to: P(10,9)); c.line(to: P(14,9)); c.close(); c.stroke()
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Canvas

final class CanvasView: NSView {
    var baseImage: NSImage
    private(set) var pixelSize: NSSize
    private var ops: [Op] = []
    // The capture in color: grayscale is made from it, and turning grayscale off restores it.
    private var sourceImage: NSImage
    private(set) var isGray = false
    // Undo snapshots carry the image too, since cropping and grayscale replace it.
    private struct State { var ops: [Op]; var image: NSImage; var source: NSImage; var gray: Bool; var size: NSSize }
    private var undone: [State] = []
    private var redoStack: [State] = []

    var currentTool: Tool = .rect {
        didSet { selected = nil; cropRect = nil; needsDisplay = true }
    }
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28

    private var draft: Op?
    private var dragStart: CGPoint?
    private var selected: Int?
    private var moveStart: CGPoint?
    private var movePushed = false
    private var isMoving = false
    private var isResizing = false
    private var resizeHandle: Int?
    private var pressHitIndex: Int?
    private var viewScale: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var ciContext = CIContext(options: nil)
    private lazy var baseCI: CIImage? =
        baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CIImage(cgImage: $0) }
    private var textField: NSTextField?
    private var pendingTextOrigin: CGPoint?
    private var editingTextIndex: Int?
    // Pending crop (Crop tool). cropHandle: 0–7 resize, 8 move, nil draws a new rect.
    private var cropRect: CGRect? { didSet { if cropRect != oldValue { onCropChange?(cropRect) } } }
    private var cropHandle: Int?
    private var cropAnchor: CGPoint = .zero
    private var cropOriginal: CGRect = .zero

    var onHistoryChange: (() -> Void)?
    var onImageResize: (() -> Void)?
    var onCropChange: ((CGRect?) -> Void)?

    init(image: NSImage, pixelSize: NSSize) {
        self.baseImage = image
        self.sourceImage = image
        self.pixelSize = pixelSize
        super.init(frame: NSRect(origin: .zero, size: pixelSize))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    var canUndo: Bool { !undone.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)
        for (i, op) in ops.enumerated() where i != editingTextIndex { drawOp(op) }
        if let d = draft { drawOp(d) }
        if let i = selected, i < ops.count {
            let inset = 6 / viewScale
            let box = boundingBox(ops[i]).insetBy(dx: -inset, dy: -inset)
            let sel = NSBezierPath(rect: box)
            sel.lineWidth = 1.5 / viewScale
            sel.setLineDash([5 / viewScale, 3 / viewScale], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            sel.stroke()
            drawHandles(ops[i])
        }
        if let r = cropRect { drawCrop(r) }
    }

    private func drawCrop(_ r: CGRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(r)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill(); shade.fill()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1.5 / viewScale
        border.setLineDash([6 / viewScale, 4 / viewScale], count: 2, phase: 0)
        NSColor.white.setStroke(); border.stroke()
        drawHandleSquares(rectHandles(r).map { $0.1 })

        let pad = 6 / viewScale
        drawInkChip("\(Int(r.width)) × \(Int(r.height))", font: inkFont(13 / viewScale), radius: 5 / viewScale) { sz in
            var box = NSRect(x: r.minX, y: r.maxY + pad, width: sz.width + 2 * pad, height: sz.height + pad)
            if box.maxY > bounds.maxY { box.origin.y = r.maxY - box.height - pad }
            box.origin.x = min(max(box.minX, bounds.minX), bounds.maxX - box.width)
            return box
        }
    }

    private func drawOp(_ op: Op) {
        op.color.setStroke()
        op.color.setFill()
        switch op.tool {
        case .select, .crop:
            break
        case .rect:
            var rng = SplitMix64(op.seed)
            let r = op.rect
            let tl = CGPoint(x: r.minX, y: r.maxY), tr = CGPoint(x: r.maxX, y: r.maxY)
            let br = CGPoint(x: r.maxX, y: r.minY), bl = CGPoint(x: r.minX, y: r.minY)
            let p = roughPath(op.width)
            addRoughLine(p, tl, tr, &rng); addRoughLine(p, tr, br, &rng)
            addRoughLine(p, br, bl, &rng); addRoughLine(p, bl, tl, &rng)
            p.stroke()
        case .ellipse:
            var rng = SplitMix64(op.seed)
            let p = roughPath(op.width)
            addRoughEllipse(p, op.rect, &rng); p.stroke()
        case .line:
            var rng = SplitMix64(op.seed)
            let p = roughPath(op.width)
            addRoughLine(p, op.p1, op.p2, &rng); p.stroke()
        case .arrow:
            drawArrow(op)
        case .pen:
            strokePolyline(op.points, width: op.width)
        case .marker:
            op.color.withAlphaComponent(0.3).setStroke()
            strokePolyline(op.points, width: op.width * 4)
        case .text:
            drawText(op)
        case .number:
            drawNumber(op)
        case .mosaic, .blur:
            drawRegion(op)
        }
    }

    // MARK: hand-drawn (Rough.js-style) rendering

    private func roughPath(_ width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }
    /// A rough line whose wobble scales with its length.
    private func addRoughLine(_ path: NSBezierPath, _ a: CGPoint, _ b: CGPoint, _ rng: inout SplitMix64) {
        let len = max(hypot(b.x - a.x, b.y - a.y), 1)
        appendRoughLine(path, a, b, amp: min(max(len * 0.02, 1.5), 6), secondPass: 0.75, rng: &rng)
    }
    private func addRoughEllipse(_ path: NSBezierPath, _ rect: CGRect, _ rng: inout SplitMix64) {
        let cx = rect.midX, cy = rect.midY, rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return }
        let amp = min(max(min(rx, ry) * 0.06, 1.5), 6)
        let steps = max(14, Int((rx + ry) / 10))
        for _ in 0..<2 {
            let start = Double.random(in: 0...(.pi / 3), using: &rng)
            var pts: [CGPoint] = []
            for i in 0...(steps + 2) {   // overshoot so the loop closes with a sketchy overlap
                let t = start + Double(i) / Double(steps) * 2 * .pi
                let base = CGPoint(x: cx + CGFloat(cos(t)) * rx, y: cy + CGFloat(sin(t)) * ry)
                pts.append(jittered(base, amp, &rng))
            }
            appendCatmullRom(path, pts)
        }
    }
    private func strokePolyline(_ pts: [CGPoint], width: CGFloat) {
        guard pts.count > 1 else {
            if let p = pts.first {
                let r = NSRect(x: p.x - width/2, y: p.y - width/2, width: width, height: width)
                NSBezierPath(ovalIn: r).fill()
            }
            return
        }
        let path = NSBezierPath()
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: pts[0])
        for i in 1..<pts.count { path.line(to: pts[i]) }
        path.stroke()
    }

    private func drawArrow(_ op: Op) {
        var rng = SplitMix64(op.seed)
        let dx = op.p2.x - op.p1.x, dy = op.p2.y - op.p1.y
        let len = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)
        let headLen = min(max(op.width * 5, 18), len * 0.9)
        let headHalf = max(op.width * 2, headLen * 0.5)
        let base = CGPoint(x: op.p2.x - headLen * cos(angle),
                           y: op.p2.y - headLen * sin(angle))
        let px = -sin(angle), py = cos(angle)
        let b1 = CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf)
        let b2 = CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf)
        // Sketchy shaft plus an open "V" head (two rough strokes) like Excalidraw.
        let p = roughPath(op.width)
        addRoughLine(p, op.p1, op.p2, &rng)
        addRoughLine(p, op.p2, b1, &rng)
        addRoughLine(p, op.p2, b2, &rng)
        p.stroke()
    }

    private func drawText(_ op: Op) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: inkFont(op.fontSize),
            .foregroundColor: op.color
        ]
        (op.text as NSString).draw(at: op.origin, withAttributes: attrs)
    }

    private func drawNumber(_ op: Op) {
        let r = max(op.width * 3, 16)
        let circle = NSRect(x: op.origin.x - r, y: op.origin.y - r, width: r * 2, height: r * 2)
        op.color.setFill(); NSBezierPath(ovalIn: circle).fill()
        let s = "\(op.number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: r * 1.1),
            .foregroundColor: NSColor.white
        ]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: op.origin.x - sz.width/2, y: op.origin.y - sz.height/2), withAttributes: attrs)
    }

    private func drawRegion(_ op: Op) {
        guard op.rect.width > 2, op.rect.height > 2, let ci = baseCI else { return }
        let sx = ci.extent.width / bounds.width
        let sy = ci.extent.height / bounds.height
        let pr = CGRect(x: op.rect.origin.x * sx, y: op.rect.origin.y * sy,
                        width: op.rect.width * sx, height: op.rect.height * sy)
        let filter: CIFilter?
        if op.tool == .blur {
            filter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: ci.clampedToExtent(),
                kCIInputRadiusKey: min(60, max(12, min(pr.width, pr.height) / 3))])
        } else {
            filter = CIFilter(name: "CIPixellate", parameters: [
                kCIInputImageKey: ci,
                kCIInputScaleKey: max(8, min(pr.width, pr.height) / 10),
                kCIInputCenterKey: CIVector(x: pr.midX, y: pr.midY)])
        }
        guard let out = filter?.outputImage,
              let cg = ciContext.createCGImage(out, from: pr) else { return }
        NSGraphicsContext.current?.cgContext.draw(cg, in: op.rect)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .crop { cropDown(at: p, clickCount: event.clickCount); return }
        if event.clickCount == 2, let i = markIndex(at: p), ops[i].tool == .text {
            editText(at: i); return
        }
        // The selected mark stays editable in any tool: resize by its handles,
        // move by its body. No need to switch to the Select tool between edits.
        if let i = selected, i < ops.count {
            if let h = handleHit(ops[i], at: p) {
                isResizing = true; resizeHandle = h; moveStart = p; movePushed = false
                return
            }
            if hits(ops[i], at: p) {
                isMoving = true; moveStart = p; movePushed = false
                NSCursor.closedHand.set()
                return
            }
        }
        // Select tool: click any mark to select (then move/resize), or deselect.
        if currentTool == .select {
            if let hit = markIndex(at: p) {
                selected = hit; moveStart = p; movePushed = false; isMoving = true
                NSCursor.closedHand.set(); needsDisplay = true
                return
            }
            selected = nil; needsDisplay = true
            return
        }
        // Drawing tools: dragging from empty draws; a plain click selects a mark.
        pressHitIndex = markIndex(at: p)
        selected = nil
        switch currentTool {
        case .select:
            break
        case .text:
            beginText(at: p)
        case .number:
            pushHistory()
            var op = Op(tool: .number, color: currentColor, width: currentWidth)
            op.origin = p; op.number = nextNumber(for: currentColor)
            ops.append(op); redoStack.removeAll(); needsDisplay = true; onHistoryChange?()
        default:
            dragStart = p
            var op = Op(tool: currentTool, color: currentColor, width: currentWidth)
            op.fontSize = currentFontSize
            if currentTool == .pen || currentTool == .marker { op.points = [p] }
            draft = op
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if currentTool == .crop { cropDragged(to: p); return }
        if isResizing {
            guard let i = selected, i < ops.count, let h = resizeHandle else { return }
            if !movePushed { pushHistory(); redoStack.removeAll(); movePushed = true }
            ops[i] = resize(ops[i], handle: h, to: p)
            needsDisplay = true; onHistoryChange?()
            return
        }
        if isMoving {
            guard let i = selected, let s = moveStart, i < ops.count else { return }
            if !movePushed { pushHistory(); redoStack.removeAll(); movePushed = true }
            ops[i] = translate(ops[i], dx: p.x - s.x, dy: p.y - s.y)
            moveStart = p; needsDisplay = true; onHistoryChange?()
            return
        }
        guard var op = draft, let s = dragStart else { return }
        switch op.tool {
        case .pen, .marker:
            op.points.append(p)
        case .line, .arrow:
            op.p1 = s; op.p2 = p
        default:
            op.rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(s.x - p.x), height: abs(s.y - p.y))
        }
        draft = op; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if currentTool == .crop {
            if let r = cropRect, r.width < 4 || r.height < 4 { cropRect = nil; needsDisplay = true }
            return
        }
        if isResizing { isResizing = false; resizeHandle = nil; moveStart = nil; return }
        if isMoving { isMoving = false; moveStart = nil; NSCursor.arrow.set(); return }
        guard let op = draft else {
            // A plain click (no draft) on a mark selects it for editing.
            if let hit = pressHitIndex { selected = hit; needsDisplay = true }
            pressHitIndex = nil
            return
        }
        draft = nil; dragStart = nil
        let trivial: Bool
        switch op.tool {
        case .rect, .ellipse, .mosaic, .blur: trivial = op.rect.width < 3 || op.rect.height < 3
        case .line, .arrow: trivial = hypot(op.p2.x - op.p1.x, op.p2.y - op.p1.y) < 4
        case .pen, .marker: trivial = op.points.count < 2
        default: trivial = true
        }
        if !trivial {
            pushHistory(); ops.append(op); redoStack.removeAll()
            // Keep resizable marks selected so their handles are ready immediately.
            selected = handlePoints(op).isEmpty ? nil : ops.count - 1
        } else if let hit = pressHitIndex {
            selected = hit   // click landed on an existing mark: select it
        }
        pressHitIndex = nil
        needsDisplay = true; onHistoryChange?()
    }

    override func keyDown(with event: NSEvent) {
        if currentTool == .crop, cropRect != nil {
            if event.keyCode == 36 || event.keyCode == 76 { applyCrop(); return }   // return / enter
            if event.keyCode == 53 { cancelCrop(); return }
        }
        if let i = selected, i < ops.count {
            if event.keyCode == 51 || event.keyCode == 117 {   // delete / forward delete
                pushHistory(); ops.remove(at: i); selected = nil
                redoStack.removeAll()
                needsDisplay = true; onHistoryChange?(); return
            }
            if event.keyCode == 53 {   // escape
                selected = nil; needsDisplay = true; return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: hit-testing & moving

    private func hits(_ op: Op, at p: CGPoint) -> Bool {
        let tol = max(op.width, 8 / max(viewScale, 0.01))
        switch op.tool {
        case .line, .arrow:
            return distance(p, seg: op.p1, op.p2) <= tol
        case .pen, .marker:
            let pts = op.points
            guard pts.count > 1 else { return false }
            for j in 1..<pts.count where distance(p, seg: pts[j-1], pts[j]) <= tol { return true }
            return false
        default:
            return boundingBox(op).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }

    private func markIndex(at p: CGPoint) -> Int? {
        for i in ops.indices.reversed() where hits(ops[i], at: p) { return i }
        return nil
    }

    private func translate(_ op: Op, dx: CGFloat, dy: CGFloat) -> Op {
        var o = op
        o.rect = o.rect.offsetBy(dx: dx, dy: dy)
        o.p1 = CGPoint(x: o.p1.x + dx, y: o.p1.y + dy)
        o.p2 = CGPoint(x: o.p2.x + dx, y: o.p2.y + dy)
        o.origin = CGPoint(x: o.origin.x + dx, y: o.origin.y + dy)
        o.points = o.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return o
    }

    private func boundingBox(_ op: Op) -> CGRect {
        switch op.tool {
        case .rect, .ellipse, .mosaic, .blur:
            return op.rect
        case .line, .arrow:
            return CGRect(x: min(op.p1.x, op.p2.x), y: min(op.p1.y, op.p2.y),
                          width: abs(op.p1.x - op.p2.x), height: abs(op.p1.y - op.p2.y))
        case .pen, .marker:
            guard let first = op.points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for pt in op.points { r = r.union(CGRect(origin: pt, size: .zero)) }
            return r
        case .text:
            let sz = (op.text as NSString).size(withAttributes: [.font: inkFont(op.fontSize)])
            return CGRect(x: op.origin.x, y: op.origin.y, width: sz.width, height: sz.height)
        case .number:
            let r = max(op.width * 3, 16)
            return CGRect(x: op.origin.x - r, y: op.origin.y - r, width: r * 2, height: r * 2)
        case .select, .crop:
            return .zero
        }
    }

    private func distance(_ p: CGPoint, seg a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx*dx + dy*dy
        if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }

    // MARK: resize handles
    // Rect-like marks get 8 handles (corners + edge midpoints); lines get 2 endpoints.
    private func handlePoints(_ op: Op) -> [(Int, CGPoint)] {
        switch op.tool {
        case .rect, .ellipse, .mosaic, .blur:
            return rectHandles(op.rect)
        case .line, .arrow:
            return [(0, op.p1), (1, op.p2)]
        default:
            return []   // pen, marker, text, number: move only
        }
    }

    private func rectHandles(_ r: CGRect) -> [(Int, CGPoint)] {
        [(0, CGPoint(x: r.minX, y: r.minY)), (1, CGPoint(x: r.midX, y: r.minY)),
         (2, CGPoint(x: r.maxX, y: r.minY)), (3, CGPoint(x: r.maxX, y: r.midY)),
         (4, CGPoint(x: r.maxX, y: r.maxY)), (5, CGPoint(x: r.midX, y: r.maxY)),
         (6, CGPoint(x: r.minX, y: r.maxY)), (7, CGPoint(x: r.minX, y: r.midY))]
    }

    private func handleHit(_ op: Op, at p: CGPoint) -> Int? {
        handleHit(handlePoints(op), at: p)
    }
    private func handleHit(_ handles: [(Int, CGPoint)], at p: CGPoint) -> Int? {
        let tol = max(9 / viewScale, 6)
        for (id, c) in handles where hypot(p.x - c.x, p.y - c.y) <= tol { return id }
        return nil
    }

    private func drawHandles(_ op: Op) { drawHandleSquares(handlePoints(op).map { $0.1 }) }
    private func drawHandleSquares(_ points: [CGPoint]) {
        let s = 7 / viewScale
        for c in points {
            let r = NSRect(x: c.x - s/2, y: c.y - s/2, width: s, height: s)
            NSColor.white.setFill(); NSBezierPath(rect: r).fill()
            let b = NSBezierPath(rect: r); b.lineWidth = 1 / viewScale
            NSColor.controlAccentColor.setStroke(); b.stroke()
        }
    }

    private func resize(_ op: Op, handle: Int, to p: CGPoint) -> Op {
        var o = op
        switch o.tool {
        case .line, .arrow:
            if handle == 0 { o.p1 = p } else { o.p2 = p }
        case .rect, .ellipse, .mosaic, .blur:
            o.rect = resized(o.rect, handle: handle, to: p)
        default:
            break
        }
        return o
    }

    private func resized(_ r: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        if [0, 6, 7].contains(handle) { x0 = p.x }
        if [2, 3, 4].contains(handle) { x1 = p.x }
        if [0, 1, 2].contains(handle) { y0 = p.y }
        if [4, 5, 6].contains(handle) { y1 = p.y }
        return CGRect(x: min(x0, x1), y: min(y0, y1),
                      width: max(abs(x1 - x0), 4), height: max(abs(y1 - y0), 4))
    }

    // MARK: crop

    private func cropDown(at p: CGPoint, clickCount: Int) {
        if let r = cropRect {
            if clickCount == 2, r.contains(p) { applyCrop(); return }
            cropOriginal = r; cropAnchor = p
            if let h = handleHit(rectHandles(r), at: p) { cropHandle = h; return }
            if r.contains(p) { cropHandle = 8; return }
        }
        cropHandle = nil; cropAnchor = p
        cropRect = nil; needsDisplay = true
    }

    private func cropDragged(to p: CGPoint) {
        let q = CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
        switch cropHandle {
        case 8?:
            var r = cropOriginal.offsetBy(dx: p.x - cropAnchor.x, dy: p.y - cropAnchor.y)
            r.origin.x = min(max(r.minX, 0), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.maxY - r.height)
            cropRect = r
        case let h?:
            cropRect = resized(cropOriginal, handle: h, to: q).intersection(bounds)
        case nil:
            cropRect = CGRect(x: min(cropAnchor.x, q.x), y: min(cropAnchor.y, q.y),
                              width: abs(q.x - cropAnchor.x), height: abs(q.y - cropAnchor.y))
        }
        needsDisplay = true
    }

    /// Replaces the image with the pending crop; marks move with it (and clip at the edge).
    func cancelCrop() { cropRect = nil; needsDisplay = true }

    func applyCrop() {
        guard let pending = cropRect else { return }
        cropRect = nil; needsDisplay = true
        let r = pending.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1, r != bounds,
              let cg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // Canvas units are image pixels, but scale anyway in case the bitmap differs.
        let sx = CGFloat(cg.width) / bounds.width, sy = CGFloat(cg.height) / bounds.height
        let pr = CGRect(x: r.minX * sx, y: (bounds.height - r.maxY) * sy,
                        width: r.width * sx, height: r.height * sy).integral
        guard let cropped = cg.cropping(to: pr) else { return }
        pushHistory(); redoStack.removeAll()
        // Marks the crop cuts through are dropped. Blur and mosaic are trimmed instead:
        // dropping a redaction would reveal what it hid.
        let kept = CGRect(origin: .zero, size: r.size).insetBy(dx: -1, dy: -1)
        ops = ops.map { translate($0, dx: -r.minX, dy: -r.minY) }.compactMap { op in
            if op.tool == .blur || op.tool == .mosaic {
                var o = op
                o.rect = o.rect.intersection(CGRect(origin: .zero, size: r.size))
                return o.rect.isNull || o.rect.isEmpty ? nil : o
            }
            let b = boundingBox(op)
            return b.minX >= kept.minX && b.minY >= kept.minY && b.maxX <= kept.maxX && b.maxY <= kept.maxY ? op : nil
        }
        selected = nil
        let img = NSImage(size: r.size)
        img.addRepresentation(NSBitmapImageRep(cgImage: cropped))
        if sourceImage === baseImage {
            sourceImage = img
        } else if let src = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: pr) {
            sourceImage = NSImage(size: r.size)
            sourceImage.addRepresentation(NSBitmapImageRep(cgImage: src))
        }
        setImage(img, size: r.size)
        onHistoryChange?()
    }

    /// Turns the capture gray (annotations keep their colors), or back to color.
    func toggleGray() {
        let img: NSImage
        if isGray {
            img = sourceImage
        } else {
            guard let cg = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let gray = ciContext.createCGImage(
                      CIImage(cgImage: cg).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]),
                      from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            else { return }
            img = NSImage(size: pixelSize)
            img.addRepresentation(NSBitmapImageRep(cgImage: gray))
        }
        pushHistory(); redoStack.removeAll()
        isGray.toggle()
        setImage(img, size: pixelSize)
        onHistoryChange?()
    }

    private func setImage(_ img: NSImage, size: NSSize) {
        let resized = size != pixelSize
        baseImage = img
        pixelSize = size
        baseCI = img.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CIImage(cgImage: $0) }
        setFrameSize(size)
        needsDisplay = true
        if resized { onImageResize?() }
    }

    // MARK: text entry

    private func beginText(at p: CGPoint) {
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - currentFontSize, width: 240, height: currentFontSize + 8))
        tf.font = inkFont(currentFontSize)
        tf.textColor = currentColor
        tf.drawsBackground = false
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .none
        tf.placeholderString = "Type…"
        tf.target = self; tf.action = #selector(textCommitted)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        pendingTextOrigin = p
    }

    private func editText(at i: Int) {
        let op = ops[i]
        let sz = (op.text as NSString).size(withAttributes: [.font: inkFont(op.fontSize)])
        beginText(at: op.origin)
        guard let tf = textField else { return }
        // Line the field's text up with the drawn mark so it doesn't jump.
        tf.frame = NSRect(x: op.origin.x - 4, y: op.origin.y - 4,
                          width: max(240, sz.width + 40), height: sz.height + 8)
        tf.font = inkFont(op.fontSize)
        tf.textColor = op.color
        tf.stringValue = op.text
        tf.currentEditor()?.selectAll(nil)
        editingTextIndex = i
        selected = nil; needsDisplay = true
    }

    @objc private func textCommitted() { commitText() }

    private func commitText() {
        guard let tf = textField, let origin = pendingTextOrigin else { return }
        let str = tf.stringValue
        tf.removeFromSuperview(); textField = nil; pendingTextOrigin = nil
        let empty = str.trimmingCharacters(in: .whitespaces).isEmpty
        if let i = editingTextIndex {
            editingTextIndex = nil
            if i < ops.count, ops[i].text != str {
                pushHistory()
                if empty { ops.remove(at: i) } else { ops[i].text = str; selected = i }
                redoStack.removeAll()
            } else if i < ops.count { selected = i }
        } else if !empty {
            pushHistory()
            var op = Op(tool: .text, color: currentColor, width: currentWidth)
            op.text = str; op.origin = origin; op.fontSize = currentFontSize
            ops.append(op); redoStack.removeAll()
        }
        needsDisplay = true; onHistoryChange?()
    }

    // MARK: history / edit

    private var state: State {
        State(ops: ops, image: baseImage, source: sourceImage, gray: isGray, size: pixelSize)
    }
    private func pushHistory() { undone.append(state) }
    private func restore(_ s: State) {
        ops = s.ops; selected = nil; cropRect = nil
        sourceImage = s.source; isGray = s.gray
        if s.image !== baseImage { setImage(s.image, size: s.size) }
        needsDisplay = true; onHistoryChange?()
    }

    func undo() {
        commitText()
        guard let prev = undone.popLast() else { return }
        redoStack.append(state); restore(prev)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undone.append(state); restore(next)
    }
    // Edit-menu ⌘Z / ⇧⌘Z land here while the canvas is first responder.
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    func clearAll() {
        guard !ops.isEmpty else { return }
        pushHistory(); ops.removeAll(); redoStack.removeAll()
        selected = nil; needsDisplay = true; onHistoryChange?()
    }
    private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a == b }
        let e: CGFloat = 0.004
        return abs(x.redComponent - y.redComponent) < e && abs(x.greenComponent - y.greenComponent) < e
            && abs(x.blueComponent - y.blueComponent) < e && abs(x.alphaComponent - y.alphaComponent) < e
    }

    // Numbered badges count per color: next is one past the highest badge of that color.
    private func nextNumber(for color: NSColor) -> Int {
        (ops.filter { $0.tool == .number && sameColor($0.color, color) }.map { $0.number }.max() ?? 0) + 1
    }

    // Apply the current size to the selected mark (stroke width, text size, badge radius).
    func applyCurrentSizeToSelection() {
        guard let i = selected, i < ops.count else { return }
        pushHistory(); redoStack.removeAll()
        ops[i].width = currentWidth
        ops[i].fontSize = currentFontSize
        needsDisplay = true; onHistoryChange?()
    }

    // MARK: export

    func renderedImage() -> NSImage {
        let rep = snapshot()
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
    func pngData() -> Data? {
        snapshot().representation(using: .png, properties: [:])
    }
    // cacheDisplay captures everything draw() paints plus subviews, so the
    // in-progress text field and the selection/crop chrome must be gone first.
    private func snapshot() -> NSBitmapImageRep {
        commitText()
        applyCrop()   // a pending crop is what the user sees as the result
        selected = nil
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}

// MARK: - Editor window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let canvas: CanvasView
    private var toolButtons: [IconButton] = []
    private var swatchButtons: [SwatchButton] = []
    private var undoBtn: IconButton!
    private var grayBtn: IconButton!
    private var redoBtn: IconButton!
    private var colorWell: NSColorWell!
    private var scroll: NSScrollView!
    private var cropBar: NSView!
    private let cropSize = NSTextField(labelWithString: "")

    private static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white
    ]
    // size index -> (line width, font size)
    private static let sizes: [(CGFloat, CGFloat)] = [(2, 18), (4, 28), (8, 42), (14, 64)]

    init(image: NSImage, pixelSize: NSSize) {
        canvas = CanvasView(image: image, pixelSize: pixelSize)

        // Open at most 80% of the screen in each direction, sized to the capture's aspect
        // (never larger than its real on-screen size). The toolbar sets a floor on width.
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let toolbarH: CGFloat = 60, screenShare: CGFloat = 0.8
        let fitScale = min(vis.width * screenShare / pixelSize.width,
                           (vis.height * screenShare - toolbarH) / pixelSize.height, Self.actualSize)
        let imgW = max((pixelSize.width * fitScale).rounded(), 1)
        let imgH = max((pixelSize.height * fitScale).rounded(), 1)
        let contentW = max(imgW, 820)
        let contentH = imgH + toolbarH
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Inkshot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        Ink.dress(window)

        super.init(window: window)

        // Rice-paper header bar merged with the title bar, underlined by a brush stroke.
        let header = InkSurface(color: Ink.paper)
        header.translatesAutoresizingMaskIntoConstraints = false
        let rule = BrushRule()
        rule.translatesAutoresizingMaskIntoConstraints = false

        // Tools group — hand-drawn glyphs
        for tool in Tool.allCases {
            let b = IconButton(toolImage: toolGlyphImage(tool))
            b.tag = tool.rawValue
            b.toolTip = tool.help
            b.target = self
            b.action = #selector(toolPicked(_:))
            b.isSelectedTool = (tool == .rect)
            toolButtons.append(b)
        }
        // Color group
        for (i, c) in Self.presetColors.enumerated() {
            let s = SwatchButton(color: c)
            s.tag = i
            s.toolTip = "Color"
            s.target = self
            s.action = #selector(swatchPicked(_:))
            s.isSelectedSwatch = (i == 0)
            swatchButtons.append(s)
        }
        colorWell = NSColorWell()
        colorWell.color = canvas.currentColor
        colorWell.toolTip = "Custom color"
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if #available(macOS 13.0, *) { colorWell.colorWellStyle = .minimal }

        let sizeControl = NSSegmentedControl(labels: ["S", "M", "L", "XL"],
                                             trackingMode: .selectOne,
                                             target: self, action: #selector(sizePicked(_:)))
        sizeControl.selectedSegment = 1
        sizeControl.toolTip = "Stroke / text size"
        sizeControl.font = inkFont(13, bold: true)

        grayBtn = IconButton(symbol: "circle.lefthalf.filled", fallbackGlyph: "◐")
        grayBtn.toolTip = "Grayscale — your marks keep their colors"
        grayBtn.target = self; grayBtn.action = #selector(toggleGray)

        // Right: history + actions
        undoBtn = IconButton(symbol: "arrow.uturn.backward", fallbackGlyph: "⤺")
        undoBtn.toolTip = "Undo (⌘Z)"; undoBtn.target = self; undoBtn.action = #selector(undo)
        redoBtn = IconButton(symbol: "arrow.uturn.forward", fallbackGlyph: "⤻")
        redoBtn.toolTip = "Redo (⇧⌘Z)"; redoBtn.target = self; redoBtn.action = #selector(redo)
        let clearBtn = IconButton(symbol: "trash", fallbackGlyph: "␡")
        clearBtn.toolTip = "Clear all"; clearBtn.target = self; clearBtn.action = #selector(clearAll)

        let copyBtn = InkButton(title: "Copy", style: .outline, target: self, action: #selector(copyImage))
        let saveBtn = InkButton(title: "Save", style: .stamp, target: self, action: #selector(saveImage))
        saveBtn.keyEquivalent = "s"; saveBtn.keyEquivalentModifierMask = .command

        // Assemble into equal-height grouped pills.
        let left = NSStackView(views: [pill(toolButtons), pill(swatchButtons + [colorWell]), pill([sizeControl]), pill([grayBtn])])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [pill([undoBtn, redoBtn, clearBtn]), pill([copyBtn, saveBtn], spacing: 6)])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(left)
        header.addSubview(right)
        header.addSubview(rule)

        // Scrollable canvas on a neutral backing; zoomed to fit the window.
        scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Ink.wash
        scroll.documentView = canvas
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 60),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 4),

            left.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 82),
            left.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Floating bar while a crop is pending: the size plus real Cancel / Crop buttons,
        // so the next step is obvious (Esc and Return still work).
        cropSize.font = inkFont(15)
        cropSize.textColor = Ink.inkSoft
        let cancelCropBtn = InkButton(title: "Cancel  esc", style: .outline, target: self, action: #selector(cancelCrop))
        let applyCropBtn = InkButton(title: "Crop  ↩", style: .stamp, target: self, action: #selector(applyCrop))
        let bar = pill([cropSize, cancelCropBtn, applyCropBtn], spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 6)
        bar.layer?.shadowColor = NSColor.black.cgColor
        bar.layer?.shadowOpacity = 0.25
        bar.layer?.shadowRadius = 10
        bar.layer?.shadowOffset = CGSize(width: 0, height: -3)
        bar.isHidden = true
        content.addSubview(bar)
        cropBar = bar
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -22),
        ])

        window.contentView = content
        // Ensure the window is at least wide enough for the toolbar, and open at
        // the capture's aspect where possible so there is no letterbox.
        let toolbarWidth = ceil(left.fittingSize.width + right.fittingSize.width + 82 + 20 + 14)
        let targetW = min(max(contentW, toolbarWidth), max(vis.width, toolbarWidth))
        window.contentMinSize = NSSize(width: toolbarWidth, height: 320)
        window.setContentSize(NSSize(width: targetW, height: contentH))
        window.center()
        window.delegate = self
        window.initialFirstResponder = canvas

        canvas.onImageResize = { [weak self] in self?.fitToWindow() }
        canvas.onCropChange = { [weak self] r in
            guard let self = self else { return }
            self.cropBar.isHidden = r == nil
            if let r = r { self.cropSize.stringValue = "\(Int(r.width)) × \(Int(r.height))" }
        }
        canvas.onHistoryChange = { [weak self] in
            guard let self = self else { return }
            self.undoBtn.isEnabled = self.canvas.canUndo
            self.redoBtn.isEnabled = self.canvas.canRedo
            self.grayBtn.isSelectedTool = self.canvas.isGray
        }
        undoBtn.isEnabled = false
        redoBtn.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // Zoom the capture so the whole image fits the viewport (never upscaled past 1:1).
    /// Canvas units are image pixels; on a Retina screen one point shows two of them, so a
    /// capture appears at its real size at magnification 1/scale, not 1.
    private static var actualSize: CGFloat { 1 / max(NSScreen.main?.backingScaleFactor ?? 1, 1) }

    func fitToWindow() {
        guard scroll != nil else { return }
        let avail = scroll.bounds.size
        guard avail.width > 1, avail.height > 1,
              canvas.pixelSize.width > 1, canvas.pixelSize.height > 1 else { return }
        let scale = min(avail.width / canvas.pixelSize.width, avail.height / canvas.pixelSize.height)
        let mag = min(max(scale, scroll.minMagnification), Self.actualSize)
        scroll.setMagnification(mag, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
    }

    func windowDidResize(_ notification: Notification) { fitToWindow() }
    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.editors.removeAll { $0 === self }
    }

    @objc private func toolPicked(_ sender: IconButton) {
        canvas.currentTool = Tool(rawValue: sender.tag) ?? .rect
        for b in toolButtons { b.isSelectedTool = (b === sender) }
    }
    @objc private func swatchPicked(_ sender: SwatchButton) {
        let c = Self.presetColors[sender.tag]
        canvas.currentColor = c
        colorWell.color = c
        for s in swatchButtons { s.isSelectedSwatch = (s === sender) }
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.currentColor = sender.color
        for s in swatchButtons { s.isSelectedSwatch = false }
    }
    @objc private func sizePicked(_ sender: NSSegmentedControl) {
        let (w, f) = Self.sizes[max(0, min(Self.sizes.count - 1, sender.selectedSegment))]
        canvas.currentWidth = w
        canvas.currentFontSize = f
        canvas.applyCurrentSizeToSelection()
    }
    @objc private func applyCrop() { canvas.applyCrop(); window?.makeFirstResponder(canvas) }
    @objc private func cancelCrop() { canvas.cancelCrop(); window?.makeFirstResponder(canvas) }
    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func clearAll() { canvas.clearAll() }

    @objc private func toggleGray() {
        canvas.toggleGray()
        window?.makeFirstResponder(canvas)
    }

    @objc private func copyImage() {
        let img = canvas.renderedImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        HistoryStore.shared.add(img, edited: true)
        ShelfController.shared.refreshIfVisible()
        window?.close()
    }

    @objc private func saveImage() {
        guard let data = canvas.pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Shot \(fmt.string(from: Date())).png"
        panel.directoryURL = Settings.shared.saveDirectory
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { showError(error); return }
            if let img = self?.canvas.renderedImage() { HistoryStore.shared.add(img, edited: true) }
            ShelfController.shared.refreshIfVisible()
        }
    }

    // Edit-menu ⌘C reaches here when no text field claims it first.
    @objc func copy(_ sender: Any?) { copyImage() }
}

func showError(_ error: Error) {
    NSApp.activate(ignoringOtherApps: true)
    NSAlert(error: error).runModal()
}

// MARK: - Settings

/// Persisted preferences, backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // The actions that each get a global hotkey. rawValue is the hotkey id.
    enum Action: Int, CaseIterable {
        case region = 1, window = 2, full = 3, record = 4
        var key: String {
            switch self { case .region: return "region"; case .window: return "window"
                          case .full: return "full"; case .record: return "record" }
        }
        var label: String {
            switch self { case .region: return "Region"; case .window: return "Window"
                          case .full: return "Full screen"; case .record: return "Recording" }
        }
        var defaultCode: Int {
            switch self { case .region: return kVK_ANSI_A; case .window: return kVK_ANSI_W
                          case .full: return kVK_ANSI_F; case .record: return kVK_ANSI_R }
        }
        var defaultModifiers: NSEvent.ModifierFlags {
            [.option, .command]   // ⌥⌘A / ⌥⌘W / ⌥⌘F / ⌥⌘R: rarely taken by apps
        }
        var defaultDisplay: String {
            switch self { case .region: return "⌥⌘A"; case .window: return "⌥⌘W"
                          case .full: return "⌥⌘F"; case .record: return "⌥⌘R" }
        }
    }

    private init() {
        var defs: [String: Any] = ["playSound": false, "captureFormat": "png",
                                   "openEditorAfterCapture": true, "shelfMode": "corner",
                                   "shelfPinned": true, "shelfAutoHide": false,
                                   "recordingFormat": "mp4", "appearance": "system"]
        for a in Action.allCases {
            defs["hotkey.\(a.key).code"] = a.defaultCode
            defs["hotkey.\(a.key).mods"] = Int(a.defaultModifiers.rawValue)
            defs["hotkey.\(a.key).display"] = a.defaultDisplay
        }
        d.register(defaults: defs)

        // One-time migration: adopt the ⇧⌘ capture defaults for existing installs
        // (register(defaults:) alone won't overwrite values already on disk).
        if d.integer(forKey: "hotkeyDefaultsVersion") < 2 {
            for a in Action.allCases {
                setHotkey(a, code: a.defaultCode, mods: a.defaultModifiers.rawValue, display: a.defaultDisplay)
            }
            d.set(2, forKey: "hotkeyDefaultsVersion")
        }
        // ⇧⌘W is "Close Window" in many apps; move the window hotkey off it unless rebound.
        if d.integer(forKey: "hotkeyDefaultsVersion") < 3 {
            if keyCode(.window) == kVK_ANSI_W, modifiers(.window) == NSEvent.ModifierFlags([.command, .shift]).rawValue {
                setHotkey(.window, code: kVK_ANSI_E, mods: NSEvent.ModifierFlags([.command, .shift]).rawValue, display: "⇧⌘E")
            }
            d.set(3, forKey: "hotkeyDefaultsVersion")
        }
        // Move to the ⌥⌘ family (no clash with ⇧⌘ app commands); keys the user rebound stay.
        if d.integer(forKey: "hotkeyDefaultsVersion") < 4 {
            let previous: [Action: (Int, NSEvent.ModifierFlags)] = [
                .region: (kVK_ANSI_A, [.command, .shift]), .window: (kVK_ANSI_E, [.command, .shift]),
                .full: (kVK_ANSI_F, [.command, .shift]), .record: (kVK_ANSI_R, [.control, .command])]
            for a in Action.allCases {
                guard let (code, mods) = previous[a], keyCode(a) == code, modifiers(a) == mods.rawValue else { continue }
                setHotkey(a, code: a.defaultCode, mods: a.defaultModifiers.rawValue, display: a.defaultDisplay)
            }
            d.set(4, forKey: "hotkeyDefaultsVersion")
        }
    }

    func keyCode(_ a: Action) -> Int { d.integer(forKey: "hotkey.\(a.key).code") }
    func modifiers(_ a: Action) -> UInt { UInt(d.integer(forKey: "hotkey.\(a.key).mods")) }
    func display(_ a: Action) -> String { d.string(forKey: "hotkey.\(a.key).display") ?? a.defaultDisplay }
    func setHotkey(_ a: Action, code: Int, mods: UInt, display: String) {
        d.set(code, forKey: "hotkey.\(a.key).code")
        d.set(Int(mods), forKey: "hotkey.\(a.key).mods")
        d.set(display, forKey: "hotkey.\(a.key).display")
    }

    var playSound: Bool {
        get { d.bool(forKey: "playSound") } set { d.set(newValue, forKey: "playSound") }
    }
    var captureFormat: String {
        get { d.string(forKey: "captureFormat") ?? "png" } set { d.set(newValue, forKey: "captureFormat") }
    }
    // "mp4", "mov", or "gif".
    var recordingFormat: String {
        get { d.string(forKey: "recordingFormat") ?? "mp4" } set { d.set(newValue, forKey: "recordingFormat") }
    }
    // "system" (the default), "light" (ink on rice paper), or "dark".
    var appearance: String {
        get { d.string(forKey: "appearance") ?? "system" } set { d.set(newValue, forKey: "appearance"); applyAppearance() }
    }
    func applyAppearance() {
        switch appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
    var openEditorAfterCapture: Bool {
        get { d.bool(forKey: "openEditorAfterCapture") } set { d.set(newValue, forKey: "openEditorAfterCapture") }
    }
    // "corner", "dock", "both", or "off".
    var shelfMode: String {
        get { d.string(forKey: "shelfMode") ?? "corner" } set { d.set(newValue, forKey: "shelfMode") }
    }
    var autoShowShelf: Bool { shelfMode != "off" }
    var shelfPinned: Bool {
        get { d.bool(forKey: "shelfPinned") } set { d.set(newValue, forKey: "shelfPinned") }
    }
    var shelfAutoHide: Bool {
        get { d.bool(forKey: "shelfAutoHide") } set { d.set(newValue, forKey: "shelfAutoHide") }
    }
    // Under the App Sandbox, access to a user-picked folder only survives relaunch
    // through a security-scoped bookmark; the plain path is the unsandboxed fallback.
    var saveDirectory: URL {
        get {
            if let data = d.data(forKey: "saveDirectoryBookmark") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if stale { saveBookmark(for: url) }
                    return url
                }
            }
            if let p = d.string(forKey: "saveDirectory") { return URL(fileURLWithPath: p) }
            return defaultSaveDirectory
        }
        set {
            d.set(newValue.path, forKey: "saveDirectory")
            d.removeObject(forKey: "saveDirectoryBookmark")
            saveBookmark(for: newValue)
        }
    }

    /// Runs `body` with sandbox access to the save folder held open.
    func accessingSaveDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let url = saveDirectory
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private func saveBookmark(for url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            d.set(data, forKey: "saveDirectoryBookmark")
        }
    }

    private var defaultSaveDirectory: URL {
        // Sandboxed, the Desktop is off-limits and NSHomeDirectory() is the container;
        // the real ~/Pictures is reachable through the assets.pictures entitlement.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, let pw = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
                .appendingPathComponent("Pictures", isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Carbon modifier mask for RegisterEventHotKey from Cocoa modifier flags.
func carbonFlags(from mods: NSEvent.ModifierFlags) -> UInt32 {
    var f: UInt32 = 0
    if mods.contains(.command) { f |= UInt32(cmdKey) }
    if mods.contains(.option)  { f |= UInt32(optionKey) }
    if mods.contains(.control) { f |= UInt32(controlKey) }
    if mods.contains(.shift)   { f |= UInt32(shiftKey) }
    return f
}

/// A button that records the next modifier+key combo pressed, for one action.
final class HotkeyRecorder: NSButton {
    let recordAction: Settings.Action
    private static weak var active: HotkeyRecorder?
    private var monitor: Any?
    private var resignObserver: Any?

    init(action: Settings.Action) {
        recordAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(begin)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func begin() {
        HotkeyRecorder.active?.finish()
        HotkeyRecorder.active = self
        title = "Type shortcut…"
        // Our own registered hotkeys would swallow their combos before the local monitor sees them.
        (NSApp.delegate as? AppDelegate)?.unregisterAllHotkeys()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.finish() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.finish(); return nil }   // escape cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Shift alone would make a global hotkey swallow typed capitals system-wide.
            guard !mods.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            let code = Int(event.keyCode)
            let taken = Settings.Action.allCases.contains {
                $0 != self.recordAction && Settings.shared.keyCode($0) == code && Settings.shared.modifiers($0) == mods.rawValue
            }
            if taken { NSSound.beep(); return nil }
            let display = self.symbols(mods) + self.keyName(event)
            Settings.shared.setHotkey(self.recordAction, code: code, mods: mods.rawValue, display: display)
            self.finish()
            return nil
        }
    }
    private func finish() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m); monitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        if HotkeyRecorder.active === self { HotkeyRecorder.active = nil }
        (NSApp.delegate as? AppDelegate)?.registerAllHotkeys()
        refreshTitle()
    }
    private func refreshTitle() {
        let ok = (NSApp.delegate as? AppDelegate)?.hotkeyRefs[recordAction] != nil
        title = Settings.shared.display(recordAction) + (ok ? "" : " (unavailable)")
    }
    private func keyName(_ event: NSEvent) -> String {
        let names: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let n = names[Int(event.keyCode)] { return n }
        // Unlike charactersIgnoringModifiers, this also drops shift/option (⇧2 → "2", not "@").
        return (event.characters(byApplyingModifiers: []) ?? "").uppercased()
    }
    private func symbols(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController {
    private let formatOrder = ["png", "jpg", "tiff", "pdf"]
    private let shelfOrder = ["corner", "off"]
    private let recordingOrder = ["mp4", "mov", "gif"]
    private let appearanceOrder = ["system", "light", "dark"]
    private var saveButton: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 462),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Inkshot Settings"
        window.isReleasedWhenClosed = false
        Ink.dress(window)
        super.init(window: window)

        func recorder(_ a: Settings.Action) -> HotkeyRecorder {
            let r = HotkeyRecorder(action: a)
            r.widthAnchor.constraint(equalToConstant: 140).isActive = true
            return r
        }

        let soundCheck = NSButton(checkboxWithTitle: "Play shutter sound when capturing",
                                  target: self, action: #selector(toggleSound(_:)))
        soundCheck.state = Settings.shared.playSound ? .on : .off

        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: ["PNG", "JPEG", "TIFF", "PDF"])
        formatPopup.selectItem(at: formatOrder.firstIndex(of: Settings.shared.captureFormat) ?? 0)
        formatPopup.target = self; formatPopup.action = #selector(formatChanged(_:))

        saveButton = NSButton(title: Settings.shared.saveDirectory.lastPathComponent,
                              target: self, action: #selector(chooseFolder))
        saveButton.bezelStyle = .rounded
        saveButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        saveButton.imagePosition = .imageLeading


        let recordingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        recordingPopup.addItems(withTitles: ["MP4", "MOV", "GIF"])
        recordingPopup.selectItem(at: recordingOrder.firstIndex(of: Settings.shared.recordingFormat) ?? 0)
        recordingPopup.target = self; recordingPopup.action = #selector(recordingFormatChanged(_:))

        let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appearancePopup.addItems(withTitles: ["Follow System", "Light", "Dark"])
        appearancePopup.selectItem(at: appearanceOrder.firstIndex(of: Settings.shared.appearance) ?? 0)
        appearancePopup.target = self; appearancePopup.action = #selector(appearanceChanged(_:))

        let shelfPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shelfPopup.addItems(withTitles: ["Shelf", "Off"])
        shelfPopup.selectItem(at: shelfOrder.firstIndex(of: Settings.shared.shelfMode) ?? 0)
        shelfPopup.target = self; shelfPopup.action = #selector(shelfModeChanged(_:))

        // The old status-menu items, folded into Settings.
        func historyButton(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            return b
        }
        let historyRow = NSStackView(views: [
            historyButton("Show History…", #selector(showHistory(_:))),
            historyButton("Show Shelf", #selector(showShelfTapped(_:))),
        ])
        historyRow.spacing = 8

        let editorCheck = NSButton(checkboxWithTitle: "Copy to clipboard & show quick‑edit thumbnail (off: save to file)",
                                   target: self, action: #selector(toggleEditor(_:)))
        editorCheck.state = Settings.shared.openEditorAfterCapture ? .on : .off

        let loginCheck = NSButton(checkboxWithTitle: "Open Inkshot at login",
                                  target: self, action: #selector(toggleLogin(_:)))
        loginCheck.state = loginEnabled ? .on : .off
        if #available(macOS 13.0, *) {} else { loginCheck.isEnabled = false }

        func label(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let grid = NSGridView(views: [
            [label("Region hotkey:"), recorder(.region)],
            [label("Window hotkey:"), recorder(.window)],
            [label("Full screen hotkey:"), recorder(.full)],
            [label("Record hotkey:"), recorder(.record)],
            [label("Capture format:"), formatPopup],
            [label("Recording format:"), recordingPopup],
            [label("Save to:"), saveButton],
            [label("Appearance:"), appearancePopup],
            [label("Recent captures:"), shelfPopup],
            [label("History:"), historyRow],
            [NSGridCell.emptyContentView, soundCheck],
            [NSGridCell.emptyContentView, editorCheck],
            [NSGridCell.emptyContentView, loginCheck],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 14
        grid.columnSpacing = 12

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: max(460, content.fittingSize.width), height: content.fittingSize.height))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func recordingFormatChanged(_ s: NSPopUpButton) {
        Settings.shared.recordingFormat = recordingOrder[max(0, s.indexOfSelectedItem)]
    }
    @objc private func appearanceChanged(_ s: NSPopUpButton) {
        Settings.shared.appearance = appearanceOrder[max(0, s.indexOfSelectedItem)]
        (NSApp.delegate as? AppDelegate)?.historyWC?.refresh()   // its frame colors are set at load
    }
    @objc private func toggleSound(_ s: NSButton) { Settings.shared.playSound = (s.state == .on) }
    @objc private func showHistory(_ s: NSButton) { (NSApp.delegate as? AppDelegate)?.openHistory() }
    @objc private func showShelfTapped(_ s: NSButton) { ShelfController.shared.show() }
    @objc private func toggleEditor(_ s: NSButton) { Settings.shared.openEditorAfterCapture = (s.state == .on) }
    @objc private func formatChanged(_ s: NSPopUpButton) {
        Settings.shared.captureFormat = formatOrder[max(0, s.indexOfSelectedItem)]
    }
    @objc private func shelfModeChanged(_ s: NSPopUpButton) {
        Settings.shared.shelfMode = shelfOrder[max(0, s.indexOfSelectedItem)]
        if Settings.shared.autoShowShelf { ShelfController.shared.show() } else { ShelfController.shared.hide() }
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Settings.shared.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.saveDirectory = url
            saveButton.title = url.lastPathComponent
        }
    }
    @objc private func toggleLogin(_ s: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if s.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            s.state = loginEnabled ? .on : .off   // revert on failure
        }
    }
    private var loginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
}

// MARK: - About window

final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About Inkshot"
        window.isReleasedWhenClosed = false
        Ink.dress(window)
        super.init(window: window)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let name = NSTextField(labelWithString: "Inkshot")
        name.font = inkFont(24, bold: true)

        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let version = NSTextField(labelWithString: "Version \(ver)")
        version.font = inkFont(13)
        version.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "Private screenshots, annotation & screen recording.")
        tagline.font = inkFont(12)
        tagline.textColor = .secondaryLabelColor

        let privacy = NSTextField(labelWithString: "No networking. No telemetry. Everything stays on this Mac.")
        privacy.font = inkFont(12)
        privacy.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, name, version, tagline, privacy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -8),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Welcome window

/// Shown on first launch. A menu-bar-only app otherwise opens to nothing visible,
/// and capture can't work at all until Screen Recording permission is granted.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(labelWithString: "")
    private var grantButton: NSButton!

    init(menuBarIcon: NSImage?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Inkshot"
        window.isReleasedWhenClosed = false
        Ink.dress(window)
        super.init(window: window)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let name = NSTextField(labelWithString: "Welcome to Inkshot")
        name.font = inkFont(24, bold: true)

        func paragraph(_ s: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.preferredMaxLayoutWidth = 380
            t.alignment = .center
            return t
        }
        let barIcon = NSImageView(image: menuBarIcon ?? NSImage())
        barIcon.contentTintColor = .labelColor
        let whereRow = NSStackView(views: [barIcon, paragraph("Inkshot lives in the menu bar. Click this icon to capture, record, or open Settings.")])
        whereRow.spacing = 8

        let hotkeys = Settings.Action.allCases.map { "\($0.label) \(Settings.shared.display($0))" }
        let keys = paragraph("Hotkeys: " + hotkeys.joined(separator: " · ") + "  (change them in Settings)")
        keys.textColor = .secondaryLabelColor

        let whyTitle = NSTextField(labelWithString: "Why Inkshot needs Screen Recording")
        whyTitle.font = inkFont(14, bold: true)
        let why = paragraph("macOS requires this permission for every screenshot app. The next dialog uses Apple's standard wording, which sounds alarming for any app.")
        // Only the sandboxed build can claim macOS enforces it; elsewhere it's the code.
        let offline = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            ? "Nothing leaves this Mac: Inkshot has no network access, and macOS enforces that."
            : "Nothing leaves this Mac: Inkshot contains no networking code."
        let promises = NSTextField(wrappingLabelWithString: [
            "Inkshot looks at the screen only when you take a shot or record.",
            "It never records audio.",
            offline,
            "You can turn it off anytime in System Settings → Privacy & Security.",
        ].map { "•\t" + $0 }.joined(separator: "\n"))
        let hanging = NSMutableParagraphStyle()
        hanging.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        hanging.headIndent = 14
        hanging.paragraphSpacing = 3
        promises.attributedStringValue = NSAttributedString(string: promises.stringValue, attributes: [
            .font: promises.font ?? NSFont.systemFont(ofSize: 13), .paragraphStyle: hanging,
            .foregroundColor: NSColor.labelColor])
        promises.preferredMaxLayoutWidth = 356
        promises.translatesAutoresizingMaskIntoConstraints = false
        let promiseBox = InkSurface(color: Ink.wash, radius: 8)
        promiseBox.addSubview(promises)
        NSLayoutConstraint.activate([
            promises.topAnchor.constraint(equalTo: promiseBox.topAnchor, constant: 10),
            promises.bottomAnchor.constraint(equalTo: promiseBox.bottomAnchor, constant: -10),
            promises.leadingAnchor.constraint(equalTo: promiseBox.leadingAnchor, constant: 12),
            promises.trailingAnchor.constraint(equalTo: promiseBox.trailingAnchor, constant: -12),
        ])

        grantButton = InkButton(title: "Continue to Permission…", style: .outline, target: nil, action: #selector(grant))
        grantButton.target = self

        let done = InkButton(title: "Get Started", style: .stamp, target: nil, action: #selector(finish))
        done.keyEquivalent = "\r"
        done.target = self

        let stack = NSStackView(views: [icon, name, whereRow, keys, whyTitle, why, promiseBox, grantButton, status, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: keys)
        stack.setCustomSpacing(6, after: whyTitle)
        stack.setCustomSpacing(16, after: promiseBox)
        stack.setCustomSpacing(20, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.delegate = self
        window.center()
        refreshStatus()
    }
    required init?(coder: NSCoder) { fatalError() }

    // The user grants access in System Settings, then comes back here.
    func windowDidBecomeKey(_ notification: Notification) { refreshStatus() }

    private func refreshStatus() {
        let ok = CGPreflightScreenCaptureAccess()
        status.stringValue = ok ? "✓ Screen Recording is allowed."
                                : "Not allowed yet. After you allow it, quit and reopen Inkshot."
        status.textColor = ok ? .systemGreen : .secondaryLabelColor
        grantButton.isHidden = ok
    }

    @objc private func grant() {
        _ = (NSApp.delegate as? AppDelegate)?.ensureScreenCapturePermission()
        refreshStatus()
    }
    @objc private func finish() { close() }
}

// MARK: - Post-capture thumbnail

/// Our transient chrome (shelf, thumbnail, selection overlays, HUDs), registered as each
/// is created. Only these stay out of shots: everything else of ours (editor, Settings,
/// the status menu, the menu-bar icon) is captured like any other app's.
let chromeWindows = NSHashTable<NSWindow>.weakObjects()
func chromeWindowIDs() -> Set<CGWindowID> {
    Set(chromeWindows.allObjects.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
}

/// Whole-display filter that leaves out just our transient chrome.
func ownChromeFilter(_ display: SCDisplay, in content: SCShareableContent, excluding ids: Set<CGWindowID>) -> SCContentFilter {
    SCContentFilter(display: display, excludingWindows: content.windows.filter { ids.contains($0.windowID) })
}

/// The menu-bar screen. The shelf and thumbnail live here rather than on
/// `NSScreen.main`, which follows the key window from display to display.
var shelfScreen: NSScreen? { NSScreen.screens.first }

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Downscaled decode for shelf/history previews; full Retina captures are tens of MB of pixels.
func thumbnailImage(_ url: URL, maxPixel: Int = 480) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Temp copies made for drag-out; emptied at launch, once no drag can still need them.
let dragTempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("InkshotDrags", isDirectory: true)

/// Space-to-edit needs the keyboard, which means activating Inkshot over the app
/// the user was in. Remember that app and hand focus back when the quick-edit
/// window ends unused, so a following ⌘V lands where the user expects.
final class FocusReturn {
    static let shared = FocusReturn()
    private var previous: NSRunningApplication?

    func take() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        NSApp.activate(ignoringOtherApps: true)
    }
    func giveBack(from panel: NSWindow?) {
        defer { previous = nil }
        // Leave focus alone if the user already moved on (another app, or one of our windows).
        guard NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === panel else { return }
        previous?.activate()
    }
    func forget() { previous = nil }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Let the auto-hidden shelf sit (almost) fully off-screen; the default
    // constraint pulls such frames back on-screen and would cancel the slide.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// An image view you can drag out into other apps (as a file + image data),
/// or click to trigger `onClick`.
final class DraggableImageView: NSImageView, NSDraggingSource, NSPasteboardItemDataProvider {
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverIn: (() -> Void)?
    var onHoverOut: (() -> Void)?
    var sourceURL: URL?          // if set, drags this real file instead of a temp copy
    var rightMenu: NSMenu?
    var sketchBorder = false
    var sketchHighlighted = false { didSet { if sketchBorder { needsDisplay = true } } }
    static let sketchInset: CGFloat = 7
    private var downPoint = NSPoint.zero
    private var dragging = false

    override func menu(for event: NSEvent) -> NSMenu? { rightMenu }

    override func draw(_ dirtyRect: NSRect) {
        guard sketchBorder else { super.draw(dirtyRect); return }
        // Inset the image so the wobbly frame surrounds it rather than running over its edges.
        image?.draw(in: bounds.insetBy(dx: Self.sketchInset, dy: Self.sketchInset))
        let p = NSBezierPath()
        p.lineWidth = 1.7; p.lineCapStyle = .round; p.lineJoinStyle = .round
        let seed = UInt64(bitPattern: Int64(sourceURL?.lastPathComponent.hashValue ?? 7)) | 1
        appendRoughRect(p, bounds.insetBy(dx: 3, dy: 3), amp: 1.8, seed: seed)
        (sketchHighlighted ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.5)).setStroke()
        p.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverIn?() }
    override func mouseExited(with event: NSEvent) { onHoverOut?() }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; dragging = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        if hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) > 4 {
            dragging = true
            onDragBegan?()
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: [.fileURL, .png, .tiff])
            let di = NSDraggingItem(pasteboardWriter: item)
            di.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [di], event: event, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) { if !dragging { onClick?() } }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ s: NSDraggingSession, endedAt: NSPoint, operation: NSDragOperation) { onDragEnded?() }

    // A real PNG file to drag out: the source file if we have one, else a temp copy.
    private var cachedURL: URL?
    private func dragURL() -> URL? {
        if let s = sourceURL { return s }
        if let c = cachedURL { return c }
        guard let tiff = image?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        try? FileManager.default.createDirectory(at: dragTempFolder, withIntermediateDirectories: true)
        let url = dragTempFolder.appendingPathComponent("Inkshot \(fmt.string(from: Date())).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        cachedURL = url
        return url
    }

    func pasteboard(_ pb: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .fileURL: if let u = dragURL() { item.setString(u.absoluteString, forType: .fileURL) }
        case .png: if let u = dragURL(), let d = try? Data(contentsOf: u) { item.setData(d, forType: .png) }
        case .tiff:
            // `image` may be a downscaled preview; drag the full-resolution file when there is one.
            let full = sourceURL.flatMap { NSImage(contentsOf: $0) } ?? image
            if let d = full?.tiffRepresentation { item.setData(d, forType: .tiff) }
        default: break
        }
    }
}

/// A floating corner preview shown after a capture. The image is already on the
/// clipboard; Space or a click opens the editor, Esc or a timeout dismisses it.
final class ThumbnailController: NSObject {
    static var current: ThumbnailController?

    private let panel: KeyPanel
    private let onEdit: () -> Void
    private var monitor: Any?
    private var timer: Timer?

    init(image: NSImage, onEdit: @escaping () -> Void) {
        self.onEdit = onEdit
        let pw = max(image.size.width, 1), ph = max(image.size.height, 1)
        var w: CGFloat = 260, h = 260 * ph / pw
        if h > 190 { h = 190; w = h * pw / ph }
        let barH: CGFloat = 22
        let rect = NSRect(x: 0, y: 0, width: w, height: h + barH)
        panel = KeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .statusBar
        chromeWindows.add(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        super.init()

        let container = InkSurface(color: Ink.paper, radius: 10)
        container.frame = rect
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.borderColor = Ink.inkGhost.cgColor
        }

        let iv = DraggableImageView(frame: NSRect(x: 0, y: barH, width: w, height: h))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.onClick = { [weak self] in self?.editAction() }
        iv.onDragBegan = { [weak self] in self?.timer?.invalidate() }
        iv.onDragEnded = { [weak self] in self?.dismiss(restoreFocus: true) }
        iv.onHoverIn = { [weak self] in self?.timer?.invalidate() }      // don't vanish mid-interaction
        iv.onHoverOut = { [weak self] in self?.restartTimer() }
        container.addSubview(iv)

        let hint = NSTextField(labelWithString: "Drag out · Space to edit · Esc")
        hint.frame = NSRect(x: 0, y: 3, width: w, height: barH - 4)
        hint.alignment = .center
        hint.font = inkFont(12)
        hint.textColor = Ink.inkSoft
        container.addSubview(hint)

        panel.contentView = container
    }

    static func show(image: NSImage, onEdit: @escaping () -> Void) {
        current?.dismiss()
        let c = ThumbnailController(image: image, onEdit: onEdit)
        current = c
        c.present()
    }

    private func present() {
        if let vf = shelfScreen?.visibleFrame {
            let s = panel.frame.size
            var x = vf.maxX - s.width - 20
            let y = vf.minY + 20
            // Sit to the left of the recent shelf so it isn't covered.
            if ShelfController.shared.isVisible, let sf = ShelfController.shared.panelFrame {
                x = min(x, sf.minX - s.width - 16)
                if x < vf.minX + 16 { x = vf.minX + 16 }
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        FocusReturn.shared.take()   // so Space/Esc reach the panel and are consumed
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.window === self.panel else { return e }
            switch e.keyCode {
            case 49, 36: self.editAction()               // space, return
            default: self.dismiss(restoreFocus: true)    // escape, or the user typing elsewhere
            }
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.dismiss(restoreFocus: true) }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.dismiss(restoreFocus: true) }
    }

    @objc private func editAction() {
        let cb = onEdit
        FocusReturn.shared.forget()
        dismiss()
        cb()
    }

    func dismiss(restoreFocus: Bool = false) {
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if restoreFocus { FocusReturn.shared.giveBack(from: panel) }
        panel.orderOut(nil)
        if ThumbnailController.current === self { ThumbnailController.current = nil }
    }
}

// MARK: - Capture history

/// Saves captures (originals and edited exports) to Application Support and lists them.
final class HistoryStore {
    static let shared = HistoryStore()
    let folder: URL
    private let maxItems = 60

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        folder = base.appendingPathComponent("Inkshot/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ image: NSImage, edited: Bool) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let url = folder.appendingPathComponent("Shot \(fmt.string(from: Date()))\(edited ? "-edited" : "").png")
        guard (try? png.write(to: url)) != nil else { return nil }
        prune()
        return url
    }

    func recent() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { (modDate($0) ?? .distantPast) > (modDate($1) ?? .distantPast) }
    }
    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    func clearAll() { for u in recent() { try? FileManager.default.removeItem(at: u) } }

    private func modDate(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    private func prune() {
        let all = recent()
        if all.count > maxItems { for u in all[maxItems...] { try? FileManager.default.removeItem(at: u) } }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - History window

final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let grid = FlippedView()
    private let scroll = NSScrollView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Inkshot History"
        window.isReleasedWhenClosed = false
        Ink.dress(window)
        super.init(window: window)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.drawsBackground = true
        scroll.backgroundColor = Ink.paper
        window.contentView = scroll
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func showAndReload() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private let pad: CGFloat = 16, cell: CGFloat = 196
    private var shownCols = 0
    private var columns: Int {
        let width = max(scroll.contentView.bounds.width, cell + pad * 2)
        return max(1, Int((width - pad) / (cell + pad)))
    }

    // Live resize fires this per frame; only rebuild when the grid actually reflows.
    func windowDidResize(_ notification: Notification) { if columns != shownCols { reload() } else { sizeGrid() } }
    func refresh() { if window?.isVisible == true { reload() } }

    private func reload() {
        grid.subviews.forEach { $0.removeFromSuperview() }
        let urls = HistoryStore.shared.recent()
        let thumbH: CGFloat = 132
        let cols = columns
        shownCols = cols
        for (i, url) in urls.enumerated() {
            let row = i / cols, col = i % cols
            let x = pad + CGFloat(col) * (cell + pad)
            let y = pad + CGFloat(row) * (thumbH + pad)
            let iv = DraggableImageView(frame: NSRect(x: x, y: y, width: cell, height: thumbH))
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 8
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 1.5
            grid.effectiveAppearance.performAsCurrentDrawingAppearance { iv.layer?.borderColor = Ink.inkGhost.cgColor }
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.image = thumbnailImage(url)
            iv.sourceURL = url
            iv.toolTip = url.lastPathComponent
            iv.onClick = { [weak self] in self?.open(url) }
            iv.rightMenu = contextMenu(for: url)
            grid.addSubview(iv)
        }
        let rows = (urls.count + cols - 1) / cols
        gridContentH = pad + CGFloat(max(rows, 1)) * (thumbH + pad)
        sizeGrid()
    }
    private var gridContentH: CGFloat = 0
    private func sizeGrid() {
        let vis = scroll.contentView.bounds.size
        grid.frame = NSRect(x: 0, y: 0, width: max(vis.width, cell + pad * 2), height: max(vis.height, gridContentH))
    }

    private func contextMenu(for url: URL) -> NSMenu {
        let m = NSMenu()
        let open = m.addItem(withTitle: "Open in Editor", action: #selector(openItem(_:)), keyEquivalent: "")
        open.representedObject = url; open.target = self
        let reveal = m.addItem(withTitle: "Reveal in Finder", action: #selector(revealItem(_:)), keyEquivalent: "")
        reveal.representedObject = url; reveal.target = self
        m.addItem(.separator())
        let del = m.addItem(withTitle: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: "")
        del.representedObject = url; del.target = self
        return m
    }

    @objc private func openItem(_ s: NSMenuItem) { if let u = s.representedObject as? URL { open(u) } }
    @objc private func revealItem(_ s: NSMenuItem) { if let u = s.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc private func deleteItem(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL {
            HistoryStore.shared.delete(u); reload()
            ShelfController.shared.refreshIfVisible()
        }
    }
    private func open(_ url: URL) { (NSApp.delegate as? AppDelegate)?.openEditor(url: url) }
}

// MARK: - Corner shelf

/// A persistent floating strip in the bottom-right corner showing recent captures,
/// like the Downloads stack. Items drag out or click to open in the editor.
final class ShelfController: NSObject {
    static let shared = ShelfController()
    private var panel: NSPanel?
    private let maxItems = 8
    private let itemW: CGFloat = 184, itemH: CGFloat = 108
    private let pad: CGFloat = 12

    var isVisible: Bool { panel?.isVisible ?? false }
    var panelFrame: NSRect? { panel?.frame }
    private var pendingFlash = false
    private var quickEditURL: URL?
    private var quickMonitor: Any?
    private var quickTimer: Timer?
    private weak var hintLabel: NSView?
    private var autoHidden = false
    private var pollTimer: Timer?
    private var lastInside = Date()
    private let peek: CGFloat = 8

    func show(flashNewest: Bool = false) {
        pendingFlash = flashNewest
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: itemW + pad * 2, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear
            p.hasShadow = false; p.hidesOnDeactivate = false   // items carry their own shadow
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            chromeWindows.add(p)
            panel = p
        }
        applyLevel()
        reload()
        panel?.orderFront(nil)
    }

    private func applyLevel() {
        panel?.level = Settings.shared.shelfPinned ? .floating : .normal
    }
    // When auto-hiding, the revealed shelf is flush to the edge so the cursor that
    // triggered it stays over the shelf; otherwise it keeps a small margin.
    private func revealedX(_ vf: NSRect, _ w: CGFloat) -> CGFloat {
        vf.maxX - w   // flush right: thumbnails sit right against the screen edge
    }
    func hide() {
        endQuickEdit()
        pollTimer?.invalidate(); pollTimer = nil
        autoHidden = false
        panel?.orderOut(nil); panel = nil
    }
    func refreshIfVisible() { if isVisible { reload() } }

    private func reload() {
        guard let p = panel else { return }
        let urls = Array(HistoryStore.shared.recent().prefix(maxItems))

        // A straight column hugging the screen's right edge: newest at the top (largest),
        // shrinking going down, with the time labels to the left of the cards.
        let baseW: CGFloat = 148, baseH: CGFloat = 90
        let sMin: CGFloat = 0.72, sMax: CGFloat = 1.18
        let W: CGFloat = 340, rightMargin: CGFloat = 8
        let gap: CGFloat = 14, topPad: CGFloat = 10, botPad: CGFloat = 14, ctlH: CGFloat = 26
        let n = urls.count

        var scales: [CGFloat] = [], heights: [CGFloat] = []
        for i in 0..<n {
            let t = n > 1 ? CGFloat(i)/CGFloat(n-1) : 0
            let sc = sMax - (sMax - sMin) * t
            scales.append(sc); heights.append(baseH * sc)
        }
        let listH = n == 0 ? 60 : heights.reduce(0, +) + CGFloat(n-1) * gap
        let H = ctlH + topPad + listH + botPad
        let frame = NSRect(x: 0, y: 0, width: W, height: H)

        // Transparent container — items float directly over the desktop.
        let bg = NSView(frame: frame)

        // Compact floating controls above the column.
        let d: CGFloat = 24, cgap: CGFloat = 6, cy = H - ctlH + (ctlH - d) / 2
        var cx = W - rightMargin - d
        bg.addSubview(circleButton("xmark", "Close", #selector(closeShelf), tint: .white,
                                   frame: NSRect(x: cx, y: cy, width: d, height: d))); cx -= (d + cgap)
        bg.addSubview(circleButton("trash", "Clear all", #selector(confirmClear), tint: .white,
                                   frame: NSRect(x: cx, y: cy, width: d, height: d))); cx -= (d + cgap)
        let pinned = Settings.shared.shelfPinned
        bg.addSubview(circleButton(pinned ? "pin.fill" : "pin", pinned ? "Unpin" : "Keep on top",
                                   #selector(togglePin), tint: pinned ? .controlAccentColor : .white,
                                   frame: NSRect(x: cx, y: cy, width: d, height: d))); cx -= (d + cgap)
        let hiding = Settings.shared.shelfAutoHide
        bg.addSubview(circleButton("arrow.right.to.line", hiding ? "Auto-hide on" : "Auto-hide at edge",
                                   #selector(toggleAutoHide), tint: hiding ? .controlAccentColor : .white,
                                   frame: NSRect(x: cx, y: cy, width: d, height: d)))

        if urls.isEmpty {
            let pill = labelPill("No captures yet")
            pill.setFrameOrigin(NSPoint(x: W - rightMargin - pill.frame.width, y: H - ctlH - topPad - 36))
            bg.addSubview(pill)
        } else {
            var y = H - ctlH - topPad                   // top edge of the newest thumbnail's slot
            for (idx, url) in urls.enumerated() {
                let wi = baseW * scales[idx], hi = heights[idx]
                // The card hugs the capture's aspect inside its slot, so the frame never encloses empty space.
                let img = thumbnailImage(url)
                let m = DraggableImageView.sketchInset * 2
                let aspect = img.map { $0.size.width / max($0.size.height, 1) } ?? wi / hi
                let iw = max(16, min(wi - m, (hi - m) * aspect)), ih = max(12, min(hi - m, iw / aspect))
                let cw = iw + m, ch = ih + m
                let x = W - rightMargin - cw, ty = y - hi + (hi - ch) / 2
                let card = DraggableImageView(frame: NSRect(x: x, y: ty, width: cw, height: ch))
                card.wantsLayer = true
                card.layer?.masksToBounds = false
                card.layer?.shadowColor = NSColor.black.cgColor
                card.layer?.shadowOpacity = 0.35
                card.layer?.shadowRadius = 5
                card.layer?.shadowOffset = CGSize(width: 0, height: -2)
                card.imageScaling = .scaleProportionallyUpOrDown
                card.image = img
                card.sourceURL = url
                card.toolTip = url.lastPathComponent
                card.sketchBorder = true                // wobbly hand-drawn frame
                card.onClick = { (NSApp.delegate as? AppDelegate)?.openEditor(url: url) }
                card.onHoverIn = { [weak card] in card?.sketchHighlighted = true }
                card.onHoverOut = { [weak card] in card?.sketchHighlighted = false }
                card.rightMenu = itemMenu(for: url)
                bg.addSubview(card)

                // Floating label pill to the left of the thumbnail.
                let isNew = idx == 0 && pendingFlash
                let pill = labelPill(isNew ? "Space to edit ✎" : shortLabel(for: url), highlight: isNew)
                pill.setFrameOrigin(NSPoint(x: x - 12 - pill.frame.width,
                                            y: ty + (ch - pill.frame.height) / 2))
                bg.addSubview(pill)
                if isNew { hintLabel = pill; card.sketchHighlighted = true; popIn(card) }

                y -= hi + gap
            }
        }

        let flashURL = pendingFlash ? urls.first : nil
        pendingFlash = false
        p.setContentSize(frame.size)
        p.contentView = bg
        if let vf = shelfScreen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: revealedX(vf, frame.width), y: vf.minY + 16))
        }
        updateAutoHide()
        if let u = flashURL { startQuickEdit(u) }
    }

    private func shortLabel(for url: URL) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return f.string(from: date) + (url.lastPathComponent.contains("-edited") ? " ✎" : "")
    }

    private func labelPill(_ text: String, highlight: Bool = false) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = inkFont(14, bold: highlight)
        field.textColor = .white
        field.sizeToFit()
        let pw = field.frame.width + 22, ph: CGFloat = 28
        let v = NSView(frame: NSRect(x: 0, y: 0, width: pw, height: ph))
        v.wantsLayer = true
        v.layer?.backgroundColor = (highlight ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.62)).cgColor
        v.layer?.cornerRadius = 7
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.3; v.layer?.shadowRadius = 3; v.layer?.shadowOffset = CGSize(width: 0, height: -1)
        field.frame = NSRect(x: 11, y: (ph - field.frame.height) / 2, width: field.frame.width, height: field.frame.height)
        v.addSubview(field)
        return v
    }

    private func circleButton(_ symbol: String, _ tip: String, _ action: Selector, tint: NSColor, frame: NSRect) -> NSView {
        let holder = NSView(frame: frame)
        holder.wantsLayer = true
        holder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        holder.layer?.cornerRadius = frame.width / 2
        let b = NSButton(frame: holder.bounds)
        b.isBordered = false; b.bezelStyle = .regularSquare; b.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        b.contentTintColor = tint
        b.toolTip = tip; b.target = self; b.action = action
        holder.addSubview(b)
        return holder
    }

    // MARK: auto-hide at the screen edge

    private func updateAutoHide() {
        guard let p = panel, let vf = shelfScreen?.visibleFrame else { return }
        if Settings.shared.shelfAutoHide {
            autoHidden = false
            lastInside = Date()
            p.setFrameOrigin(NSPoint(x: revealedX(vf, p.frame.width), y: vf.minY + 16))
            if pollTimer == nil {
                pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.autoHideTick() }
            }
        } else {
            pollTimer?.invalidate(); pollTimer = nil
            autoHidden = false
            p.setFrameOrigin(NSPoint(x: revealedX(vf, p.frame.width), y: vf.minY + 16))
        }
    }

    private func autoHideTick() {
        guard let p = panel, let scr = shelfScreen else { return }
        let vf = scr.visibleFrame
        let loc = NSEvent.mouseLocation
        let w = p.frame.width, h = p.frame.height, y = vf.minY + 16
        // Only count the cursor when it is on the shelf's own display: global mouse x
        // on a display to the right of this one also passes the maxX check below and
        // would otherwise flip the shelf between revealed and concealed forever.
        let onShelfScreen = scr.frame.contains(loc)
        if autoHidden {
            if onShelfScreen && loc.x >= vf.maxX - 3 && loc.y >= y - 10 && loc.y <= y + h + 10 { reveal() }
        } else {
            let revealed = NSRect(x: revealedX(vf, w), y: y, width: w, height: h).insetBy(dx: -8, dy: -8)
            // During the quick-edit window the shelf (and its Space-to-edit badge) stays put.
            if revealed.contains(loc) || quickEditURL != nil { lastInside = Date() }
            else if Date().timeIntervalSince(lastInside) > 1.0 { conceal() }
        }
    }
    private func reveal() {
        guard let p = panel, let vf = shelfScreen?.visibleFrame else { return }
        autoHidden = false; lastInside = Date()
        var f = p.frame; f.origin.x = revealedX(vf, f.width); f.origin.y = vf.minY + 16
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18
            p.animator().setFrame(f, display: true) }   // animator().setFrameOrigin is a silent no-op
    }
    private func conceal() {
        guard let p = panel, let vf = shelfScreen?.visibleFrame else { return }
        autoHidden = true
        var f = p.frame; f.origin.x = vf.maxX - peek; f.origin.y = vf.minY + 16
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2
            p.animator().setFrame(f, display: true) }
    }

    // A short window right after capture where Space/Return edits the newest shot.
    private func startQuickEdit(_ url: URL) {
        quickEditURL = url
        FocusReturn.shared.take()
        // On the first capture the panel isn't on screen yet, and makeKey alone is ignored then.
        panel?.makeKeyAndOrderFront(nil)
        if let m = quickMonitor { NSEvent.removeMonitor(m) }
        quickMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, let u = self.quickEditURL, e.window === self.panel else { return e }
            switch e.keyCode {
            case 49, 36:   // space, return
                FocusReturn.shared.forget()
                self.endQuickEdit()
                (NSApp.delegate as? AppDelegate)?.openEditor(url: u)
            default:       // escape, or the user typing elsewhere
                self.endQuickEdit(restoreFocus: true)
            }
            return nil
        }
        quickTimer?.invalidate()
        quickTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.endQuickEdit(restoreFocus: true)
        }
    }
    private func endQuickEdit(restoreFocus: Bool = false) {
        guard quickEditURL != nil else { return }
        quickEditURL = nil
        if let m = quickMonitor { NSEvent.removeMonitor(m); quickMonitor = nil }
        quickTimer?.invalidate(); quickTimer = nil
        hintLabel?.removeFromSuperview(); hintLabel = nil
        if restoreFocus { FocusReturn.shared.giveBack(from: panel) }
    }

    private func itemMenu(for url: URL) -> NSMenu {
        let m = NSMenu()
        for (titleStr, sel) in [("Open in Editor", #selector(openItem(_:))),
                                ("Reveal in Finder", #selector(revealItem(_:))),
                                ("Delete", #selector(deleteItem(_:)))] {
            if titleStr == "Delete" { m.addItem(.separator()) }
            let it = m.addItem(withTitle: titleStr, action: sel, keyEquivalent: "")
            it.representedObject = url; it.target = self
        }
        return m
    }

    @objc private func openItem(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { (NSApp.delegate as? AppDelegate)?.openEditor(url: u) }
    }
    @objc private func revealItem(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
    @objc private func deleteItem(_ s: NSMenuItem) {
        if let u = s.representedObject as? URL {
            HistoryStore.shared.delete(u); reload()
            (NSApp.delegate as? AppDelegate)?.historyWC?.refresh()
        }
    }
    /// Grow a freshly added card up from nothing, like a Downloads-stack drop.
    private func popIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let f = view.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: f.midX, y: f.midY)
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.08; scale.toValue = 1.0
        scale.damping = 13; scale.stiffness = 170; scale.mass = 0.9
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0; fade.toValue = 1.0; fade.duration = 0.25
        layer.add(scale, forKey: "popin")
        layer.add(fade, forKey: "fade")
    }

    @objc private func closeShelf() { hide() }
    @objc private func togglePin() {
        Settings.shared.shelfPinned.toggle()
        applyLevel()
        reload()
    }
    @objc private func toggleAutoHide() {
        Settings.shared.shelfAutoHide.toggle()
        reload()
    }
    @objc private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Clear all recent captures?"
        a.informativeText = "This permanently deletes the saved screenshots in your history."
        a.alertStyle = .warning
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            HistoryStore.shared.clearAll()
            reload()
            (NSApp.delegate as? AppDelegate)?.historyWC?.refresh()
        }
    }
}

// MARK: - Selection overlays (window picker, region select)

/// Receives a full-screen overlay's events. Points are global AppKit screen coordinates.
fileprivate protocol OverlayHandler: AnyObject {
    func overlayDraw(_ view: OverlayView)
    func overlayDown(at p: NSPoint, clickCount: Int)
    func overlayMoved(to p: NSPoint)
    func overlayDragged(to p: NSPoint)
    func overlayUp(at p: NSPoint)
    func overlayKey(_ event: NSEvent)
    func overlayCancel()
}
extension OverlayHandler {
    func overlayMoved(to p: NSPoint) {}
    func overlayDragged(to p: NSPoint) {}
    func overlayUp(at p: NSPoint) {}
    func overlayKey(_ event: NSEvent) { if event.keyCode == 53 { overlayCancel() } }   // Esc
}

/// One translucent overlay window per screen, all driven by one handler.
fileprivate final class OverlaySet {
    private var windows: [OverlayWindow] = []

    func show(_ handler: OverlayHandler) {
        hide()
        FocusReturn.shared.take()   // so Esc reaches us; handed back on cancel
        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen, handler: handler)
            windows.append(w)
            w.orderFrontRegardless()
        }
        // Make the overlay under the cursor key so Esc works.
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
    }
    func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }
    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

fileprivate final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    private weak var handler: OverlayHandler?

    init(screen: NSScreen, handler: OverlayHandler) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.handler = handler
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        chromeWindows.add(self)
        contentView = OverlayView(handler: handler)
    }

    override func keyDown(with event: NSEvent) { handler?.overlayKey(event) }
}

fileprivate final class OverlayView: NSView {
    private weak var handler: OverlayHandler?

    init(handler: OverlayHandler) {
        self.handler = handler
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Global screen rect → this view's coordinates.
    func local(_ global: NSRect) -> NSRect {
        guard let window else { return global }
        return convert(window.convertFromScreen(global), from: nil)
    }

    override func draw(_ dirtyRect: NSRect) { handler?.overlayDraw(self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { handler?.overlayMoved(to: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) {
        handler?.overlayDown(at: screenPoint(event), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { handler?.overlayDragged(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { handler?.overlayUp(at: screenPoint(event)) }
    // The event's own location: NSEvent.mouseLocation can lag behind it during a fast drag.
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
    override func rightMouseDown(with event: NSEvent) { handler?.overlayCancel() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) {}   // handlers may set their own cursor
}

/// Highlights the window under the cursor (rects from `SCShareableContent`).
/// Click picks, Esc / right-click / an empty-area click cancels.
final class WindowPickerController: NSObject, OverlayHandler {
    static let shared = WindowPickerController()
    private let overlays = OverlaySet()
    private var candidates: [(window: SCWindow, rect: NSRect)] = []
    private var onPick: ((SCWindow) -> Void)?
    private var hovered: NSRect?

    func begin(content: SCShareableContent, onPick: @escaping (SCWindow) -> Void) {
        finish()   // in case one is already up
        let chrome = chromeWindowIDs()
        candidates = content.windows.compactMap { w in
            // Real app windows only: skip our own chrome (our editor etc. are fair game), tiny
            // frames, and anything off the normal layer (menu bar, status items, Dock, Control Center).
            guard !chrome.contains(w.windowID), w.windowLayer == 0,
                  w.frame.width > 40, w.frame.height > 40,
                  let (display, screen) = Self.display(for: w, in: content) else { return nil }
            // SCK space is top-left origin per display; AppKit is bottom-left global.
            let y = screen.frame.maxY - (w.frame.maxY - display.frame.minY)
            let rect = NSRect(x: screen.frame.minX + w.frame.minX - display.frame.minX, y: y,
                              width: w.frame.width, height: w.frame.height)
            return (w, rect)
        }
        // Front-to-back order from the window server (SCShareableContent's order isn't defined).
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                        as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        candidates.sort { (rank[$0.window.windowID] ?? .max) < (rank[$1.window.windowID] ?? .max) }
        guard !candidates.isEmpty else { return }
        self.onPick = onPick
        overlays.show(self)
        overlayMoved(to: NSEvent.mouseLocation)
    }

    /// The SCDisplay/NSScreen pair whose display contains the window's center.
    private static func display(for w: SCWindow, in content: SCShareableContent) -> (SCDisplay, NSScreen)? {
        let mid = CGPoint(x: w.frame.midX, y: w.frame.midY)
        guard let d = content.displays.first(where: { $0.frame.contains(mid) }),
              let s = NSScreen.screens.first(where: { $0.displayID == d.displayID }) else { return nil }
        return (d, s)
    }

    /// The frontmost window under the point (candidates are kept front to back). Picking the
    /// smallest instead chose a small window hidden behind a large one, like the editor.
    private func candidate(at p: NSPoint) -> (window: SCWindow, rect: NSRect)? {
        candidates.first { $0.rect.contains(p) }
    }

    fileprivate func overlayMoved(to p: NSPoint) {
        let rect = candidate(at: p)?.rect
        if rect != hovered { hovered = rect; overlays.redraw() }
    }

    fileprivate func overlayDown(at p: NSPoint, clickCount: Int) {
        guard let c = candidate(at: p) else { overlayCancel(); return }
        let onPick = onPick   // finish() clears the callback
        finish()
        onPick?(c.window)
    }

    fileprivate func overlayCancel() {
        finish()
        FocusReturn.shared.giveBack(from: nil)
    }

    fileprivate func overlayDraw(_ view: OverlayView) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        view.bounds.fill()
        guard let rect = hovered else { return }
        let local = view.local(rect)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        local.fill(using: .sourceOver)
        let path = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func finish() {
        overlays.hide()
        candidates.removeAll()
        hovered = nil
        onPick = nil
    }
}

/// What a region selection produced.
enum RegionPick {
    case area(NSRect, NSScreen)   // global AppKit points
    case frozen(CGImage)          // the area, cut from the screen as it was when selection began
    case screen(NSScreen)         // a click without a drag, when allowed
    case window                   // Space: the caller switches to window picking
}

/// Drag-to-select region capture. The selection stays adjustable (handles, move,
/// arrow keys) until Return or a double-click confirms it. It's clamped to the
/// screen it started on, since one capture comes from one display. A magnifier
/// reads from a still of each display taken when selection begins.
final class RegionSelectController: NSObject, OverlayHandler {
    static let shared = RegionSelectController()
    private let overlays = OverlaySet()
    private enum Drag { case create(NSPoint), move(NSPoint, NSRect), resize(Int, NSRect) }
    private var drag: Drag?
    private var selection: NSRect?
    private var screen: NSScreen?
    private var mouse = NSEvent.mouseLocation
    private var allowScreenClick = false
    private var allowWindow = false
    private var confirmOnRelease = false
    private var onPick: ((RegionPick) -> Void)?
    private var stills: [CGDirectDisplayID: CGImage] = [:]
    private var frozen = false
    private var session = 0

    /// `freeze` grabs the screen before the overlay appears (taking focus closes any open
    /// menu), shows that frozen picture while selecting, and cuts the result from it — so
    /// open menus can be captured. Recording passes false and selects over the live screen.
    func begin(allowScreenClick: Bool = false, allowWindow: Bool = false, confirmOnRelease: Bool = false,
               freeze: Bool = false, willShow: (() -> Void)? = nil, onPick: @escaping (RegionPick) -> Void) {
        finish()
        self.allowScreenClick = allowScreenClick
        self.allowWindow = allowWindow
        self.confirmOnRelease = confirmOnRelease
        self.onPick = onPick
        frozen = freeze
        mouse = NSEvent.mouseLocation
        if freeze {
            loadStills { [weak self] in
                guard let self else { return }
                willShow?()
                self.mouse = NSEvent.mouseLocation
                self.overlays.show(self)
            }
        } else {
            overlays.show(self)
            loadStills()
        }
    }

    /// Captures each display (without our chrome) for the magnifier and the freeze-frame;
    /// `ready` runs once all are in.
    private func loadStills(ready: (() -> Void)? = nil) {
        session += 1
        let token = session
        let chrome = chromeWindowIDs()
        Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            else { await MainActor.run { ready?() }; return }
            for d in content.displays {
                let filter = ownChromeFilter(d, in: content, excluding: chrome)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(CGFloat(d.width) * CGFloat(filter.pointPixelScale))
                cfg.height = Int(CGFloat(d.height) * CGFloat(filter.pointPixelScale))
                cfg.captureResolution = .best
                cfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                      let self else { continue }
                await MainActor.run {
                    guard self.session == token else { return }
                    self.stills[d.displayID] = img
                    self.overlays.redraw()
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.session == token else { return }
                ready?()
            }
        }
    }

    // MARK: events

    fileprivate func overlayMoved(to p: NSPoint) {
        mouse = p
        cursor(at: p).set()
        overlays.redraw()
    }

    fileprivate func overlayDown(at p: NSPoint, clickCount: Int) {
        mouse = p
        if let sel = selection {
            if clickCount == 2, sel.contains(p) { confirm(); return }
            if let h = handle(at: p) { drag = .resize(h, sel); return }
            if sel.contains(p) { drag = .move(p, sel); NSCursor.closedHand.set(); return }
        }
        screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens.first
        selection = nil
        drag = .create(p)
        overlays.redraw()
    }

    fileprivate func overlayDragged(to p: NSPoint) {
        guard let drag, let f = screen?.frame else { return }
        mouse = NSPoint(x: min(max(p.x, f.minX), f.maxX), y: min(max(p.y, f.minY), f.maxY))
        switch drag {
        case .create(let s):
            selection = NSRect(x: min(s.x, mouse.x), y: min(s.y, mouse.y),
                               width: abs(s.x - mouse.x), height: abs(s.y - mouse.y))
        case .move(let s, let r):
            selection = clamp(r.offsetBy(dx: p.x - s.x, dy: p.y - s.y), in: f)
        case .resize(let h, let r):
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            if [0, 6, 7].contains(h) { x0 = mouse.x }
            if [2, 3, 4].contains(h) { x1 = mouse.x }
            if [0, 1, 2].contains(h) { y0 = mouse.y }
            if [4, 5, 6].contains(h) { y1 = mouse.y }
            selection = NSRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        overlays.redraw()
    }

    fileprivate func overlayUp(at p: NSPoint) {
        if drag != nil { overlayDragged(to: p) }   // the release point can be past the last drag event
        let wasCreate: Bool
        if case .create? = drag { wasCreate = true } else { wasCreate = false }
        drag = nil
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            if wasCreate, confirmOnRelease { confirm(); return }
            cursor(at: p).set()
            overlays.redraw()
            return
        }
        selection = nil
        // A plain click (no drag) picks the whole screen when the caller allows it.
        if wasCreate, allowScreenClick, let scr = screen {
            let onPick = onPick
            finish()
            onPick?(.screen(scr))
            return
        }
        overlays.redraw()
    }

    fileprivate func overlayKey(_ e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape: overlayCancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: confirm()
        case kVK_Space where allowWindow && drag == nil:
            let onPick = onPick
            finish()
            onPick?(.window)
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(Int(e.keyCode), step: e.modifierFlags.contains(.shift) ? 10 : 1,
                  resize: e.modifierFlags.contains(.option))
        default: break
        }
    }

    fileprivate func overlayCancel() {
        finish()
        FocusReturn.shared.giveBack(from: nil)
    }

    private func confirm() {
        guard let sel = selection, let scr = screen, sel.width >= 4, sel.height >= 4 else { return }
        let onPick = onPick
        let cut = frozen ? frozenCut(sel, on: scr) : nil
        finish()
        onPick?(cut.map { .frozen($0) } ?? .area(sel, scr))
    }

    /// The selection cut from the frozen still of its display, at full pixel resolution.
    private func frozenCut(_ rect: NSRect, on scr: NSScreen) -> CGImage? {
        guard let id = scr.displayID, let img = stills[id] else { return nil }
        let k = CGFloat(img.width) / scr.frame.width
        let px = CGRect(x: (rect.minX - scr.frame.minX) * k, y: (scr.frame.maxY - rect.maxY) * k,
                        width: rect.width * k, height: rect.height * k).integral
        return img.cropping(to: px)
    }

    /// Arrows move the selection; ⌥ resizes it (right/up grow, left/down shrink).
    private func nudge(_ key: Int, step: CGFloat, resize: Bool) {
        guard var r = selection, drag == nil, let f = screen?.frame else { return }
        let dx: CGFloat = key == kVK_LeftArrow ? -step : key == kVK_RightArrow ? step : 0
        let dy: CGFloat = key == kVK_DownArrow ? -step : key == kVK_UpArrow ? step : 0
        if resize {   // moves the right and top edges
            r.size.width = max(4, min(r.width + dx, f.maxX - r.minX))
            r.size.height = max(4, min(r.height + dy, f.maxY - r.minY))
        } else {
            r = clamp(r.offsetBy(dx: dx, dy: dy), in: f)
        }
        selection = r
        overlays.redraw()
    }

    private func clamp(_ r: NSRect, in f: NSRect) -> NSRect {
        var r = r
        r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
        r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
        return r
    }

    // MARK: handles

    private func handles(_ r: NSRect) -> [(Int, NSPoint)] {
        [(0, NSPoint(x: r.minX, y: r.minY)), (1, NSPoint(x: r.midX, y: r.minY)),
         (2, NSPoint(x: r.maxX, y: r.minY)), (3, NSPoint(x: r.maxX, y: r.midY)),
         (4, NSPoint(x: r.maxX, y: r.maxY)), (5, NSPoint(x: r.midX, y: r.maxY)),
         (6, NSPoint(x: r.minX, y: r.maxY)), (7, NSPoint(x: r.minX, y: r.midY))]
    }

    private func handle(at p: NSPoint) -> Int? {
        guard let sel = selection else { return nil }
        return handles(sel).first { hypot(p.x - $0.1.x, p.y - $0.1.y) <= 7 }?.0
    }

    private func cursor(at p: NSPoint) -> NSCursor {
        guard drag == nil, let sel = selection else { return .crosshair }
        switch handle(at: p) {
        case 1?, 5?: return .resizeUpDown
        case 3?, 7?: return .resizeLeftRight
        case _?: return .crosshair
        case nil: return sel.contains(p) ? .openHand : .crosshair
        }
    }

    // MARK: drawing

    fileprivate func overlayDraw(_ view: OverlayView) {
        let dim = NSColor.black.withAlphaComponent(0.25)
        let viewScreen = view.window?.screen
        if frozen, let id = viewScreen?.displayID, let still = stills[id] {
            NSGraphicsContext.current?.cgContext.draw(still, in: view.bounds)
        }
        let onThisScreen = viewScreen.map { NSMouseInRect(mouse, $0.frame, false) } ?? false
        if let sel = selection, viewScreen?.displayID == screen?.displayID {
            let local = view.local(sel)
            // Dim everything except the selection.
            let shade = NSBezierPath(rect: view.bounds)
            shade.appendRect(local)
            shade.windingRule = .evenOdd
            dim.setFill(); shade.fill()
            let border = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor.white.setStroke(); border.stroke()
            if drag == nil {
                for (_, c) in handles(sel) {
                    let lc = view.local(NSRect(origin: c, size: .zero)).origin
                    let r = NSRect(x: lc.x - 4, y: lc.y - 4, width: 8, height: 8)
                    NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                    NSColor.controlAccentColor.setStroke(); NSBezierPath(ovalIn: r).stroke()
                }
            }
            drawSizeLabel(sel, local: local, in: view)
        } else {
            dim.setFill(); view.bounds.fill()
        }
        if onThisScreen, let viewScreen {
            drawHint(in: view)
            if case .move? = drag {} else { drawLoupe(in: view, screen: viewScreen) }
        }
    }

    /// Pixel size of the capture, just below the selection (inside it at the screen bottom).
    private func drawSizeLabel(_ sel: NSRect, local: NSRect, in view: OverlayView) {
        let scale = screen?.backingScaleFactor ?? 1
        let text = "\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))"
        drawInkChip(text, font: inkFont(13), radius: 5) { sz in
            var box = NSRect(x: local.minX, y: local.minY - sz.height - 12, width: sz.width + 14, height: sz.height + 6)
            if box.minY < view.bounds.minY + 2 { box.origin.y = local.minY + 4; box.origin.x = local.minX + 4 }
            return box
        }
    }

    private func drawHint(in view: OverlayView) {
        var parts: [String]
        if selection != nil, confirmOnRelease {
            parts = ["Release to capture"]
        } else if selection != nil {
            parts = ["Return to confirm", "Drag to adjust", "Arrows to nudge (⌥ resizes)"]
        } else {
            parts = ["Drag to select"]
            if allowScreenClick { parts.append("Click for the whole screen") }
            if allowWindow { parts.append("Space for a window") }
        }
        parts.append("Esc to cancel")
        let top = view.window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        drawInkChip(parts.joined(separator: "  ·  "), font: inkFont(15), radius: 10) { sz in
            NSRect(x: view.bounds.midX - sz.width / 2 - 16, y: view.bounds.maxY - top - sz.height - 30,
                   width: sz.width + 32, height: sz.height + 14)
        }
    }

    /// An 8× pixel magnifier beside the cursor, with the center pixel outlined.
    private func drawLoupe(in view: OverlayView, screen s: NSScreen) {
        guard let id = s.displayID, let img = stills[id], let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = CGFloat(img.width) / s.frame.width
        let px = Int(((mouse.x - s.frame.minX) * scale).rounded(.down))
        let py = Int(((s.frame.maxY - mouse.y) * scale).rounded(.down))
        let n = 15, size: CGFloat = 120, cell = size / CGFloat(n)
        let src = CGRect(x: px - n / 2, y: py - n / 2, width: n, height: n)
        let m = view.local(NSRect(origin: mouse, size: .zero)).origin
        var box = NSRect(x: m.x + 24, y: m.y - 24 - size, width: size, height: size)
        if box.maxX > view.bounds.maxX - 4 { box.origin.x = m.x - 24 - size }
        if box.minY < view.bounds.minY + 30 { box.origin.y = m.y + 24 }
        let frame = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        NSColor.black.setFill(); box.fill()
        let clipped = src.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        if !clipped.isEmpty, let part = img.cropping(to: clipped) {
            ctx.interpolationQuality = .none
            ctx.draw(part, in: CGRect(x: box.minX + (clipped.minX - src.minX) * cell,
                                      y: box.maxY - (clipped.maxY - src.minY) * cell,
                                      width: clipped.width * cell, height: clipped.height * cell))
        }
        let center = NSRect(x: box.minX + CGFloat(n / 2) * cell, y: box.maxY - CGFloat(n / 2 + 1) * cell,
                            width: cell, height: cell)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSRect(x: box.minX, y: center.minY, width: size, height: cell).fill(using: .sourceOver)
        NSRect(x: center.minX, y: box.minY, width: cell, height: size).fill(using: .sourceOver)
        NSColor.white.setStroke(); NSBezierPath(rect: center).stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        frame.lineWidth = 2; frame.stroke()

        drawInkChip("\(px), \(py)", font: inkFont(12), radius: 5) { sz in
            NSRect(x: box.midX - sz.width / 2 - 7, y: box.minY - sz.height - 10, width: sz.width + 14, height: sz.height + 5)
        }
    }

    private func finish() {
        overlays.hide()
        session += 1   // drop stills still loading
        stills.removeAll()
        drag = nil; selection = nil; screen = nil
        onPick = nil; frozen = false
    }
}

// MARK: - Countdown and area frame

/// The big 3‑2‑1 badge before a recording. Click it to cancel.
/// Like all our windows it is excluded from captures.
final class CountdownHUD {
    static let shared = CountdownHUD()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var remaining = 0
    private var completion: ((Bool) -> Void)?
    var isRunning: Bool { panel != nil }

    /// Calls `completion(true)` when the count reaches zero, `false` if cancelled.
    func run(seconds: Int, on screen: NSScreen?, completion: @escaping (Bool) -> Void) {
        cancel()
        self.completion = completion
        remaining = seconds
        let size: CGFloat = 120
        let area = (screen ?? NSScreen.screens[0]).visibleFrame
        // Bottom center, out of the way of the menus and tooltips being set up.
        let p = NSPanel(contentRect: NSRect(x: area.midX - size / 2, y: area.minY + 40, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hasShadow = true
        chromeWindows.add(p)
        let bg = InkSurface(color: Ink.paper, radius: 26)
        bg.frame = NSRect(x: 0, y: 0, width: size, height: size)
        bg.layer?.borderWidth = 1
        bg.effectiveAppearance.performAsCurrentDrawingAppearance { bg.layer?.borderColor = Ink.inkGhost.cgColor }
        let number = NSTextField(labelWithString: "")
        number.font = inkFont(60, bold: true)
        number.textColor = Ink.ink
        number.alignment = .center
        number.frame = NSRect(x: 0, y: 30, width: size, height: 76)
        let hint = NSTextField(labelWithString: "Click to cancel")
        hint.font = inkFont(12)
        hint.textColor = Ink.inkSoft
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 14, width: size, height: 16)
        bg.addSubview(number); bg.addSubview(hint)
        bg.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        p.contentView = bg
        panel = p; label = number
        update()
        p.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.finish(true) } else { self.update() }
        }
    }

    func cancel() { finish(false) }
    @objc private func clicked() { cancel() }
    private func update() { label?.stringValue = "\(remaining)" }

    private func finish(_ go: Bool) {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil; label = nil
        let c = completion
        completion = nil
        c?(go)
    }
}

/// A dashed outline marking the area being recorded.
final class AreaFrame {
    static let shared = AreaFrame()
    private var window: NSWindow?

    func show(_ rect: NSRect) {
        hide()
        let w = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        chromeWindows.add(w)
        w.contentView = DashedBorderView()
        w.orderFrontRegardless()
        window = w
    }
    func hide() { window?.orderOut(nil); window = nil }

    private final class DashedBorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 2
            p.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke(); p.stroke()
        }
    }
}

/// The floating "● 0:12  Stop" bar shown while recording, under the recorded area
/// (or at the bottom of the screen). Draggable by its background.
final class RecordingBar {
    static let shared = RecordingBar()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var onStop: (() -> Void)?

    func show(below area: NSRect?, on screen: NSScreen?, onStop: @escaping () -> Void) {
        hide()
        self.onStop = onStop
        let size = NSSize(width: 168, height: 44)
        let vis = (screen ?? NSScreen.screens[0]).visibleFrame
        var origin = NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 40)
        if let area {
            origin = NSPoint(x: area.midX - size.width / 2, y: area.minY - size.height - 10)
            if origin.y < vis.minY { origin.y = area.maxY + 10 }                   // no room below
            if origin.y + size.height > vis.maxY { origin.y = area.minY + 10 }    // fills the screen
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hasShadow = true
        chromeWindows.add(p)
        let bg = InkSurface(color: Ink.paper, radius: 12)
        bg.frame = NSRect(origin: .zero, size: size)
        bg.layer?.borderWidth = 1
        bg.effectiveAppearance.performAsCurrentDrawingAppearance { bg.layer?.borderColor = Ink.inkGhost.cgColor }
        let dot = InkSurface(color: Ink.seal, radius: 5)
        dot.translatesAutoresizingMaskIntoConstraints = false
        let time = NSTextField(labelWithString: "0:00")
        time.font = inkFont(16)
        time.textColor = Ink.ink
        let stop = InkButton(title: "Stop", style: .stamp, target: self, action: #selector(stopClicked))
        let row = NSStackView(views: [dot, time, NSView(), stop])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -5),
            row.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        p.contentView = bg
        panel = p; label = time
        p.orderFrontRegardless()
        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let t = Int(Date().timeIntervalSince(start))
            self?.label?.stringValue = String(format: "%d:%02d", t / 60, t % 60)
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil; label = nil
        onStop = nil
    }

    @objc private func stopClicked() { let stop = onStop; hide(); stop?() }
}

// MARK: - Screen recording (ScreenCaptureKit → AVAssetWriter)

struct RecordingError: LocalizedError {
    var errorDescription: String? { "The recording captured no frames." }
}

/// Records a display, a region of one, or a window to a movie. SCStream only delivers frames when the
/// screen changes, so the movie's end is taken from elapsed wall time at stop, not
/// from the last frame (a static screen at the end would otherwise be cut off).
// Sendable by confinement: after start(), all mutable state is touched only on `queue`.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private let fileType: AVFileType
    /// Called once on the main queue when the movie is finalized or recording failed.
    var onFinish: ((Error?) -> Void)?
    private let queue = DispatchQueue(label: "Inkshot.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var firstHostTime = CMTime.zero
    private var finished = false

    init(url: URL, fileType: AVFileType) { self.url = url; self.fileType = fileType }

    /// `sourceRect` (display points, top-left origin) limits a display filter to a region.
    func start(filter: SCContentFilter, sourceRect: CGRect? = nil) async throws {
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        let size = sourceRect?.size ?? filter.contentRect.size
        if let r = sourceRect { cfg.sourceRect = r }
        // Even dimensions keep the video encoder happy.
        cfg.width = Int(size.width * scale) & ~1
        cfg.height = Int(size.height * scale) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.queueDepth = 6
        // H.264 tops out at 4096×2304; 5K/6K displays need HEVC.
        let codec: AVVideoCodecType = cfg.width <= 4096 && cfg.height <= 2304 ? .h264 : .hevc
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.writer = writer; self.input = input; self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
            queue.async { self.finish(error: nil) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sb.isValid, let writer, let input else { return }
        // Idle frames (screen unchanged) carry no image; only .complete ones do.
        guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if firstPTS == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            firstPTS = sb.presentationTimeStamp
            firstHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stopping from the system's screen-sharing menu is a normal stop, not a failure.
        let stoppedByUser = (error as? SCStreamError)?.code == .userStopped
        queue.async { self.finish(error: stoppedByUser ? nil : error) }
    }

    private func finish(error: Error?) {   // runs on `queue`
        guard !finished else { return }
        finished = true
        let report: (Error?) -> Void = { e in DispatchQueue.main.async { self.onFinish?(e) } }
        guard let writer, let input, let firstPTS else { report(error ?? RecordingError()); return }
        input.markAsFinished()
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), firstHostTime)
        writer.endSession(atSourceTime: CMTimeAdd(firstPTS, elapsed))
        writer.finishWriting { report(error ?? writer.error) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var editors: [EditorWindowController] = []
    var hotkeyRefs: [Settings.Action: EventHotKeyRef] = [:]
    var menuItems: [Settings.Action: NSMenuItem] = [:]
    var recorder: ScreenRecorder?
    private var quitAfterRecording = false
    var settingsWC: SettingsWindowController?
    var historyWC: HistoryWindowController?
    var aboutWC: AboutWindowController?
    var welcomeWC: WelcomeWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.shared.applyAppearance()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = menuBarIcon() {
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "✂"
        }

        let menu = NSMenu()
        let region = menu.addItem(withTitle: "Capture Region", action: #selector(captureRegion), keyEquivalent: "")
        region.image = symbol("rectangle.dashed"); menuItems[.region] = region
        let win = menu.addItem(withTitle: "Capture Window", action: #selector(captureWindow), keyEquivalent: "")
        win.image = symbol("macwindow"); menuItems[.window] = win
        let full = menu.addItem(withTitle: "Capture Full Screen", action: #selector(captureFull), keyEquivalent: "")
        full.image = symbol("display"); menuItems[.full] = full
        menu.addItem(.separator())
        let rec = menu.addItem(withTitle: "Record Screen", action: #selector(toggleRecording), keyEquivalent: "")
        rec.image = symbol("record.circle"); menuItems[.record] = rec
        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "About Inkshot", action: #selector(openAbout), keyEquivalent: "")
        about.image = symbol("info.circle")
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = symbol("gearshape")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Inkshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        menu.delegate = self
        statusItem.menu = menu
        installMainMenu()
        installHotkeyHandler()
        registerAllHotkeys()
        try? FileManager.default.removeItem(at: dragTempFolder)
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            openWelcome()
        }
    }

    // An unfinalized AVAssetWriter movie is unplayable, so finish (and offer to
    // save) the recording first; `saveRecording` replies once that's done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let rec = recorder else { return .terminateNow }
        quitAfterRecording = true
        rec.stop()
        return .terminateLater
    }

    // Accessory apps never show a menu bar, but NSApp.mainMenu still supplies the
    // standard key equivalents (⌘Z/⌘X/⌘C/⌘V/⌘A in text fields, ⌘W to close).
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        for sub in [NSMenu(title: "Inkshot"), edit, window] {
            let item = NSMenuItem()
            item.submenu = sub
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    func openWelcome() {
        if welcomeWC == nil { welcomeWC = WelcomeWindowController(menuBarIcon: menuBarIcon()) }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWC?.showWindow(nil)
        welcomeWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openAbout() {
        if aboutWC == nil { aboutWC = AboutWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        aboutWC?.showWindow(nil)
        aboutWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openHistory() {
        if historyWC == nil { historyWC = HistoryWindowController() }
        historyWC?.showAndReload()
    }

    // Open a history file (or any image file) in a fresh editor window.
    func openEditor(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let size = NSSize(width: cg.width, height: cg.height)
        let img = NSImage(size: size)
        img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        openEditor(img, size)
    }

    func updateMenuTitle(for a: Settings.Action) {
        guard let item = menuItems[a] else { return }
        let hk = "   \(Settings.shared.display(a))" + (hotkeyRefs[a] == nil ? " (unavailable)" : "")
        switch a {
        case .region: item.title = "Capture Region\(hk)"
        case .window: item.title = "Capture Window\(hk)"
        case .full:   item.title = "Capture Full Screen\(hk)"
        case .record: item.title = (recorder != nil ? "Stop Recording" : "Record Screen") + hk
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    /// Monochrome template icon for the menu bar — the Inkshot motif (a hand-drawn
    /// capture frame with an ink scribble), matching the app icon. Being a template
    /// it adapts to light/dark menu bars.
    /// The app icon's motif as a menu-bar template: four tapered brush corners and an ensō.
    func menuBarIcon() -> NSImage? {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // One brush arm: full width at the corner, thinning to a point at its tip.
            func arm(_ c: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
                let len: CGFloat = 5.2, w0: CGFloat = 2.6, w1: CGFloat = 0.5
                let tip = CGPoint(x: c.x + dx * len, y: c.y + dy * len)
                let nx = -dy, ny = dx
                // Curved flanks keep the stroke's body, then lift sharply, like a brush.
                let body = CGPoint(x: c.x + dx * len * 0.6, y: c.y + dy * len * 0.6), bw = w0 * 0.42
                let p = NSBezierPath()
                p.move(to: CGPoint(x: c.x + nx * w0 / 2, y: c.y + ny * w0 / 2))
                p.curve(to: CGPoint(x: tip.x + nx * w1 / 2, y: tip.y + ny * w1 / 2),
                        controlPoint1: CGPoint(x: body.x + nx * bw, y: body.y + ny * bw),
                        controlPoint2: CGPoint(x: body.x + nx * bw, y: body.y + ny * bw))
                p.line(to: CGPoint(x: tip.x - nx * w1 / 2, y: tip.y - ny * w1 / 2))
                p.curve(to: CGPoint(x: c.x - nx * w0 / 2, y: c.y - ny * w0 / 2),
                        controlPoint1: CGPoint(x: body.x - nx * bw, y: body.y - ny * bw),
                        controlPoint2: CGPoint(x: body.x - nx * bw, y: body.y - ny * bw))
                p.close(); p.fill()
                NSBezierPath(ovalIn: NSRect(x: c.x - w0 / 2, y: c.y - w0 / 2, width: w0, height: w0)).fill()
            }
            let lo: CGFloat = 2.6, hi: CGFloat = 15.4
            for (x, y, sx, sy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (hi, lo, -1.0, 1.0), (lo, lo, 1.0, 1.0)] {
                let c = CGPoint(x: x, y: y)
                arm(c, CGFloat(sx), 0); arm(c, 0, CGFloat(sy))
            }
            // The ensō: a brush ring thinning toward where the brush lifts, left open there.
            let ec = CGPoint(x: 9, y: 9), er: CGFloat = 3.5, n = 40
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let a = Double.pi * 0.15 - Double.pi * 1.8 * Double(t)
                let w = 1.45 * (t < 0.7 ? 1 : 1 - (t - 0.7) / 0.3 * 0.75) / 2
                outer.append(CGPoint(x: ec.x + (er + w) * CGFloat(cos(a)), y: ec.y + (er + w) * CGFloat(sin(a))))
                inner.append(CGPoint(x: ec.x + (er - w) * CGFloat(cos(a)), y: ec.y + (er - w) * CGFloat(sin(a))))
            }
            let ring = NSBezierPath()
            ring.move(to: outer[0])
            for p in outer.dropFirst() + inner.reversed() { ring.line(to: p) }
            ring.close(); ring.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    private func timestampName(ext: String) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Shot \(fmt.string(from: Date())).\(ext)"
    }

    // Shared post-capture flow for every capture mode.
    private func handleCapturedImage(_ img: NSImage, pixelSize: NSSize) {
        // Straight to the clipboard and history; the thumbnail offers a quick edit.
        copyToPasteboard(img)
        HistoryStore.shared.add(img, edited: false)
        if Settings.shared.autoShowShelf {
            // The shelf's newest item is the capture, so no separate thumbnail.
            ShelfController.shared.show(flashNewest: true)
        } else {
            ShelfController.shared.refreshIfVisible()
            ThumbnailController.show(image: img) { [weak self] in self?.openEditor(img, pixelSize) }
        }
    }

    private func copyToPasteboard(_ img: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    private func openEditor(_ img: NSImage, _ size: NSSize) {
        let ec = EditorWindowController(image: img, pixelSize: size)
        editors.append(ec)
        NSApp.activate(ignoringOtherApps: true)
        ec.showWindow(nil)
        ec.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { ec.fitToWindow() }   // after the window has laid out
    }

    // While our own status menu is open, AppKit holds the global hotkeys until it closes, so
    // the menu would always be gone from the shot. Instead the region and full-screen hotkeys
    // are unregistered for that time, their keys are caught inside the menu, and the screen
    // is grabbed before the menu is dismissed. The other hotkeys are left alone.
    private var menuKeyMonitor: Any?
    private let inMenuActions: [Settings.Action] = [.region, .full]

    func menuWillOpen(_ menu: NSMenu) {
        for a in inMenuActions { if let r = hotkeyRefs[a] { UnregisterEventHotKey(r); hotkeyRefs[a] = nil } }
        menuKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak menu] e in
            guard let self, let menu else { return e }
            if self.matches(e, .region) { self.captureRegionInMenu(menu); return nil }
            if self.matches(e, .full) { self.captureFullInMenu(menu); return nil }
            return e
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if let m = menuKeyMonitor { NSEvent.removeMonitor(m); menuKeyMonitor = nil }
        // Re-register once the menu has fully torn down, not from inside its close.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for a in self.inMenuActions { self.registerHotkey(for: a) }
        }
    }

    @objc func captureRegion() { captureRegionInMenu(nil) }

    /// `menu`: our status menu, still open — kept on screen until the freeze-frame is taken.
    private func captureRegionInMenu(_ menu: NSMenu?) {
        guard ensureScreenCapturePermission() else { menu?.cancelTracking(); return }
        RegionSelectController.shared.begin(confirmOnRelease: true, freeze: true,
                                            willShow: { menu?.cancelTracking() }) { [weak self] pick in
            if case .frozen(let cg) = pick { self?.playShutter(); self?.sckPostProcess(cg); return }
            guard case .area(let rect, let screen) = pick else { return }
            self?.shareableContent(excludingDesktop: false) { content in
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                self?.sckCapture(filter: Self.displayFilter(display, in: content),
                                 sourceRect: Self.sourceRect(rect, on: screen))
            }
        }
    }

    /// A global AppKit rect → `sourceRect` space: display points with a top-left origin.
    private static func sourceRect(_ rect: NSRect, on screen: NSScreen) -> CGRect {
        CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    @objc func captureWindow() {
        guard ensureScreenCapturePermission() else { return }
        shareableContent(excludingDesktop: true) { [weak self] content in
            WindowPickerController.shared.begin(content: content) { window in
                self?.sckCapture(filter: SCContentFilter(desktopIndependentWindow: window))
            }
        }
    }

    @objc func captureFull() {
        guard ensureScreenCapturePermission() else { return }
        // Let the status menu finish closing before the grab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.shareableContent(excludingDesktop: false) { content in
                guard let display = Self.mainDisplay(in: content) else { return }
                self?.sckCapture(filter: Self.displayFilter(display, in: content))
            }
        }
    }

    /// The full-screen hotkey pressed inside our open status menu: grab it, then close it.
    private func captureFullInMenu(_ menu: NSMenu) {
        guard ensureScreenCapturePermission() else { menu.cancelTracking(); return }
        shareableContent(excludingDesktop: false) { [weak self] content in
            guard let display = Self.mainDisplay(in: content) else { menu.cancelTracking(); return }
            self?.sckCapture(filter: Self.displayFilter(display, in: content), before: { menu.cancelTracking() })
        }
    }

    private var requestedScreenCapture = false

    /// ScreenCaptureKit fails without Screen Recording permission. The first request
    /// in a process makes macOS show its own Allow / Open System Settings dialog (and
    /// adds Inkshot to the Settings list). The answer is cached until relaunch, so
    /// later attempts in this process get our own pointer to System Settings instead.
    func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let firstAsk = !requestedScreenCapture
        requestedScreenCapture = true
        if CGRequestScreenCaptureAccess() { return true }
        if firstAsk { return false }   // the system dialog is on screen

        let a = NSAlert()
        a.messageText = "Inkshot can't see the screen yet"
        a.informativeText = "Turn on Inkshot in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Inkshot.\n\nInkshot looks at the screen only when you take a shot or record, never records audio, and nothing leaves this Mac."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
        return false
    }

    /// Loads the current windows/displays, then continues on the main thread
    /// (overlays and capture setup are AppKit work).
    private func shareableContent(excludingDesktop: Bool, _ body: @escaping (SCShareableContent) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(excludingDesktop, onScreenWindowsOnly: true)
                await MainActor.run { body(content) }
            } catch {
                await MainActor.run { showError(error) }
            }
        }
    }

    /// SCDisplay for the menu-bar screen, matched by display ID.
    private static func mainDisplay(in content: SCShareableContent) -> SCDisplay? {
        let id = NSScreen.screens.first?.displayID
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    private static func displayFilter(_ display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        ownChromeFilter(display, in: content, excluding: chromeWindowIDs())
    }

    /// `before` runs on the main thread once the pixels are in, ahead of the post-capture UI.
    private func sckCapture(filter: SCContentFilter, sourceRect: CGRect? = nil, before: (() -> Void)? = nil) {
        Task { [weak self] in
            let cfg = SCStreamConfiguration()
            // Output size defaults to 1920×1080 regardless of the source; size it to the content.
            let size = sourceRect?.size ?? filter.contentRect.size
            if let r = sourceRect { cfg.sourceRect = r }
            cfg.width = Int((size.width * CGFloat(filter.pointPixelScale)).rounded())
            cfg.height = Int((size.height * CGFloat(filter.pointPixelScale)).rounded())
            cfg.captureResolution = .best   // native pixel resolution (retina)
            cfg.showsCursor = false
            do {
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                guard let self else { return }
                await MainActor.run { before?(); self.playShutter(); self.sckPostProcess(cg) }
            } catch {
                await MainActor.run { before?(); showError(error) }
            }
        }
    }

    private func playShutter() {
        guard Settings.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }

    private func sckPostProcess(_ cg: CGImage) {
        let pixelSize = NSSize(width: cg.width, height: cg.height)
        let img = NSImage(size: pixelSize)
        img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        if Settings.shared.openEditorAfterCapture {
            handleCapturedImage(img, pixelSize: pixelSize)
        } else {
            saveCGImage(cg)
        }
    }

    /// Encodes to the chosen format and writes into the save folder; under the
    /// sandbox (or any unwritable folder) falls back to a save panel.
    private func saveCGImage(_ cg: CGImage) {
        let fmt = Settings.shared.captureFormat
        let utiString = fmt == "jpg" ? "public.jpeg" : fmt == "tiff" ? "public.tiff"
                      : fmt == "pdf" ? "com.adobe.pdf" : "public.png"
        let mdata = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mdata, utiString as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        let data = mdata as Data
        do {
            let file = try Settings.shared.accessingSaveDirectory { dir -> URL in
                let file = dir.appendingPathComponent(timestampName(ext: fmt))
                try data.write(to: file, options: .atomic)
                return file
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            // Unwritable folder (e.g. sandboxed Desktop): let the user place it.
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: fmt) ?? .png]
            panel.nameFieldStringValue = timestampName(ext: fmt)
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                do { try data.write(to: url) } catch { showError(error) }
            }
        }
    }

    // MARK: screen recording

    @objc func toggleRecording() {
        if let r = recorder { r.stop() }
        else if CountdownHUD.shared.isRunning { CountdownHUD.shared.cancel() }
        else { startRecording() }
    }

    /// Drag a region, click a screen, or press Space to pick a window; then a 3‑second
    /// countdown. The movie goes to a temp file and is saved (or converted) at stop.
    private func startRecording() {
        guard ensureScreenCapturePermission() else { return }
        RegionSelectController.shared.begin(allowScreenClick: true, allowWindow: true) { [weak self] pick in
            guard let self else { return }
            let isWindow: Bool
            if case .window = pick { isWindow = true } else { isWindow = false }
            self.shareableContent(excludingDesktop: isWindow) { content in
                switch pick {
                case .area(let rect, let screen):
                    guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                    self.beginRecording(filter: Self.displayFilter(display, in: content),
                                        sourceRect: Self.sourceRect(rect, on: screen), frame: rect, screen: screen)
                case .screen(let screen):
                    guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                    self.beginRecording(filter: Self.displayFilter(display, in: content),
                                        sourceRect: nil, frame: nil, screen: screen)
                case .window:
                    WindowPickerController.shared.begin(content: content) { window in
                        let mouse = NSEvent.mouseLocation
                        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                        self.beginRecording(filter: SCContentFilter(desktopIndependentWindow: window),
                                            sourceRect: nil, frame: nil, screen: screen)
                    }
                case .frozen:
                    break   // recording selects over the live screen, never frozen
                }
            }
        }
    }

    private func beginRecording(filter: SCContentFilter, sourceRect: CGRect?, frame: NSRect?, screen: NSScreen?) {
        FocusReturn.shared.giveBack(from: nil)
        if let frame { AreaFrame.shared.show(frame) }
        CountdownHUD.shared.run(seconds: 3, on: screen) { [weak self] go in
            guard let self, go else { AreaFrame.shared.hide(); return }
            let format = Settings.shared.recordingFormat
            // GIFs are made from a movie once recording stops.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Inkshot-\(UUID().uuidString).\(format == "mp4" ? "mp4" : "mov")")
            let rec = ScreenRecorder(url: tmp, fileType: format == "mp4" ? .mp4 : .mov)
            rec.onFinish = { [weak self] error in
                AreaFrame.shared.hide()
                RecordingBar.shared.hide()
                guard let self else { return }
                self.recorder = nil
                self.updateRecordUI()
                if let error {
                    try? FileManager.default.removeItem(at: tmp)
                    showError(error)
                    self.recordingSaved()
                } else {
                    self.saveRecording(tmp, format: format)
                }
            }
            self.recorder = rec
            self.updateRecordUI()
            RecordingBar.shared.show(below: frame, on: screen) { rec.stop() }
            Task {
                do { try await rec.start(filter: filter, sourceRect: sourceRect) }
                catch { await MainActor.run { rec.onFinish?(error) } }
            }
        }
    }

    private func saveRecording(_ tmp: URL, format: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == "gif" ? .gif : format == "mov" ? .quickTimeMovie : .mpeg4Movie]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Recording \(fmt.string(from: Date())).\(format)"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            try? FileManager.default.removeItem(at: tmp)
            recordingSaved()
            return
        }
        if format == "gif" {
            Task {
                let failure: Error?
                do { try await Self.makeGIF(from: tmp, to: url); failure = nil } catch { failure = error }
                await MainActor.run {
                    try? FileManager.default.removeItem(at: tmp)
                    if let failure { showError(failure) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    self.recordingSaved()
                }
            }
            return
        }
        do {
            try? FileManager.default.removeItem(at: url)   // the save panel already confirmed replacing it
            try FileManager.default.moveItem(at: tmp, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error)
        }
        recordingSaved()
    }

    private func recordingSaved() {
        if quitAfterRecording { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    /// Converts a movie to a looping GIF at 15 fps, at most 960 px on the long side.
    static func makeGIF(from src: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        let fps = 15.0
        let count = max(1, Int(try await asset.load(.duration).seconds * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 960, height: 960)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, count, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let (img, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, img, frame)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func updateRecordUI() {
        let on = recorder != nil
        updateMenuTitle(for: .record)
        menuItems[.record]?.image = symbol(on ? "stop.circle.fill" : "record.circle")
        if on, let icon = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Recording") {
            icon.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.contentTintColor = .systemRed
        } else {
            statusItem.button?.image = menuBarIcon()
            statusItem.button?.contentTintColor = nil
        }
    }

    // Global hotkeys: one per Settings.Action, dispatched by its id.
    private let hotkeySignature = OSType(0x4C534854) // 'LSHT'

    private func installHotkeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = Int(hk.id)
            DispatchQueue.main.async {
                guard let d = NSApp.delegate as? AppDelegate, let a = Settings.Action(rawValue: id) else { return }
                switch a {
                case .region: d.captureRegion()
                case .window: d.captureWindow()
                case .full:   d.captureFull()
                case .record: d.toggleRecording()
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    private func matches(_ e: NSEvent, _ a: Settings.Action) -> Bool {
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return Int(e.keyCode) == Settings.shared.keyCode(a)
            && e.modifierFlags.intersection(mask) == NSEvent.ModifierFlags(rawValue: Settings.shared.modifiers(a)).intersection(mask)
    }

    func registerAllHotkeys() {
        unregisterAllHotkeys()
        for a in Settings.Action.allCases { registerHotkey(for: a) }
    }

    func unregisterAllHotkeys() {
        for r in hotkeyRefs.values { UnregisterEventHotKey(r) }
        hotkeyRefs.removeAll()
    }

    // (Re)registers one action's global hotkey from the current settings.
    func registerHotkey(for a: Settings.Action) {
        if let r = hotkeyRefs[a] { UnregisterEventHotKey(r); hotkeyRefs[a] = nil }
        let mods = NSEvent.ModifierFlags(rawValue: Settings.shared.modifiers(a))
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(Settings.shared.keyCode(a)), carbonFlags(from: mods),
                                         EventHotKeyID(signature: hotkeySignature, id: UInt32(a.rawValue)),
                                         GetApplicationEventTarget(), 0, &ref)
        hotkeyRefs[a] = status == noErr ? ref : nil
        updateMenuTitle(for: a)
    }
}

// Entry point: see main.swift (top-level bootstrap, shared by build.sh and Xcode).
