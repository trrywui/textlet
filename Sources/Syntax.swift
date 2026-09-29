import AppKit

enum TextLanguage: String, CaseIterable {
    case plain, sql, yaml, toml
    var title: String { self == .plain ? "纯文本" : rawValue.uppercased() }
    static func detect(_ name: String) -> TextLanguage {
        switch (name as NSString).pathExtension.lowercased() {
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        default: return .plain
        }
    }
}

enum SyntaxToken { case comment, string, keyword, key, value
    var color: NSColor {
        switch self {
        case .comment: return Theme.comment
        case .string: return Theme.string
        case .keyword: return Theme.keyword
        case .key: return Theme.key
        case .value: return Theme.value
        }
    }
}

// Lexical state only. No token tree or second copy of the document is retained.
struct SyntaxState {
    var quote: unichar = 0
    var triple = false
    var blockDepth = 0
    var lineComment = false
    var bareTail = false
    var section = false
    var lineStart = true
    var indent = 0
    var yamlBlock: Int?
    var pendingBlock: Int?
}
struct SyntaxCheckpoint {
    var offset: Int
    var state: SyntaxState
}

private final class SyntaxCharacters {
    let text: NSString
    private var buffer = [unichar](repeating: 0, count: 4096)
    private var start = -4096, count = 0
    init(_ text: NSString) { self.text = text }
    func at(_ index: Int) -> unichar {
        guard index >= 0, index < text.length else { return 0 }
        if index < start || index >= start + count {
            start = index; count = min(buffer.count, text.length - index)
            text.getCharacters(&buffer, range: NSRange(location: start, length: count))
        }
        return buffer[index - start]
    }
}

enum SyntaxLexer {
    private static let keywords = Set("select from where and or not null is in as on join inner left right full outer cross union all distinct group by having order asc desc limit offset insert into values update set delete create alter drop table view index primary foreign key references constraint default unique check if exists case when then else end begin commit rollback transaction with recursive returning count sum avg min max over partition rows between like ilike true false grant revoke explain analyze truncate database schema use replace conflict do nothing cast varchar char text integer int bigint boolean numeric decimal date timestamp interval".split(separator: " ").map(String.init))
    private static func space(_ c: unichar) -> Bool { c == 32 || c == 9 }
    private static func newline(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }
    private static func digit(_ c: unichar) -> Bool { (48...57).contains(c) }
    private static func letter(_ c: unichar) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 || (c >= 128 && !newline(c)) }
    private static func word(_ c: unichar, _ language: TextLanguage) -> Bool {
        letter(c) || digit(c) || (language != .sql && (c == 45 || c == 46))
    }

    // Checkpoints are taken only between tokens; long comments and strings carry state.
    // The requested end may be exceeded by at most one small token/delimiter.
    static func scan(_ text: NSString, language: TextLanguage, from point: SyntaxCheckpoint, to end: Int,
                     checkpoint: (SyntaxCheckpoint) -> Void = { _ in },
                     emit: (NSRange, SyntaxToken) -> Void) -> SyntaxCheckpoint {
        let chars = SyntaxCharacters(text)
        let limit = min(text.length, end)
        var i = point.offset, state = point.state, checkpointOffset = point.offset
        var runStart = i, runEnd = i
        var runKind: SyntaxToken?
        func paint(_ start: Int, _ end: Int, _ kind: SyntaxToken?) {
            if kind == runKind, start == runEnd { runEnd = end; return }
            if let previous = runKind, runEnd > runStart { emit(NSRange(location: runStart, length: runEnd - runStart), previous) }
            runStart = start; runEnd = end; runKind = kind
        }
        while i < limit {
            let start = i, c = chars.at(i)
            if i - checkpointOffset >= 4096 {
                checkpoint(SyntaxCheckpoint(offset: i, state: state)); checkpointOffset = i
            }
            if newline(c) {
                paint(i, i + 1, state.quote != 0 || state.yamlBlock != nil ? .string : (state.blockDepth > 0 ? .comment : nil))
                state.lineComment = false; state.section = false; state.bareTail = false
                if language == .toml && !state.triple { state.quote = 0 }
                if let indent = state.pendingBlock { state.yamlBlock = indent; state.pendingBlock = nil }
                state.lineStart = true; state.indent = 0; i += 1; continue
            }
            if state.lineStart {
                if space(c) { state.indent += 1 }
                else {
                    state.lineStart = false
                    if let parent = state.yamlBlock, state.indent <= parent { state.yamlBlock = nil }
                }
            }
            if state.yamlBlock != nil { paint(i, i + 1, .string); i += 1; continue }
            if state.lineComment { paint(i, i + 1, .comment); i += 1; continue }
            if state.blockDepth > 0 {
                if c == 47 && chars.at(i + 1) == 42 { state.blockDepth += 1; i += 2 }
                else if c == 42 && chars.at(i + 1) == 47 { state.blockDepth -= 1; i += 2 }
                else { i += 1 }
                paint(start, i, .comment); continue
            }
            if state.quote != 0 {
                let color: SyntaxToken = language == .sql && state.quote != 39 ? .key : .string
                if c == 92 && (state.quote == 34 || (language == .sql && state.quote == 39)) {
                    i += chars.at(i + 1) == 0 || newline(chars.at(i + 1)) ? 1 : 2
                } else if c == state.quote {
                    if state.triple {
                        if chars.at(i + 1) == c && chars.at(i + 2) == c { state.quote = 0; state.triple = false; i += 3 }
                        else { i += 1 }
                    } else if language != .toml && chars.at(i + 1) == c { i += 2 }
                    else { state.quote = 0; i += 1 }
                } else { i += 1 }
                paint(start, i, color); continue
            }
            if state.bareTail {
                if word(c, language) { paint(i, i + 1, nil); i += 1; continue }
                state.bareTail = false
            }
            if state.section { i += 1; paint(start, i, .key); if c == 93 { state.section = false }; continue }
            if (c == 35 && language != .sql) || (language == .sql && (c == 35 || (c == 45 && chars.at(i + 1) == 45))) {
                state.lineComment = true; continue
            }
            if language == .sql && c == 47 && chars.at(i + 1) == 42 {
                state.blockDepth = 1; i += 2; paint(start, i, .comment); continue
            }
            if c == 39 || c == 34 || (language == .sql && c == 96) {
                state.quote = c
                state.triple = language == .toml && chars.at(i + 1) == c && chars.at(i + 2) == c
                i += state.triple ? 3 : 1
                paint(start, i, language == .sql && c != 39 ? .key : .string); continue
            }
            if language == .toml && c == 91 && start - state.indent == lineStartOffset(text, start) {
                state.section = true; i += 1; paint(start, i, .key); continue
            }
            if language == .yaml && (c == 124 || c == 62) {
                state.pendingBlock = state.indent; i += 1; paint(start, i, .string); continue
            }
            if digit(c) || ((c == 43 || c == 45) && digit(chars.at(i + 1))) {
                i += 1
                while i < text.length && i - start < 64 {
                    let n = chars.at(i), previous = chars.at(i - 1)
                    if digit(n) || n == 46 || n == 95 || n == 120 || n == 88 || (65...70).contains(n) || (97...102).contains(n)
                        || ((n == 43 || n == 45) && (previous == 69 || previous == 101)) { i += 1 }
                    else { break }
                }
                paint(start, i, .value); continue
            }
            if letter(c) {
                i += 1
                while i < text.length && i - start < 64 && word(chars.at(i), language) { i += 1 }
                if word(chars.at(i), language) { state.bareTail = true; paint(start, i, nil); continue }
                let token = text.substring(with: NSRange(location: start, length: i - start)).lowercased()
                var kind: SyntaxToken?
                if language == .sql { if keywords.contains(token) { kind = .keyword } }
                else {
                    var next = i
                    // Bound look-ahead even in files with pathological whitespace.
                    while next < min(text.length, i + 256) && space(chars.at(next)) { next += 1 }
                    if (language == .toml && chars.at(next) == 61)
                        || (language == .yaml && chars.at(next) == 58 && (space(chars.at(next + 1)) || newline(chars.at(next + 1)) || next + 1 == text.length)) { kind = .key }
                    else if ["true", "false", "null", "inf", "nan"].contains(token) { kind = .value }
                }
                paint(start, i, kind); continue
            }
            i += 1; paint(start, i, nil)
        }
        if let kind = runKind, runEnd > runStart { emit(NSRange(location: runStart, length: runEnd - runStart), kind) }
        return SyntaxCheckpoint(offset: i, state: state)
    }
    private static func lineStartOffset(_ text: NSString, _ offset: Int) -> Int {
        var start = 0
        text.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: offset, length: 0))
        return start
    }
}

