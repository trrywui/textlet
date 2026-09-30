#if ROW_RENDERER
import AppKit
import QuartzCore

// Retain NSTextView's input, layout, undo, accessibility and finder. Only its
// full-surface rendering is replaced with visible line images and vector selection.
class RowRenderingTextView: NSTextView, NSLayoutManagerDelegate {
    private struct Tile {
        let layer: CALayer
        let glyphs: NSRange
        let frame: NSRect
        let signature: NSAttributedString
        let scale: CGFloat
        let bytes: Int
        let image: CGImage?
    }
    private var tiles: [Int: Tile] = [:]
    private let selectionLayer = CAShapeLayer()
    private var rendering = false
    private var scheduled = false
    private var observers: [NSObjectProtocol] = []
    private var installed = false
    private(set) var renderedBitmapBytes = 0
    private(set) var rowRasterizations = 0
    var rowDiagnostics: [String] { tiles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.signature.attributes(at: 0, effectiveRange: nil)) image=\($0.value.image?.width ?? 0)x\($0.value.image?.height ?? 0)" } }
    private(set) var renderedGlyphRange = NSRange(location: 0, length: 0)
    var renderedTileCount: Int { tiles.count }
    var renderedLineImages: [CGImage] { tiles.sorted { $0.key < $1.key }.compactMap { $0.value.image } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = backgroundColor.cgColor
        renderRows()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutManager?.delegate = self
        installObservers()
        invalidateRows()
    }
    // TextKit normally omits temporary colors when drawing into a bitmap (printing).
    // Our bitmaps are screen tiles, so syntax colors and marked-text attributes apply.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        attrs
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); invalidateRows() }
    override func setFrameSize(_ size: NSSize) {
        let changed = size != frame.size
        super.setFrameSize(size)
        if changed { invalidateRows() }
    }
    override func didChangeText() { super.didChangeText(); invalidateRows() }
    override func setNeedsDisplay(_ rect: NSRect) {
        super.setNeedsDisplay(rect)
        if !rendering { invalidateRows() }
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        queueRender()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func installObservers() {
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        let center = NotificationCenter.default
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.queueRender() })
        }
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.queueRender() })
            }
        }
    }
    func invalidateRows() {
        queueRender()
    }
    private func queueRender() {
        guard !scheduled, !rendering else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.scheduled = false
            self.renderRows()
        }
    }
    func renderRows() {
        guard !rendering, let root = layer, let layout = layoutManager, let container = textContainer,
              let storage = textStorage, window != nil else { return }
        rendering = true
        defer { rendering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if !installed {
            root.insertSublayer(selectionLayer, at: 0)
            installed = true
        }
        root.backgroundColor = backgroundColor.cgColor
        let origin = textContainerOrigin
        let viewPort = visibleRect
        var visible = viewPort.offsetBy(dx: -origin.x, dy: -origin.y)
        visible = visible.intersection(NSRect(origin: .zero, size: container.size))
        guard !visible.isNull, visible.height > 0 else {
            clearRows(); selectionLayer.path = nil; return
        }
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        renderedGlyphRange = glyphs
        let scale = window?.backingScaleFactor ?? 2
        var keep = Set<Int>(), glyph = glyphs.location
        let limit = min(NSMaxRange(glyphs), layout.firstUnlaidGlyphIndex())
        while glyph < limit {
            var range = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range, withoutAdditionalLayout: true)
            guard range.length > 0, NSMaxRange(range) > glyph else { break }
            let characters = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            // Newline control glyphs have a full-fragment bounding box; they carry no ink.
            var end = NSMaxRange(characters)
            let string = storage.mutableString
            while end > characters.location {
                let c = string.character(at: end - 1)
                if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 { end -= 1 } else { break }
            }
            let inkCharacters = NSRange(location: characters.location, length: end - characters.location)
            let inkGlyphs = layout.glyphRange(forCharacterRange: inkCharacters, actualCharacterRange: nil)
            let signature = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: characters))
            var attributeIndex = characters.location
            while attributeIndex < NSMaxRange(characters) {
                var effective = NSRange()
                let attributes = layout.temporaryAttributes(atCharacterIndex: attributeIndex, effectiveRange: &effective)
                let part = NSIntersectionRange(effective, characters)
                if part.length == 0 { break }
                signature.addAttributes(attributes, range: NSRange(location: part.location - characters.location, length: part.length))
                attributeIndex = NSMaxRange(part)
            }
            // Include overhanging glyphs/underlines while clipping allocation to the viewport.
            var rect = inkGlyphs.length > 0 ? layout.boundingRect(forGlyphRange: inkGlyphs, in: container) : NSRect(x: line.minX, y: line.minY, width: 1, height: line.height)
            rect = rect.union(NSRect(x: rect.minX, y: line.minY, width: max(1, rect.width), height: line.height))
            rect = rect.insetBy(dx: -3, dy: -2).offsetBy(dx: origin.x, dy: origin.y)
            rect = rect.intersection(viewPort.insetBy(dx: -3, dy: -2))
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                rect = NSRect(x: floor(rect.minX * scale) / scale, y: floor(rect.minY * scale) / scale,
                              width: ceil(rect.maxX * scale) / scale - floor(rect.minX * scale) / scale,
                              height: ceil(rect.maxY * scale) / scale - floor(rect.minY * scale) / scale)
                keep.insert(range.location)
                let previous = tiles[range.location]
                if previous?.glyphs != range || previous?.frame != rect || previous?.signature.isEqual(to: signature) != true || previous?.scale != scale {
                    let w = max(1, Int(ceil(rect.width * scale))), h = max(1, Int(ceil(rect.height * scale)))
                    if let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale)
                        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
                        let offset = NSPoint(x: origin.x - rect.minX, y: origin.y - rect.minY)
                        layout.drawBackground(forGlyphRange: inkGlyphs, at: offset)
                        layout.drawGlyphs(forGlyphRange: inkGlyphs, at: offset)
                        NSGraphicsContext.restoreGraphicsState()
                        let tile = previous?.layer ?? CALayer()
                        tile.contentsScale = scale; tile.contentsGravity = .resize
                        let image = context.makeImage()
                        rowRasterizations += 1
                        tile.frame = rect; tile.contents = image
                        if previous == nil { root.insertSublayer(tile, above: selectionLayer) }
                        tiles[range.location] = Tile(layer: tile, glyphs: range, frame: rect, signature: signature, scale: scale, bytes: context.bytesPerRow * h, image: image)
                    }
                }
            }
            glyph = NSMaxRange(range)
        }
        for key in Array(tiles.keys) where !keep.contains(key) { tiles.removeValue(forKey: key)?.layer.removeFromSuperlayer() }
        renderedBitmapBytes = tiles.values.reduce(0) { $0 + $1.bytes }
        let path = CGMutablePath()
        for value in selectedRanges {
            let selected = NSIntersectionRange(value.rangeValue, NSRange(location: 0, length: storage.length))
            guard selected.length > 0 else { continue }
            let selectedGlyphs = layout.glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
            let shown = NSIntersectionRange(selectedGlyphs, glyphs)
            guard shown.length > 0 else { continue }
            layout.enumerateEnclosingRects(forGlyphRange: shown, withinSelectedGlyphRange: selectedGlyphs, in: container) { rect, _ in
                let rect = rect.offsetBy(dx: origin.x, dy: origin.y).intersection(viewPort)
                if !rect.isNull { path.addRect(rect) }
            }
        }
        selectionLayer.path = path
        selectionLayer.fillColor = (window?.isKeyWindow == true ? Theme.selection : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
    }
    private func clearRows() {
        tiles.values.forEach { $0.layer.removeFromSuperlayer() }; tiles.removeAll()
        renderedBitmapBytes = 0; renderedGlyphRange = NSRange(location: 0, length: 0)
    }
}
#endif
