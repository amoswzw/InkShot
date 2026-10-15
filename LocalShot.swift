// LocalShot — a private, local-only screenshot & annotation app for macOS.
// Capture uses the system `screencapture`; annotation is native AppKit.
// No networking anywhere.

import Cocoa
import CoreImage
import Carbon.HIToolbox
import UniformTypeIdentifiers
import ServiceManagement
import ScreenCaptureKit

// MARK: - Model

enum Tool: Int, CaseIterable {
    case select, rect, ellipse, arrow, line, pen, marker, text, number, mosaic, blur
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rect: return "rectangle"; case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"; case .line: return "line.diagonal"
        case .pen: return "pencil.tip"; case .marker: return "highlighter"
        case .text: return "character"; case .number: return "number.circle"
        case .mosaic: return "square.grid.3x3.fill"; case .blur: return "drop.fill"
        }
    }
    var glyph: String {
        switch self {
        case .select: return "⌖"
        case .rect: return "▭"; case .ellipse: return "◯"; case .arrow: return "➔"
        case .line: return "╱"; case .pen: return "✎"; case .marker: return "▰"
        case .text: return "T"; case .number: return "①"; case .mosaic: return "▦"
        case .blur: return "☁"
        }
    }
    var help: String {
        switch self {
        case .select: return "Select / move"
        case .rect: return "Rectangle"; case .ellipse: return "Ellipse"; case .arrow: return "Arrow"
        case .line: return "Line"; case .pen: return "Pen"; case .marker: return "Highlighter"
        case .text: return "Text"; case .number: return "Numbered step"; case .mosaic: return "Mosaic (pixelate)"
        case .blur: return "Blur"
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
}

// MARK: - UI building blocks

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
        widthAnchor.constraint(equalToConstant: 40).isActive = true
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

    private func refresh() {
        if isSelectedTool {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            contentTintColor = .white
        } else if !isEnabled {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .tertiaryLabelColor
        } else if hovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
            contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .secondaryLabelColor
        }
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
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 19
        let r = NSRect(x: (bounds.width - d)/2, y: (bounds.height - d)/2, width: d, height: d)
        let dot = NSBezierPath(ovalIn: r)
        swatch.setFill(); dot.fill()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke(); dot.lineWidth = 1; dot.stroke()
        if isSelectedSwatch {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.controlAccentColor.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
    }
}

/// Groups related controls into one subtly tinted, rounded cluster.
func pill(_ views: [NSView], spacing: CGFloat = 3) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.alignment = .centerY
    s.spacing = spacing
    s.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
    s.translatesAutoresizingMaskIntoConstraints = false
    s.wantsLayer = true
    s.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    s.layer?.cornerRadius = 9
    return s
}

// MARK: - Canvas

final class CanvasView: NSView {
    var baseImage: NSImage
    let pixelSize: NSSize
    private var ops: [Op] = []
    private var undone: [[Op]] = []
    private var redoStack: [[Op]] = []

    var currentTool: Tool = .rect {
        didSet { selected = nil; needsDisplay = true }
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
    private var textField: NSTextField?
    private var pendingTextOrigin: CGPoint?

    var onHistoryChange: (() -> Void)?

    init(image: NSImage, pixelSize: NSSize) {
        self.baseImage = image
        self.pixelSize = pixelSize
        super.init(frame: NSRect(origin: .zero, size: pixelSize))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    var canUndo: Bool { !ops.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        baseImage.draw(in: bounds)
        for op in ops { drawOp(op) }
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
    }

    private func drawOp(_ op: Op) {
        op.color.setStroke()
        op.color.setFill()
        let path = NSBezierPath()
        path.lineWidth = op.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch op.tool {
        case .select:
            break
        case .rect:
            path.appendRect(op.rect); path.stroke()
        case .ellipse:
            path.appendOval(in: op.rect); path.stroke()
        case .line:
            path.move(to: op.p1); path.line(to: op.p2); path.stroke()
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
        let dx = op.p2.x - op.p1.x, dy = op.p2.y - op.p1.y
        let len = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)
        // Head proportional to line width, clamped so it never exceeds the shaft.
        let headLen = min(max(op.width * 4.5, 16), len * 0.9)
        let headHalf = max(op.width * 1.8, headLen * 0.42)
        // Shaft stops at the head's base so the round cap doesn't poke through.
        let base = CGPoint(x: op.p2.x - headLen * cos(angle),
                           y: op.p2.y - headLen * sin(angle))
        let shaft = NSBezierPath()
        shaft.lineWidth = op.width; shaft.lineCapStyle = .round
        shaft.move(to: op.p1); shaft.line(to: base); shaft.stroke()
        // Perpendicular offset for the two base corners of the arrowhead.
        let px = -sin(angle), py = cos(angle)
        let b1 = CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf)
        let b2 = CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf)
        let head = NSBezierPath()
        head.move(to: op.p2); head.line(to: b1); head.line(to: b2); head.close()
        head.fill()
    }

