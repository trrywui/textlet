#if ROW_RENDERER
import AppKit
import QuartzCore

// Retain NSTextView's input, layout, undo, accessibility and finder. Only its
// full-surface rendering is replaced with visible line images and vector selection.
class RowRenderingTextView: NSTextView, NSLayoutManagerDelegate {
    private struct TemporaryRun: Equatable {
        let range: NSRange
        let attributes: NSDictionary
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.range == rhs.range && lhs.attributes.isEqual(rhs.attributes)
        }
    }
    private struct Tile {
        let layer: CALayer
        var characters: NSRange
        var frame: NSRect
        var line: NSRect
        let signature: NSAttributedString
        let temporaryRuns: [TemporaryRun]
        let scale: CGFloat
        let bytes: Int
        let image: CGImage?
        var lastUsed: Int
    }
    private var tiles: [Int: Tile] = [:]
    private let selectionLayer = CAShapeLayer()
    private var rendering = false
    private var scheduled = false
    private var observers: [NSObjectProtocol] = []
    private var installed = false
    private weak var observedStorage: NSTextStorage?
    private var storageObserver: NSObjectProtocol?
    private var cacheWidth: CGFloat = -1
    private var visibleKeys = Set<Int>()
    private var generation = 0
    // Visible rows are the minimum working set; only offscreen rows are evicted.
    let rowCacheBudgetBytes = (Int(ProcessInfo.processInfo.environment["TEXTLET_ROW_CACHE_MIB"] ?? "32") ?? 32).clamped(to: 0...128) * 1024 * 1024
    private(set) var rowCacheHits = 0
    private(set) var rowRenderPasses = 0
    private let nativeTouchBarUpdates = ProcessInfo.processInfo.environment["TEXTLET_NATIVE_TOUCHBAR_UPDATES"] == "1"
    private(set) var skippedTouchBarFormatUpdates = 0
    private lazy var pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    private(set) var renderedBitmapBytes = 0
    private(set) var rowRasterizations = 0
    var rowDiagnostics: [String] { tiles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.signature.attributes(at: 0, effectiveRange: nil)) image=\($0.value.image?.width ?? 0)x\($0.value.image?.height ?? 0)" } }
    private(set) var renderedGlyphRange = NSRange(location: 0, length: 0)
    var renderedTileCount: Int { visibleKeys.count }
    var cachedTileCount: Int { tiles.count }
    var renderedLineImages: [CGImage] { visibleKeys.sorted().compactMap { tiles[$0]?.image } }
    var renderedLineFrames: [NSRect] { visibleKeys.sorted().compactMap { tiles[$0]?.frame } }

    override var wantsUpdateLayer: Bool { true }
    // This public AppKit hook updates rich-text formatting controls only. Plain
    // text has none; candidate/character-picker updates use separate AppKit hooks.
    override func updateTextTouchBarItems() {
        if isRichText || nativeTouchBarUpdates { super.updateTextTouchBarItems() }
        else { skippedTouchBarFormatUpdates += 1 }
    }
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
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
        if installed { pressure.cancel() }
    }

    // Edits shift character offsets, but leave later paragraphs' pixels unchanged.
    // Invalidate the whole affected paragraph, including wrap/shaping neighbours.
    private func storageEdited(_ storage: NSTextStorage) {
        let edited = storage.editedRange
        guard edited.location != NSNotFound else { discardRowCache(); return }
        let delta = storage.editedMask.contains(.editedCharacters) ? storage.changeInLength : 0
        let start = min(edited.location, storage.length)
        let length = min(edited.length, storage.length - start)
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: length))
        let oldEnd = max(paragraph.location, NSMaxRange(paragraph) - delta)
        var shifted: [Int: Tile] = [:]
        for var tile in tiles.values {
            if NSMaxRange(tile.characters) <= paragraph.location {
                shifted[tile.characters.location] = tile
            } else if tile.characters.location >= oldEnd {
                tile.characters.location += delta
                shifted[tile.characters.location] = tile
            } else { tile.layer.removeFromSuperlayer() }
        }
        tiles = shifted
        visibleKeys.removeAll()
        queueRender()
    }

    func discardRowCache() { clearRows(); queueRender() }

    private func trimCache(to budget: Int) {
        var bytes = tiles.values.reduce(0) { $0 + $1.bytes }
        for (key, tile) in tiles.filter({ !visibleKeys.contains($0.key) }).sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where bytes > budget {
            tile.layer.removeFromSuperlayer(); tiles.removeValue(forKey: key); bytes -= tile.bytes
        }
        renderedBitmapBytes = bytes
    }

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
            guard let self, self.scheduled else { return }; self.scheduled = false
            self.renderRows()
        }
    }
    func renderRows() {
        guard !rendering, let root = layer, let layout = layoutManager, let container = textContainer,
              let storage = textStorage, window != nil else { return }
        rendering = true
        scheduled = false
        generation += 1; rowRenderPasses += 1
        defer { rendering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if !installed {
            root.insertSublayer(selectionLayer, at: 0)
            installed = true
            pressure.setEventHandler { [weak self] in self?.trimCache(to: 0) }
            pressure.resume()
        }
        if observedStorage !== storage {
            clearRows()
            if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
            observedStorage = storage
            storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { [weak self, weak storage] _ in
                if let storage { self?.storageEdited(storage) }
            }
        }
        if cacheWidth != container.size.width { clearRows(); cacheWidth = container.size.width }
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
            var temporaryRuns: [TemporaryRun] = []
            var attributeIndex = characters.location
            while attributeIndex < NSMaxRange(characters) {
                var effective = NSRange()
                let attributes = layout.temporaryAttributes(atCharacterIndex: attributeIndex, effectiveRange: &effective)
                let part = NSIntersectionRange(effective, characters)
                if part.length == 0 { break }
                if !attributes.isEmpty {
                    temporaryRuns.append(TemporaryRun(range: NSRange(location: part.location - characters.location, length: part.length), attributes: attributes as NSDictionary))
                }
                attributeIndex = NSMaxRange(part)
            }
            let key = characters.location
            let previous = tiles[key]
            let anchor = line.offsetBy(dx: origin.x, dy: origin.y)
            let dx = anchor.minX - (previous?.line.minX ?? anchor.minX)
            let dy = anchor.minY - (previous?.line.minY ?? anchor.minY)
            // Keep the glyphs' pixel phase when reusing a moved image.
            let aligned = abs(dx * scale - (dx * scale).rounded()) < 0.0001 && abs(dy * scale - (dy * scale).rounded()) < 0.0001
            if var old = previous, old.characters == characters, old.line.size == anchor.size,
               old.scale == scale, aligned, old.temporaryRuns == temporaryRuns {
                old.frame = old.frame.offsetBy(dx: dx, dy: dy); old.line = anchor
                old.layer.frame = old.frame; old.lastUsed = generation
                if old.layer.superlayer == nil { root.insertSublayer(old.layer, above: selectionLayer) }
                tiles[key] = old; keep.insert(key); rowCacheHits += 1
                glyph = NSMaxRange(range); continue
            }
            // Storage notifications invalidate changed paragraphs; unchanged rows
            // need only check temporary (syntax/IME) attributes, not copy their text.
            let signature = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: characters))
            for run in temporaryRuns {
                signature.addAttributes(run.attributes as! [NSAttributedString.Key: Any], range: run.range)
            }
            // Include overhanging glyphs/underlines, bounded by the view's width.
            var rect = inkGlyphs.length > 0 ? layout.boundingRect(forGlyphRange: inkGlyphs, in: container) : NSRect(x: line.minX, y: line.minY, width: 1, height: line.height)
            rect = rect.union(NSRect(x: rect.minX, y: line.minY, width: max(1, rect.width), height: line.height))
            rect = rect.insetBy(dx: -3, dy: -2).offsetBy(dx: origin.x, dy: origin.y)
            // Keep full row height: scrolling must not change edge-row images.
            rect = rect.intersection(NSRect(x: bounds.minX - 3, y: rect.minY, width: bounds.width + 6, height: rect.height))
            if !rect.isNull, rect.width > 0, rect.height > 0 {
                rect = NSRect(x: floor(rect.minX * scale) / scale, y: floor(rect.minY * scale) / scale,
                              width: ceil(rect.maxX * scale) / scale - floor(rect.minX * scale) / scale,
                              height: ceil(rect.maxY * scale) / scale - floor(rect.minY * scale) / scale)
                keep.insert(key)
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
                    if tile.superlayer == nil { root.insertSublayer(tile, above: selectionLayer) }
                    tiles[key] = Tile(layer: tile, characters: characters, frame: rect, line: anchor, signature: signature, temporaryRuns: temporaryRuns, scale: scale, bytes: context.bytesPerRow * h, image: image, lastUsed: generation)
                }
            }
            glyph = NSMaxRange(range)
        }
        for key in tiles.keys where !keep.contains(key) { tiles[key]?.layer.removeFromSuperlayer() }
        visibleKeys = keep
        trimCache(to: rowCacheBudgetBytes)
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
        visibleKeys.removeAll()
        renderedBitmapBytes = 0; renderedGlyphRange = NSRange(location: 0, length: 0)
    }
}
private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
#endif
