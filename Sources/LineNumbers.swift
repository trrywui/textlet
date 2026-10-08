import AppKit

// Sparse checkpoints keep even newline-heavy notes from allocating an Int per line.
final class LineCounter {
    var unicodeSeparators = true
    struct Checkpoint { let offset: Int; let line: Int; let previousCR: Bool }
    private var checkpoints = [Checkpoint(offset: 0, line: 1, previousCR: false)]
    private var lastLookup = Checkpoint(offset: 0, line: 1, previousCR: false)
    private var characters = [unichar](repeating: 0, count: 4096)
    func invalidate(from offset: Int = 0) {
        while checkpoints.count > 1 && checkpoints.last!.offset >= max(1, offset) { checkpoints.removeLast() }
        if lastLookup.offset >= offset { lastLookup = checkpoints.last! }
    }
    func line(at offset: Int, in text: NSString) -> Int {
        let end = min(max(0, offset), text.length)
        var low = 0, high = checkpoints.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if checkpoints[mid].offset <= end { low = mid } else { high = mid }
        }
        let point = lastLookup.offset <= end && lastLookup.offset > checkpoints[low].offset ? lastLookup : checkpoints[low]
        var count = point.line, cr = point.previousCR, i = point.offset
        while i < end {
            let length = min(characters.count, end - i)
            text.getCharacters(&characters, range: NSRange(location: i, length: length))
            for j in 0..<length {
                let c = characters[j]
                if c == 13 || (c == 10 && !cr) || (unicodeSeparators && (c == 0x2028 || c == 0x2029)) { count += 1 }
                cr = c == 13; i += 1
                if i % 4096 == 0 && i > checkpoints.last!.offset {
                    checkpoints.append(Checkpoint(offset: i, line: count, previousCR: cr))
                }
            }
        }
        lastLookup = Checkpoint(offset: end, line: count, previousCR: cr)
        return count
    }
    func isLineStart(_ offset: Int, in text: NSString) -> Bool {
        guard offset > 0 else { return true }
        let previous = text.character(at: offset - 1)
        return previous == 10 || (unicodeSeparators && (previous == 0x2028 || previous == 0x2029))
            || (previous == 13 && (offset == text.length || text.character(at: offset) != 10))
    }
}

final class LineNumberRuler: NSView {
    weak var editor: NSTextView?
    let counter = LineCounter()
    var firstLine = 1
    var startsMidLine = false
    let ruleThickness: CGFloat = 64
    // Reuse label measurements without retaining a bitmap for each document line.
    private struct Label { let text: NSString; let size: NSSize; var lastUsed: UInt64 }
    private var labels: [String: Label] = [:]
    private var labelGeneration: UInt64 = 0
    private let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: Theme.comment
    ]
    var usesLabelCache = ProcessInfo.processInfo.environment["TEXTLET_NATIVE_LINE_NUMBERS"] != "1"
    var cachedLabelCount: Int { labels.count }
    private(set) var labelCacheHits = 0
    private(set) var labelMeasurements = 0
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); labels.removeAll(); needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); labels.removeAll() }

    private func drawLabel(_ string: String, y: CGFloat) {
        labelGeneration &+= 1
        let label: Label
        if usesLabelCache, var cached = labels[string] {
            cached.lastUsed = labelGeneration; labels[string] = cached
            labelCacheHits += 1; label = cached
        } else {
            let text = string as NSString
            label = Label(text: text, size: text.size(withAttributes: labelAttributes), lastUsed: labelGeneration)
            labelMeasurements += 1
            if usesLabelCache {
                if labels.count >= 128 { labels.removeValue(forKey: labels.min { $0.value.lastUsed < $1.value.lastUsed }!.key) }
                labels[string] = label
            }
        }
        label.text.draw(at: NSPoint(x: ruleThickness - label.size.width - 9, y: y), withAttributes: labelAttributes)
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
    }
    required init(coder: NSCoder) { fatalError() }
    func reset(firstLine: Int = 1, continuation: Bool = false, log: Bool = false) {
        self.firstLine = firstLine; startsMidLine = continuation
        counter.unicodeSeparators = !log
        counter.invalidate(); needsDisplay = true
    }
    var textDrawingRect: NSRect {
        guard let scroll = editor?.enclosingScrollView, scroll.isFindBarVisible,
              let bar = scroll.findBarView else { return bounds }
        let barRect = convert(bar.bounds, from: bar)
        let top = min(bounds.maxY, max(bounds.minY, barRect.maxY))
        return NSRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
    }
    override func draw(_ rect: NSRect) {
        // On macOS 14 dirtyRect can extend beyond bounds. Never paint over siblings.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        Theme.canvas.setFill(); bounds.fill()
        NSBezierPath(rect: textDrawingRect).addClip()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        // Read the native UTF-16 backing string. Bridging a Swift String back to
        // NSString makes random UTF-16 character access costly for Unicode notes.
        guard let text = editor.textStorage?.mutableString else { return }
        let origin = editor.textContainerOrigin
        var visible = editor.visibleRect
        visible.origin.x -= origin.x; visible.origin.y -= origin.y
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        func drawNumber(_ number: Int, y: CGFloat, continuation: Bool = false) {
            let point = convert(NSPoint(x: 0, y: y + origin.y), from: editor)
            drawLabel(continuation ? "↳" : String(number), y: point.y + 2)
        }
        // Read only fragments already laid out for this viewport. Avoid enumeration
        // helpers that can request layout for the enclosing text container.
        var glyph = glyphs.location
        let limit = min(NSMaxRange(glyphs), layout.firstUnlaidGlyphIndex())
        while glyph < limit {
            var range = NSRange()
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range, withoutAdditionalLayout: true)
            guard range.length > 0, NSMaxRange(range) > glyph else { break }
            let character = layout.characterIndexForGlyph(at: range.location)
            if counter.isLineStart(character, in: text) {
                let line = firstLine - 1 + counter.line(at: character, in: text)
                drawNumber(line, y: fragment.minY, continuation: character == 0 && startsMidLine)
            }
            glyph = NSMaxRange(range)
        }
        // The trailing empty line is needed only after layout reaches EOF.
        if layout.firstUnlaidCharacterIndex() >= text.length && layout.extraLineFragmentTextContainer != nil {
            drawNumber(firstLine - 1 + counter.line(at: text.length, in: text), y: layout.extraLineFragmentRect.minY)
        }
    }
}