    private func drawText(_ op: Op) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: op.fontSize),
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
        guard op.rect.width > 2, op.rect.height > 2,
              let tiff = baseImage.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return }
        let sx = ci.extent.width / bounds.width
        let sy = ci.extent.height / bounds.height
        let pr = CGRect(x: op.rect.origin.x * sx, y: op.rect.origin.y * sy,
                        width: op.rect.width * sx, height: op.rect.height * sy)
        let filter: CIFilter?
        if op.tool == .blur {
            filter = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: ci.clampedToExtent(),
                kCIInputRadiusKey: max(6, min(pr.width, pr.height) / 12)])
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
            let sz = (op.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: op.fontSize)])
            return CGRect(x: op.origin.x, y: op.origin.y, width: sz.width, height: sz.height)
        case .number:
            let r = max(op.width * 3, 16)
            return CGRect(x: op.origin.x - r, y: op.origin.y - r, width: r * 2, height: r * 2)
        case .select:
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
            let r = op.rect
            return [(0, CGPoint(x: r.minX, y: r.minY)), (1, CGPoint(x: r.midX, y: r.minY)),
                    (2, CGPoint(x: r.maxX, y: r.minY)), (3, CGPoint(x: r.maxX, y: r.midY)),
                    (4, CGPoint(x: r.maxX, y: r.maxY)), (5, CGPoint(x: r.midX, y: r.maxY)),
                    (6, CGPoint(x: r.minX, y: r.maxY)), (7, CGPoint(x: r.minX, y: r.midY))]
        case .line, .arrow:
            return [(0, op.p1), (1, op.p2)]
        default:
            return []   // pen, marker, text, number: move only
        }
    }

    private func handleHit(_ op: Op, at p: CGPoint) -> Int? {
        let tol = max(9 / viewScale, 6)
        for (id, c) in handlePoints(op) where hypot(p.x - c.x, p.y - c.y) <= tol { return id }
        return nil
    }

    private func drawHandles(_ op: Op) {
        let s = 7 / viewScale
        for (_, c) in handlePoints(op) {
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
            var x0 = o.rect.minX, y0 = o.rect.minY, x1 = o.rect.maxX, y1 = o.rect.maxY
            if [0, 6, 7].contains(handle) { x0 = p.x }
            if [2, 3, 4].contains(handle) { x1 = p.x }
            if [0, 1, 2].contains(handle) { y0 = p.y }
            if [4, 5, 6].contains(handle) { y1 = p.y }
            o.rect = CGRect(x: min(x0, x1), y: min(y0, y1),
                            width: max(abs(x1 - x0), 4), height: max(abs(y1 - y0), 4))
        default:
            break
        }
        return o
    }

    // MARK: text entry

    private func beginText(at p: CGPoint) {
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - currentFontSize, width: 240, height: currentFontSize + 8))
        tf.font = NSFont.systemFont(ofSize: currentFontSize)
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

    @objc private func textCommitted() { commitText() }

    private func commitText() {
        guard let tf = textField, let origin = pendingTextOrigin else { return }
        let str = tf.stringValue
        tf.removeFromSuperview(); textField = nil; pendingTextOrigin = nil
        if !str.trimmingCharacters(in: .whitespaces).isEmpty {
            pushHistory()
            var op = Op(tool: .text, color: currentColor, width: currentWidth)
            op.text = str; op.origin = origin; op.fontSize = currentFontSize
            ops.append(op); redoStack.removeAll()
        }
        needsDisplay = true; onHistoryChange?()
    }

    // MARK: history / edit

    private func pushHistory() { undone.append(ops) }

    func undo() {
        commitText()
        guard let prev = undone.popLast() else { return }
        redoStack.append(ops); ops = prev; selected = nil; needsDisplay = true; onHistoryChange?()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undone.append(ops); ops = next; selected = nil; needsDisplay = true; onHistoryChange?()
    }
    func clearAll() {
        guard !ops.isEmpty else { return }
        pushHistory(); ops.removeAll(); selected = nil; needsDisplay = true; onHistoryChange?()
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
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }
    func pngData() -> Data? {
        let rep = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Editor window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let canvas: CanvasView
    private var toolButtons: [IconButton] = []
    private var swatchButtons: [SwatchButton] = []
    private var undoBtn: IconButton!
    private var redoBtn: IconButton!
    private var colorWell: NSColorWell!
    private var scroll: NSScrollView!

    private static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white
    ]
    // size index -> (line width, font size)
    private static let sizes: [(CGFloat, CGFloat)] = [(2, 18), (4, 28), (8, 42), (14, 64)]

    init(image: NSImage, pixelSize: NSSize) {
        canvas = CanvasView(image: image, pixelSize: pixelSize)

        // Size the window to the capture's aspect ratio so the image fills the
        // canvas with no letterbox. The toolbar sets a floor on width.
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let toolbarH: CGFloat = 60
        let fitScale = min((vis.width - 80) / pixelSize.width,
                           (vis.height - 120 - toolbarH) / pixelSize.height, 1.0)
        let imgW = max((pixelSize.width * fitScale).rounded(), 1)
        let imgH = max((pixelSize.height * fitScale).rounded(), 1)
        let contentW = max(imgW, 820)
        let contentH = imgH + toolbarH
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "LocalShot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // Translucent header bar, merged with the title bar.
        let header = NSVisualEffectView()
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false

        // Tools group
        for tool in Tool.allCases {
            let b = IconButton(symbol: tool.symbol, fallbackGlyph: tool.glyph)
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

        // Right: history + actions
        undoBtn = IconButton(symbol: "arrow.uturn.backward", fallbackGlyph: "⤺")
        undoBtn.toolTip = "Undo (⌘Z)"; undoBtn.target = self; undoBtn.action = #selector(undo)
        redoBtn = IconButton(symbol: "arrow.uturn.forward", fallbackGlyph: "⤻")
        redoBtn.toolTip = "Redo (⇧⌘Z)"; redoBtn.target = self; redoBtn.action = #selector(redo)
        let clearBtn = IconButton(symbol: "trash", fallbackGlyph: "␡")
        clearBtn.toolTip = "Clear all"; clearBtn.target = self; clearBtn.action = #selector(clearAll)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .large
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveImage))
        saveBtn.bezelStyle = .rounded
        saveBtn.controlSize = .large
        saveBtn.keyEquivalent = "s"; saveBtn.keyEquivalentModifierMask = .command
        saveBtn.bezelColor = .controlAccentColor

        // Assemble into tidy grouped pills.
        let left = NSStackView(views: [pill(toolButtons), pill(swatchButtons + [colorWell]), sizeControl])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 12
        left.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [pill([undoBtn, redoBtn, clearBtn]), copyBtn, saveBtn])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(left)
        header.addSubview(right)

        // Scrollable canvas on a neutral backing; zoomed to fit the window.
        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
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

            left.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 82),
            left.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // Ensure the window is at least wide enough for the toolbar, and open at
        // the capture's aspect where possible so there is no letterbox.
        let toolbarWidth = ceil(left.fittingSize.width + right.fittingSize.width + 82 + 20 + 14)
        let targetW = max(contentW, toolbarWidth)
        window.contentMinSize = NSSize(width: toolbarWidth, height: 320)
        window.setContentSize(NSSize(width: targetW, height: contentH))
        window.center()
        window.delegate = self

        canvas.onHistoryChange = { [weak self] in
            guard let self = self else { return }
            self.undoBtn.isEnabled = self.canvas.canUndo
            self.redoBtn.isEnabled = self.canvas.canRedo
        }
        undoBtn.isEnabled = false
        redoBtn.isEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // Zoom the capture so the whole image fits the viewport (never upscaled past 1:1).
    func fitToWindow() {
        guard scroll != nil else { return }
        let avail = scroll.bounds.size
        guard avail.width > 1, avail.height > 1,
              canvas.pixelSize.width > 1, canvas.pixelSize.height > 1 else { return }
        let scale = min(avail.width / canvas.pixelSize.width, avail.height / canvas.pixelSize.height)
        let mag = min(max(scale, scroll.minMagnification), 1.0)
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
    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func clearAll() { canvas.clearAll() }

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
            if resp == .OK, let url = panel.url {
                try? data.write(to: url)
                if let img = self?.canvas.renderedImage() { HistoryStore.shared.add(img, edited: true) }
                ShelfController.shared.refreshIfVisible()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z": event.modifierFlags.contains(.shift) ? canvas.redo() : canvas.undo(); return
            case "c": copyImage(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Settings

/// Persisted preferences, backed by UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // The four actions that each get a global hotkey. rawValue is the hotkey id.
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
        var defaultDisplay: String {
            switch self { case .region: return "⌃⌘A"; case .window: return "⌃⌘W"
                          case .full: return "⌃⌘F"; case .record: return "⌃⌘R" }
        }
    }

    private init() {
        var defs: [String: Any] = ["playSound": false, "captureFormat": "png",
                                   "openEditorAfterCapture": true, "shelfMode": "corner",
                                   "shelfPinned": true, "shelfAutoHide": false]
        let mods = Int(NSEvent.ModifierFlags([.control, .command]).rawValue)
        for a in Action.allCases {
            defs["hotkey.\(a.key).code"] = a.defaultCode
            defs["hotkey.\(a.key).mods"] = mods
            defs["hotkey.\(a.key).display"] = a.defaultDisplay
        }
        d.register(defaults: defs)
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
    var openEditorAfterCapture: Bool {
        get { d.bool(forKey: "openEditorAfterCapture") } set { d.set(newValue, forKey: "openEditorAfterCapture") }
    }
    // "corner", "dock", "both", or "off".
    var shelfMode: String {
        get { d.string(forKey: "shelfMode") ?? "corner" } set { d.set(newValue, forKey: "shelfMode") }
    }
    var autoShowShelf: Bool { shelfMode == "corner" || shelfMode == "both" }
    var usesDockFolder: Bool { shelfMode == "dock" || shelfMode == "both" }
    var shelfPinned: Bool {
        get { d.bool(forKey: "shelfPinned") } set { d.set(newValue, forKey: "shelfPinned") }
    }
    var shelfAutoHide: Bool {
        get { d.bool(forKey: "shelfAutoHide") } set { d.set(newValue, forKey: "shelfAutoHide") }
    }
    var saveDirectory: URL {
        get {
            if let p = d.string(forKey: "saveDirectory") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        set { d.set(newValue.path, forKey: "saveDirectory") }
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
    var onChange: ((Settings.Action) -> Void)?
    private var monitor: Any?

    init(action: Settings.Action) {
        recordAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        title = Settings.shared.display(action)
        target = self
        self.action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func begin() {
        title = "Type shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.finish(); return nil }   // escape cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return nil }                // require a modifier
            let key = (event.charactersIgnoringModifiers ?? "").uppercased()
            let display = self.symbols(mods) + key
            Settings.shared.setHotkey(self.recordAction, code: Int(event.keyCode), mods: mods.rawValue, display: display)
            self.title = display
            self.onChange?(self.recordAction)
            self.finish()
            return nil
        }
    }
    private func finish() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if title == "Type shortcut…" { title = Settings.shared.display(recordAction) }
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
    private let shelfOrder = ["corner", "dock", "both", "off"]
    private var saveButton: NSButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 462),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LocalShot Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        func recorder(_ a: Settings.Action) -> HotkeyRecorder {
            let r = HotkeyRecorder(action: a)
            r.onChange = { action in (NSApp.delegate as? AppDelegate)?.registerHotkey(for: action) }
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

        let shelfPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shelfPopup.addItems(withTitles: ["Corner shelf", "Dock folder", "Both", "Off"])
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
            historyButton("Open Folder", #selector(openFolderTapped(_:))),
            historyButton("Show Shelf", #selector(showShelfTapped(_:))),
        ])
        historyRow.spacing = 8

        let editorCheck = NSButton(checkboxWithTitle: "Copy to clipboard & show quick‑edit thumbnail (off: save to file)",
                                   target: self, action: #selector(toggleEditor(_:)))
        editorCheck.state = Settings.shared.openEditorAfterCapture ? .on : .off

        let loginCheck = NSButton(checkboxWithTitle: "Open LocalShot at login",
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
            [label("Save to:"), saveButton],
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
        ])
        window.contentView = content
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleSound(_ s: NSButton) { Settings.shared.playSound = (s.state == .on) }
    @objc private func showHistory(_ s: NSButton) { (NSApp.delegate as? AppDelegate)?.openHistory() }
    @objc private func openFolderTapped(_ s: NSButton) { (NSApp.delegate as? AppDelegate)?.openHistoryFolder() }
    @objc private func showShelfTapped(_ s: NSButton) { ShelfController.shared.show() }
    @objc private func toggleEditor(_ s: NSButton) { Settings.shared.openEditorAfterCapture = (s.state == .on) }
    @objc private func formatChanged(_ s: NSPopUpButton) {
        Settings.shared.captureFormat = formatOrder[max(0, s.indexOfSelectedItem)]
    }
    @objc private func shelfModeChanged(_ s: NSPopUpButton) {
        let mode = shelfOrder[max(0, s.indexOfSelectedItem)]
        Settings.shared.shelfMode = mode
        if Settings.shared.usesDockFolder { NSWorkspace.shared.open(HistoryStore.shared.folder) }
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
        window.title = "About LocalShot"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        icon.contentTintColor = .controlAccentColor

        let name = NSTextField(labelWithString: "LocalShot")
        name.font = .systemFont(ofSize: 20, weight: .bold)

        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let version = NSTextField(labelWithString: "Version \(ver)")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "Private screenshots, annotation & screen recording.")
        tagline.font = .systemFont(ofSize: 11)
        tagline.textColor = .secondaryLabelColor

        let privacy = NSTextField(labelWithString: "No networking. No telemetry. Everything stays on this Mac.")
        privacy.font = .systemFont(ofSize: 11)
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

// MARK: - Post-capture thumbnail

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
    private var downPoint = NSPoint.zero
    private var dragging = false

    override func menu(for event: NSEvent) -> NSMenu? { rightMenu }

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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShot \(fmt.string(from: Date())).png")
        try? png.write(to: url)
        cachedURL = url
        return url
    }

    func pasteboard(_ pb: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .fileURL: if let u = dragURL() { item.setString(u.absoluteString, forType: .fileURL) }
        case .png: if let u = dragURL(), let d = try? Data(contentsOf: u) { item.setData(d, forType: .png) }
        case .tiff: if let d = image?.tiffRepresentation { item.setData(d, forType: .tiff) }
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        super.init()

        let container = NSView(frame: rect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let iv = DraggableImageView(frame: NSRect(x: 0, y: barH, width: w, height: h))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.onClick = { [weak self] in self?.editAction() }
        iv.onDragBegan = { [weak self] in self?.timer?.invalidate() }
        iv.onDragEnded = { [weak self] in self?.dismiss() }
        iv.onHoverIn = { [weak self] in self?.timer?.invalidate() }      // don't vanish mid-interaction
        iv.onHoverOut = { [weak self] in self?.restartTimer() }
        container.addSubview(iv)

        let hint = NSTextField(labelWithString: "Drag out · Space to edit · Esc")
        hint.frame = NSRect(x: 0, y: 3, width: w, height: barH - 4)
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
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
        if let vf = NSScreen.main?.visibleFrame {
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
        NSApp.activate(ignoringOtherApps: true)   // so Space/Esc reach the panel and are consumed
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            switch e.keyCode {
            case 49, 36: self.editAction(); return nil   // space, return
            case 53: self.dismiss(); return nil          // escape
            default: return e
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    @objc private func editAction() {
        let cb = onEdit
        dismiss()
        cb()
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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
        folder = base.appendingPathComponent("LocalShot/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ image: NSImage, edited: Bool) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let url = folder.appendingPathComponent("Shot \(fmt.string(from: Date()))\(edited ? "-edited" : "").png")
        try? png.write(to: url)
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
        window.title = "LocalShot History"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
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

    func windowDidResize(_ notification: Notification) { reload() }
    func refresh() { if window?.isVisible == true { reload() } }

    private func reload() {
        grid.subviews.forEach { $0.removeFromSuperview() }
        let urls = HistoryStore.shared.recent()
        let pad: CGFloat = 16, cell: CGFloat = 196, thumbH: CGFloat = 132
        let width = max(scroll.contentView.bounds.width, cell + pad * 2)
        let cols = max(1, Int((width - pad) / (cell + pad)))
        for (i, url) in urls.enumerated() {
            let row = i / cols, col = i % cols
            let x = pad + CGFloat(col) * (cell + pad)
            let y = pad + CGFloat(row) * (thumbH + pad)
            let iv = DraggableImageView(frame: NSRect(x: x, y: y, width: cell, height: thumbH))
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 8
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 1
            iv.layer?.borderColor = NSColor.separatorColor.cgColor
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.image = NSImage(contentsOf: url)
            iv.sourceURL = url
            iv.toolTip = url.lastPathComponent
            iv.onClick = { [weak self] in self?.open(url) }
            iv.rightMenu = contextMenu(for: url)
            grid.addSubview(iv)
        }
        let rows = (urls.count + cols - 1) / cols
        let height = max(scroll.contentView.bounds.height, pad + CGFloat(max(rows, 1)) * (thumbH + pad))
        grid.frame = NSRect(x: 0, y: 0, width: width, height: height)
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
        if let u = s.representedObject as? URL { HistoryStore.shared.delete(u); reload() }
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
    private let pad: CGFloat = 12, gap: CGFloat = 10, headerH: CGFloat = 32

    var isVisible: Bool { panel?.isVisible ?? false }
    var panelFrame: NSRect? { panel?.frame }
    private var pendingFlash = false
    private var quickEditURL: URL?
    private var quickMonitor: Any?
    private var quickTimer: Timer?
    private weak var hintLabel: NSTextField?
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
            p.hasShadow = true; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
        Settings.shared.shelfAutoHide ? vf.maxX - w : vf.maxX - w - 16
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
        let w = itemW + pad * 2
        let listH = urls.isEmpty ? 54 : CGFloat(urls.count) * itemH + CGFloat(urls.count - 1) * gap
        let height = headerH + pad + listH + pad
        let frame = NSRect(x: 0, y: 0, width: w, height: height)

        // Frosted, rounded background.
        let bg = NSVisualEffectView(frame: frame)
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

        // Header: title + pin / clear / close.
        let title = NSTextField(labelWithString: "Recent")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: pad, y: height - headerH + (headerH - 16) / 2, width: 120, height: 16)
        bg.addSubview(title)

        let btn: CGFloat = 20, bgap: CGFloat = 2
        let by = height - headerH + (headerH - btn) / 2
        var bx = w - pad - btn
        bg.addSubview(headerButton("xmark", symbolSize: 11, tint: .secondaryLabelColor,
                                   tip: "Close", action: #selector(closeShelf), frame: NSRect(x: bx, y: by, width: btn, height: btn)))
        bx -= (btn + bgap)
        bg.addSubview(headerButton("trash", symbolSize: 11, tint: .secondaryLabelColor,
                                   tip: "Clear all", action: #selector(confirmClear), frame: NSRect(x: bx, y: by, width: btn, height: btn)))
        bx -= (btn + bgap)
        let pinned = Settings.shared.shelfPinned
        bg.addSubview(headerButton(pinned ? "pin.fill" : "pin", symbolSize: 11,
                                   tint: pinned ? .controlAccentColor : .secondaryLabelColor,
                                   tip: pinned ? "Pinned on top — click to unpin" : "Keep on top of all windows",
                                   action: #selector(togglePin), frame: NSRect(x: bx, y: by, width: btn, height: btn)))
        bx -= (btn + bgap)
        let hiding = Settings.shared.shelfAutoHide
        bg.addSubview(headerButton("arrow.right.to.line", symbolSize: 11,
                                   tint: hiding ? .controlAccentColor : .secondaryLabelColor,
                                   tip: hiding ? "Auto-hide on — click to keep open" : "Auto-hide at screen edge",
                                   action: #selector(toggleAutoHide), frame: NSRect(x: bx, y: by, width: btn, height: btn)))

        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "No recent captures")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: pad, y: pad + 14, width: itemW, height: 16)
            bg.addSubview(empty)
        } else {
            var y = height - headerH - pad - itemH
            for (idx, url) in urls.enumerated() {
                let card = DraggableImageView(frame: NSRect(x: pad, y: y, width: itemW, height: itemH))
                card.wantsLayer = true
                card.layer?.cornerRadius = 8
                card.layer?.masksToBounds = true
                card.layer?.borderWidth = 1
                card.layer?.borderColor = NSColor.separatorColor.cgColor
                card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
                card.imageScaling = .scaleProportionallyUpOrDown
                card.image = NSImage(contentsOf: url)
                card.sourceURL = url
                card.toolTip = url.lastPathComponent
                card.onClick = { (NSApp.delegate as? AppDelegate)?.openEditor(url: url) }
                card.onHoverIn = { [weak card] in card?.layer?.borderColor = NSColor.controlAccentColor.cgColor }
                card.onHoverOut = { [weak card] in card?.layer?.borderColor = NSColor.separatorColor.cgColor }
                card.rightMenu = itemMenu(for: url)
                bg.addSubview(card)
                // Briefly highlight the just-captured item (it replaces the pop-up thumbnail).
                if idx == 0 && pendingFlash {
                    card.layer?.borderColor = NSColor.controlAccentColor.cgColor
                    card.layer?.borderWidth = 2
                    let hint = NSTextField(labelWithString: "Space to edit")
                    hint.font = .systemFont(ofSize: 10, weight: .semibold)
                    hint.textColor = .white
                    hint.alignment = .center
                    hint.drawsBackground = true
                    hint.backgroundColor = .controlAccentColor
                    hint.wantsLayer = true
                    hint.layer?.cornerRadius = 4
                    hint.layer?.masksToBounds = true
                    hint.frame = NSRect(x: card.frame.minX + 6, y: card.frame.minY + 6, width: 86, height: 17)
                    bg.addSubview(hint)
                    hintLabel = hint
                }
                y -= (itemH + gap)
            }
        }
        let flashURL = pendingFlash ? urls.first : nil
        pendingFlash = false

        p.setContentSize(frame.size)
        p.contentView = bg
        if let vf = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: revealedX(vf, frame.width), y: vf.minY + 16))
        }
        updateAutoHide()
        if let u = flashURL { startQuickEdit(u) }
    }

    // MARK: auto-hide at the screen edge

    private func updateAutoHide() {
        guard let p = panel, let vf = NSScreen.main?.visibleFrame else { return }
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
        guard let p = panel, let scr = NSScreen.main else { return }
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
        guard let p = panel, let vf = NSScreen.main?.visibleFrame else { return }
        autoHidden = false; lastInside = Date()
        var f = p.frame; f.origin.x = revealedX(vf, f.width); f.origin.y = vf.minY + 16
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18
            p.animator().setFrame(f, display: true) }   // animator().setFrameOrigin is a silent no-op
    }
    private func conceal() {
        guard let p = panel, let vf = NSScreen.main?.visibleFrame else { return }
        autoHidden = true
        var f = p.frame; f.origin.x = vf.maxX - peek; f.origin.y = vf.minY + 16
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2
            p.animator().setFrame(f, display: true) }
    }

    // A short window right after capture where Space/Return edits the newest shot.
    private func startQuickEdit(_ url: URL) {
        quickEditURL = url
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
        if let m = quickMonitor { NSEvent.removeMonitor(m) }
        quickMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, let u = self.quickEditURL else { return e }
            switch e.keyCode {
            case 49, 36: (NSApp.delegate as? AppDelegate)?.openEditor(url: u); self.endQuickEdit(); return nil
            case 53: self.endQuickEdit(); return nil
            default: return e
            }
        }
        quickTimer?.invalidate()
        quickTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in self?.endQuickEdit() }
    }
    private func endQuickEdit() {
        quickEditURL = nil
        if let m = quickMonitor { NSEvent.removeMonitor(m); quickMonitor = nil }
        quickTimer?.invalidate(); quickTimer = nil
        hintLabel?.removeFromSuperview(); hintLabel = nil
    }

    private func headerButton(_ symbol: String, symbolSize: CGFloat, tint: NSColor,
                              tip: String, action: Selector, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        b.contentTintColor = tint
        b.toolTip = tip
        b.target = self; b.action = action
        return b
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

// MARK: - ScreenCaptureKit window picker (macOS 14+)

/// Full-screen translucent overlay that highlights the window under the cursor
/// (rects from `SCShareableContent`) — the sandbox-friendly replacement for
/// `screencapture -i -w`. Click picks, Esc or an empty-area click cancels.
@available(macOS 14.0, *)
final class WindowPickerController: NSObject {
    static let shared = WindowPickerController()
    private var overlays: [OverlayWindow] = []
    private var candidates: [(window: SCWindow, rect: NSRect)] = []
    private var onPick: ((SCWindow) -> Void)?
    private var onCancel: (() -> Void)?
    private var hovered: NSRect?
    fileprivate var hoveredRect: NSRect? { hovered }

    func begin(content: SCShareableContent, onPick: @escaping (SCWindow) -> Void, onCancel: @escaping () -> Void) {
        finish()   // in case one is already up
        let ours = Bundle.main.bundleIdentifier
        candidates = content.windows.compactMap { w in
            // Real app windows only: skip our own and tiny/system frames.
            guard w.owningApplication?.bundleIdentifier != ours,
                  w.frame.width > 40, w.frame.height > 40,
                  let (display, screen) = Self.display(for: w, in: content) else { return nil }
            // SCK space is top-left origin per display; AppKit is bottom-left global.
            let y = screen.frame.maxY - (w.frame.maxY - display.frame.minY)
            let rect = NSRect(x: screen.frame.minX + w.frame.minX - display.frame.minX, y: y,
                              width: w.frame.width, height: w.frame.height)
            return (w, rect)
        }
        guard !candidates.isEmpty else { onCancel(); return }
        self.onPick = onPick
        self.onCancel = onCancel
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let overlay = OverlayWindow(screen: screen, picker: self)
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }
        // Make the overlay under the cursor key so Esc works.
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKeyAndOrderFront(nil)
    }

    /// The SCDisplay/NSScreen pair whose display contains the window's center.
    private static func display(for w: SCWindow, in content: SCShareableContent) -> (SCDisplay, NSScreen)? {
        let mid = CGPoint(x: w.frame.midX, y: w.frame.midY)
        guard let d = content.displays.first(where: { $0.frame.contains(mid) }) else { return nil }
        for s in NSScreen.screens
        where abs(d.frame.width - s.frame.width) < 2 && abs(d.frame.height - s.frame.height) < 2 {
            return (d, s)
        }
        return nil
    }

    fileprivate func hover(at point: NSPoint) {
        // Prefer the smallest window containing the cursor: the topmost one.
        let rect = candidates.filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.rect
        if rect != hovered { hovered = rect; overlays.forEach { $0.contentViewController?.view.needsDisplay = true } }
    }

    fileprivate func pick(at point: NSPoint) {
        if let c = candidates.filter({ $0.rect.contains(point) })
            .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            let window = c.window
            finish()
            onPick?(window)
        } else {
            cancel()
        }
    }

    fileprivate func cancel() {
        finish()
        onCancel?()
    }

    private func finish() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        candidates.removeAll()
        hovered = nil
        onPick = nil
        onCancel = nil
    }
}

@available(macOS 14.0, *)
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    private weak var picker: WindowPickerController?

    init(screen: NSScreen, picker: WindowPickerController) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.picker = picker
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = OverlayView(picker: picker)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { picker?.cancel() }   // Esc
    }
}

@available(macOS 14.0, *)
private final class OverlayView: NSView {
    private weak var picker: WindowPickerController?

    init(picker: WindowPickerController) {
        self.picker = picker
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        guard let picker, let rect = picker.hoveredRect else { return }
        let local = convert(rect, from: nil)   // nil = global screen coordinates
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        local.fill(using: .sourceOver)
        let path = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { picker?.hover(at: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { picker?.pick(at: NSEvent.mouseLocation) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var editors: [EditorWindowController] = []
    var hotkeyRefs: [Settings.Action: EventHotKeyRef] = [:]
    var menuItems: [Settings.Action: NSMenuItem] = [:]
    var recordingProcess: Process?
    var settingsWC: SettingsWindowController?
    var historyWC: HistoryWindowController?
    var aboutWC: AboutWindowController?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = NSImage(systemSymbolName: "scissors", accessibilityDescription: "LocalShot") {
            icon.isTemplate = true
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
        let about = menu.addItem(withTitle: "About LocalShot", action: #selector(openAbout), keyEquivalent: "")
        about.image = symbol("info.circle")
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = symbol("gearshape")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LocalShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        installHotkeyHandler()
        registerAllHotkeys()
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

    @objc func openHistoryFolder() {
        NSWorkspace.shared.open(HistoryStore.shared.folder)
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
        let hk = "   \(Settings.shared.display(a))"
        switch a {
        case .region: item.title = "Capture Region\(hk)"
        case .window: item.title = "Capture Window\(hk)"
        case .full:   item.title = "Capture Full Screen\(hk)"
        case .record: item.title = (recordingProcess != nil ? "Stop Recording" : "Record Screen") + hk
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    private func timestampName(ext: String) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Shot \(fmt.string(from: Date())).\(ext)"
    }

    private func runScreencapture(_ args: [String], delay: TimeInterval, done: @escaping (Bool) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            try? proc.run(); proc.waitUntilExit()
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async { done(ok) }
        }
    }

    // `delay` lets the menu finish closing before a non-interactive grab,
    // so a full-screen shot doesn't capture our own open menu.
    private func capture(_ mode: [String], delay: TimeInterval = 0) {
        let s = Settings.shared
        // The editor needs raster pixels, so it always captures PNG; the chosen
        // format applies when saving straight to disk.
        let fmt = s.openEditorAfterCapture ? "png" : s.captureFormat
        var flags = mode + ["-t", fmt]
        if !s.playSound { flags.append("-x") }

        if s.openEditorAfterCapture {
            let tmp = NSTemporaryDirectory() + "localshot-\(UUID().uuidString).png"
            runScreencapture(flags + [tmp], delay: delay) { [weak self] ok in
                guard let self = self, ok,
                      let data = FileManager.default.contents(atPath: tmp),
                      let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                let pixelSize = NSSize(width: cg.width, height: cg.height)
                let img = NSImage(size: pixelSize)
                img.addRepresentation(NSBitmapImageRep(cgImage: cg))
                try? FileManager.default.removeItem(atPath: tmp)
                self.handleCapturedImage(img, pixelSize: pixelSize)
            }
        } else {
            let dest = s.saveDirectory.appendingPathComponent(timestampName(ext: fmt))
            runScreencapture(flags + [dest.path], delay: delay) { ok in
                if ok, FileManager.default.fileExists(atPath: dest.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            }
        }
    }

    // Shared post-capture flow for the ScreenCaptureKit and legacy paths alike.
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

    @objc func captureRegion() { capture(["-i"]) }

    // Window & full-screen capture prefer ScreenCaptureKit (sandbox-friendly,
    // macOS 14+): no child process, works under App Sandbox. The legacy
    // `screencapture` binary remains as the pre-14 / no-permission fallback.
    @objc func captureWindow() {
        if #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() {
            Task { [weak self] in
                guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                      let self else { return }
                WindowPickerController.shared.begin(content: content,
                    onPick: { [weak self] window in
                        self?.sckCapture(filter: SCContentFilter(desktopIndependentWindow: window))
                    },
                    onCancel: {})
            }
        } else {
            capture(["-i", "-w", "-o"])   // window mode, no drop shadow
        }
    }

    @objc func captureFull() {
        if #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)   // let the menu close
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let self, let display = Self.mainDisplay(in: content) else { return }
                self.sckCapture(filter: SCContentFilter(display: display, excludingWindows: []))
            }
        } else {
            capture([], delay: 0.4)       // wait for the menu to close
        }
    }

    /// SCDisplay for the main (menu-bar) screen, matched by point size.
    @available(macOS 14.0, *)
    private static func mainDisplay(in content: SCShareableContent) -> SCDisplay? {
        guard let main = NSScreen.main ?? NSScreen.screens.first else { return content.displays.first }
        return content.displays.first {
            abs($0.frame.width - main.frame.width) < 2 && abs($0.frame.height - main.frame.height) < 2
        } ?? content.displays.first
    }

    private func sckCapture(filter: SCContentFilter) {
        Task { [weak self] in
            let cfg = SCStreamConfiguration()
            cfg.captureResolution = .best   // native pixel resolution (retina)
            cfg.showsCursor = false
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
                  let self else { return }
            await MainActor.run { self.sckPostProcess(cg) }
        }
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
        let file = Settings.shared.saveDirectory.appendingPathComponent(timestampName(ext: fmt))
        do {
            try data.write(to: file, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            // Unwritable folder (e.g. sandboxed Desktop): let the user place it.
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: fmt) ?? .png]
            panel.nameFieldStringValue = timestampName(ext: fmt)
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    // MARK: screen recording (screencapture -v; SIGINT finalizes the movie)

    @objc func toggleRecording() {
        if recordingProcess != nil { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Recording \(fmt.string(from: Date())).mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-v", "-x", url.path]
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.recordingProcess = nil
                self?.updateRecordUI()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        do { try proc.run() } catch { return }
        recordingProcess = proc
        updateRecordUI()
    }

    private func stopRecording() {
        recordingProcess?.interrupt()   // SIGINT; the file is finalized by the termination handler
    }

    private func updateRecordUI() {
        let on = recordingProcess != nil
        updateMenuTitle(for: .record)
        menuItems[.record]?.image = symbol(on ? "stop.circle.fill" : "record.circle")
        if let icon = NSImage(systemSymbolName: on ? "stop.circle.fill" : "scissors",
                              accessibilityDescription: "LocalShot") {
            icon.isTemplate = !on
            statusItem.button?.image = icon
            statusItem.button?.contentTintColor = on ? .systemRed : nil
        }
    }

    // Global hotkeys: the configurable capture key (id 1) and ⌃⌘R record (id 2).
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

    func registerAllHotkeys() {
        for a in Settings.Action.allCases { registerHotkey(for: a) }
    }

    // (Re)registers one action's global hotkey from the current settings.
    func registerHotkey(for a: Settings.Action) {
        if let r = hotkeyRefs[a] { UnregisterEventHotKey(r); hotkeyRefs[a] = nil }
        let mods = NSEvent.ModifierFlags(rawValue: Settings.shared.modifiers(a))
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(Settings.shared.keyCode(a)), carbonFlags(from: mods),
                            EventHotKeyID(signature: hotkeySignature, id: UInt32(a.rawValue)),
                            GetApplicationEventTarget(), 0, &ref)
        hotkeyRefs[a] = ref
        updateMenuTitle(for: a)
    }
}

// Entry point: see main.swift (top-level bootstrap, shared by build.sh and Xcode).