final class SyntaxHighlighter {
    weak var editor: NSTextView?
    var onHighlight: (() -> Void)?
    private(set) var language: TextLanguage = .plain
    private var points = [SyntaxCheckpoint(offset: 0, state: SyntaxState())]
    private var painted: NSRange?
    private var scheduled = false
    private var updating = false
    init(editor: NSTextView) { self.editor = editor }
    func reset(_ language: TextLanguage) {
        clearColors(); self.language = language
        points = [SyntaxCheckpoint(offset: 0, state: SyntaxState())]; painted = nil
        schedule()
    }
    func invalidate(from offset: Int) {
        while points.count > 1 && points.last!.offset >= max(1, offset) { points.removeLast() }
        painted = nil; schedule()
    }
    func schedule() {
        guard language != .plain, !scheduled, !updating else { return }
        scheduled = true
        // Coalesce viewport/edit notifications, with no idle polling timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }; self.scheduled = false; self.update()
        }
    }
    private func clearColors() {
        guard let layout = editor?.layoutManager, let storage = editor?.textStorage else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
#if ROW_RENDERER
        (editor as? RowRenderingTextView)?.invalidateRows()
#endif
    }
    func update() {
        guard !updating, language != .plain, let editor, !editor.hasMarkedText(),
              let layout = editor.layoutManager, let container = editor.textContainer,
              let text = editor.textStorage?.mutableString else { return }
        // Large read-only files select .plain; pasted giant drafts also avoid highlighting.
        guard text.length <= 8 * 1_048_576 else { clearColors(); points = [SyntaxCheckpoint(offset: 0, state: SyntaxState())]; return }
        updating = true
        var visible = editor.visibleRect
        visible.origin.x -= editor.textContainerOrigin.x; visible.origin.y -= editor.textContainerOrigin.y
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
        var target = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        target.length = min(target.length, 65536)
        guard target != painted else { updating = false; return }
        var low = 0, high = points.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if points[mid].offset <= target.location { low = mid } else { high = mid }
        }
        let point = points[low]
        let warming = target.location - point.offset > 65536
        let end = warming ? point.offset + 65536 : NSMaxRange(target)
        clearColors()
        func remember(_ point: SyntaxCheckpoint) { if point.offset > points.last!.offset { points.append(point) } }
        _ = SyntaxLexer.scan(text, language: language, from: point, to: end, checkpoint: remember) { range, token in
            guard !warming else { return }
            let visiblePart = NSIntersectionRange(target, range)
            if visiblePart.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: token.color, forCharacterRange: visiblePart) }
        }
        painted = warming ? nil : target
        updating = false
        onHighlight?()
        if warming { schedule() }
    }
}
