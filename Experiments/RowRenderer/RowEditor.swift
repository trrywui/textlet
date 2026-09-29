import AppKit
import CoreText
import QuartzCore

// Experimental only: bounded document, full re-layout on edit, visible-row image cache.
// Does not read/write Textlet sessions and does not replace its production editor.
final class RowEditor: NSView, NSTextInputClient {
    struct Row { let range: NSRange; let line: CTLine; let width: CGFloat }
    struct Composition { let oldText: String; let selection: NSRange; let start: Int }
    let text = NSMutableString(string: "")
    let history = UndoManager()
    var selection = NSRange(location: 0, length: 0)
    var marked = NSRange(location: NSNotFound, length: 0)
    var composition: Composition?
    var rows: [Row] = []
    var rowLayers: [Int: CALayer] = [:]
    var rowKeys: [Int: String] = [:]
    let selectionLayer = CAShapeLayer()
    let markedLayer = CAShapeLayer()
    let caret = CALayer()
    let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let rowHeight: CGFloat = 23
    let inset: CGFloat = 20
    let limit = 128 * 1024
    var scrollY: CGFloat = 0
    var anchor = 0
    var layoutWidth: CGFloat = -1
    var renderedScale: CGFloat = 0
    var blinkTimer: Timer?
    var onChange: (() -> Void)?
    private(set) var bitmapBytes = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var undoManager: UndoManager? { history }
    override func updateLayer() { layer?.backgroundColor = canvas.cgColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = canvas.cgColor
        layer?.masksToBounds = true
        selectionLayer.fillColor = NSColor(srgbRed: 0.29, green: 0.30, blue: 0.24, alpha: 1).cgColor
        markedLayer.fillColor = NSColor.systemYellow.cgColor
        caret.backgroundColor = NSColor.systemYellow.cgColor
        for item in [selectionLayer, markedLayer, caret] { layer?.addSublayer(item) }
        history.levelsOfUndo = 100
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("实验编辑区，不自动保存")
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { blinkTimer?.invalidate() }
    override func becomeFirstResponder() -> Bool {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.caret.isHidden = self.selection.length != 0 || !(self.window?.isKeyWindow ?? false) || !self.caret.isHidden
            CATransaction.commit()
        }
        render()
        return true
    }
    override func resignFirstResponder() -> Bool {
        inputContext?.discardMarkedText(); unmarkText()
        blinkTimer?.invalidate(); blinkTimer = nil
        caret.isHidden = true
        return true
    }
    override func viewDidChangeBackingProperties() { renderedScale = 0; render() }
    override func layout() {
        super.layout()
        if bounds.width != layoutWidth { rebuild() } else { render() }
    }
    func setText(_ string: String) {
        guard string.utf16.count <= limit else { NSSound.beep(); return }
        text.setString(string); selection = NSRange(location: 0, length: 0)
        marked = NSRange(location: NSNotFound, length: 0); composition = nil
        scrollY = 0; history.removeAllActions(); rebuild()
    }
    func clamp(_ range: NSRange) -> NSRange {
        let start = min(max(0, range.location == NSNotFound ? selection.location : range.location), text.length)
        return NSRange(location: start, length: min(max(0, range.length), text.length - start))
    }
    func replace(_ range: NSRange, with string: String, register: Bool = true, restore: NSRange? = nil) {
        let range = clamp(range), length = string.utf16.count
        guard text.length - range.length + length <= limit else { NSSound.beep(); return }
        let old = text.substring(with: range), previousSelection = selection
        if register {
            history.registerUndo(withTarget: self) { target in
                target.replace(NSRange(location: range.location, length: length), with: old, restore: previousSelection)
            }
        }
        text.replaceCharacters(in: range, with: string)
        selection = clamp(restore ?? NSRange(location: range.location + length, length: 0))
        rebuild(); revealCaret(); onChange?()
    }
    func rebuild() {
        layoutWidth = bounds.width
        let value = NSAttributedString(string: text as String, attributes: [.font: font, .foregroundColor: ink])
        let typesetter = CTTypesetterCreateWithAttributedString(value)
        var result: [Row] = [], start = 0
        while start < text.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(20, bounds.width - 2 * inset))))
            let range = NSRange(location: start, length: min(count, text.length - start))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: range.length))
            result.append(Row(range: range, line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
            start += range.length
        }
        if text.length == 0 || CharacterSet.newlines.contains(UnicodeScalar(text.character(at: text.length - 1)) ?? " ") {
            result.append(Row(range: NSRange(location: text.length, length: 0), line: CTLineCreateWithAttributedString(NSAttributedString(string: "")), width: 0))
        }
        rows = result
        scrollY = min(scrollY, maxScroll)
        render()
    }
    var maxScroll: CGFloat { max(0, CGFloat(rows.count) * rowHeight + 2 * inset - bounds.height) }
    func rowIndex(at offset: Int) -> Int {
        for i in rows.indices.reversed() where offset >= rows[i].range.location { return i }
        return 0
    }
    func caretRect(at offset: Int) -> NSRect {
        guard !rows.isEmpty else { return .zero }
        let i = rowIndex(at: offset)
        let x = CTLineGetOffsetForStringIndex(rows[i].line, offset, nil)
        return NSRect(x: inset + x, y: inset + CGFloat(i) * rowHeight - scrollY, width: 1, height: rowHeight)
    }
    func revealCaret() {
        let rect = caretRect(at: selection.location)
        if rect.minY < inset { scrollY = max(0, scrollY + rect.minY - inset) }
        if rect.maxY > bounds.height - inset { scrollY = min(maxScroll, scrollY + rect.maxY - bounds.height + inset) }
        render(); inputContext?.invalidateCharacterCoordinates()
    }
    func render() {
        guard let root = layer, !rows.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        if renderedScale != scale { rowKeys.removeAll(); renderedScale = scale }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let first = max(0, Int(floor((scrollY - inset) / rowHeight)))
        let last = min(rows.count, Int(ceil((scrollY + bounds.height - inset) / rowHeight)))
        let visible = Set(first..<max(first, last))
        for i in Array(rowLayers.keys) where !visible.contains(i) {
            rowLayers.removeValue(forKey: i)?.removeFromSuperlayer(); rowKeys.removeValue(forKey: i)
        }
        bitmapBytes = 0
        for i in visible.sorted() {
            let row = rows[i]
            let width = max(1, min(bounds.width - inset, ceil(row.width) + 6))
            let w = max(1, Int(ceil(width * scale))), h = Int(ceil(rowHeight * scale))
            let tile: CALayer
            if let old = rowLayers[i] { tile = old } else {
                tile = CALayer(); tile.contentsGravity = .resize
                root.insertSublayer(tile, below: markedLayer); rowLayers[i] = tile
            }
            tile.frame = CGRect(x: inset - 2, y: inset + CGFloat(i) * rowHeight - scrollY, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
            tile.contentsScale = scale
            let key = text.substring(with: row.range) + "|\(w)|\(scale)"
            if rowKeys[i] != key {
                if let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.scaleBy(x: scale, y: scale)
                    context.textPosition = CGPoint(x: 2, y: 5)
                    CTLineDraw(row.line, context)
                    tile.contents = context.makeImage()
                }
                rowKeys[i] = key
            }
            bitmapBytes += w * h * 4
        }
        func path(for range: NSRange, underline: Bool) -> CGPath {
            let p = CGMutablePath()
            guard range.location != NSNotFound, range.length > 0 else { return p }
            for i in visible.sorted() {
                let part = NSIntersectionRange(range, rows[i].range)
                guard part.length > 0 else { continue }
                let x1 = CTLineGetOffsetForStringIndex(rows[i].line, part.location, nil)
                let x2 = CTLineGetOffsetForStringIndex(rows[i].line, NSMaxRange(part), nil)
                p.addRect(CGRect(x: inset + min(x1, x2), y: inset + CGFloat(i) * rowHeight - scrollY + (underline ? rowHeight - 2 : 0),
                                width: max(3, abs(x2 - x1)), height: underline ? 1 : rowHeight))
            }
            return p
        }
        selectionLayer.path = path(for: selection, underline: false)
        markedLayer.path = path(for: marked, underline: true)
        caret.frame = caretRect(at: selection.location)
        caret.isHidden = selection.length > 0 || window?.firstResponder !== self
    }
    func index(at point: NSPoint) -> Int {
        let i = max(0, min(rows.count - 1, Int(floor((point.y + scrollY - inset) / rowHeight))))
        let index = CTLineGetStringIndexForPosition(rows[i].line, CGPoint(x: point.x - inset, y: 0))
        let raw = index == kCFNotFound ? NSMaxRange(rows[i].range) : min(max(index, rows[i].range.location), NSMaxRange(rows[i].range))
        if raw >= text.length { return text.length }
        return text.rangeOfComposedCharacterSequence(at: raw).location
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); inputContext?.discardMarkedText(); unmarkText()
        let i = index(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) {
            selection = NSRange(location: min(anchor, i), length: abs(anchor - i))
        } else { anchor = i; selection = NSRange(location: i, length: 0) }
        if event.clickCount == 2, i < text.length { selection = text.rangeOfComposedCharacterSequence(at: i) }
        render()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 0 { scrollY = max(0, scrollY - rowHeight) }
        if point.y > bounds.height { scrollY = min(maxScroll, scrollY + rowHeight) }
        let i = index(at: point)
        selection = NSRange(location: min(anchor, i), length: abs(anchor - i)); render()
    }
    override func scrollWheel(with event: NSEvent) {
        scrollY = min(maxScroll, max(0, scrollY - event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : rowHeight)))
        render(); inputContext?.invalidateCharacterCoordinates()
    }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        let originalCommand = NSStringFromSelector(selector)
        let extending = originalCommand.contains("AndModifySelection:")
        let command = originalCommand.replacingOccurrences(of: "AndModifySelection:", with: ":")
        if hasMarkedText(), command != "cancelOperation:" { unmarkText() }
        switch command {
        case "insertNewline:": insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "insertTab:": insertText("\t", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "deleteBackward:":
            if selection.length > 0 { insertText("", replacementRange: selection) }
            else if selection.location > 0 { insertText("", replacementRange: text.rangeOfComposedCharacterSequence(at: selection.location - 1)) }
        case "deleteForward:":
            if selection.length > 0 { insertText("", replacementRange: selection) }
            else if selection.location < text.length { insertText("", replacementRange: text.rangeOfComposedCharacterSequence(at: selection.location)) }
        case "moveLeft:", "moveRight:", "moveUp:", "moveDown:", "moveToBeginningOfLine:", "moveToEndOfLine:":
            if extending && selection.length == 0 { anchor = selection.location }
            var i = extending && anchor == selection.location ? NSMaxRange(selection) : selection.location
            if command == "moveLeft:" { i = !extending && selection.length > 0 ? selection.location : (i > 0 ? text.rangeOfComposedCharacterSequence(at: i - 1).location : 0) }
            if command == "moveRight:" { i = !extending && selection.length > 0 ? NSMaxRange(selection) : (i < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: i)) : i) }
            if command == "moveUp:" || command == "moveDown:" {
                var point = caretRect(at: i).origin; point.y += command == "moveUp:" ? -rowHeight : rowHeight
                i = index(at: point)
            }
            if command == "moveToBeginningOfLine:" { i = rows[rowIndex(at: i)].range.location }
            if command == "moveToEndOfLine:" { i = NSMaxRange(rows[rowIndex(at: i)].range); if i > 0, text.character(at: i - 1) == 10 { i -= 1 } }
            if extending { selection = NSRange(location: min(anchor, i), length: abs(anchor - i)) }
            else { selection = NSRange(location: i, length: 0); anchor = i }
            revealCaret()
        case "cancelOperation:": inputContext?.discardMarkedText(); unmarkText()
        default: NSSound.beep()
        }
    }
    func hasMarkedText() -> Bool { marked.location != NSNotFound }
    func markedRange() -> NSRange { marked }
    func selectedRange() -> NSRange { selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func plain(_ value: Any) -> String { (value as? NSAttributedString)?.string ?? (value as? String ?? "") }
    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let target = replacementRange.location == NSNotFound ? (hasMarkedText() ? marked : selection) : clamp(replacementRange)
        let value = plain(value)
        guard text.length - target.length + value.utf16.count <= limit else { NSSound.beep(); return }
        if composition == nil { composition = Composition(oldText: text.substring(with: target), selection: selection, start: target.location) }
        replace(target, with: value, register: false)
        marked = NSRange(location: target.location, length: value.utf16.count)
        let offset = min(selectedRange.location, marked.length)
        selection = NSRange(location: marked.location + offset, length: min(selectedRange.length, marked.length - offset))
        revealCaret()
    }
    func unmarkText() {
        if let saved = composition {
            let length = marked.location == NSNotFound ? 0 : marked.length
            history.registerUndo(withTarget: self) { target in
                target.replace(NSRange(location: saved.start, length: length), with: saved.oldText, restore: saved.selection)
            }
        }
        composition = nil; marked = NSRange(location: NSNotFound, length: 0); render()
    }
    func insertText(_ value: Any, replacementRange: NSRange) {
        let value = plain(value)
        let range = replacementRange.location == NSNotFound ? (hasMarkedText() ? marked : selection) : clamp(replacementRange)
        guard text.length - range.length + value.utf16.count <= limit else { NSSound.beep(); return }
        if hasMarkedText() {
            replace(range, with: value, register: false)
            marked = NSRange(location: range.location, length: value.utf16.count); unmarkText()
        } else { replace(range, with: value) }
        anchor = selection.location
    }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= text.length else { return nil }
        let r = clamp(range); actualRange?.pointee = r
        return NSAttributedString(string: text.substring(with: r), attributes: [.font: font])
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = clamp(range); actualRange?.pointee = NSRange(location: r.location, length: 0)
        return window?.convertToScreen(convert(caretRect(at: r.location), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        return index(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }
    @objc func copy(_ sender: Any?) {
        guard selection.length > 0, !hasMarkedText() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.substring(with: selection), forType: .string)
    }
    @objc func cut(_ sender: Any?) { guard !hasMarkedText() else { return }; copy(sender); insertText("", replacementRange: selection) }
    @objc func paste(_ sender: Any?) { if let s = NSPasteboard.general.string(forType: .string) { insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    @objc override func selectAll(_ sender: Any?) { unmarkText(); selection = NSRange(location: 0, length: text.length); render() }
    @objc func undo(_ sender: Any?) { unmarkText(); history.undo(); render() }
    @objc func redo(_ sender: Any?) { unmarkText(); history.redo(); render() }
}
