import AppKit

func runSyntaxTests() throws {
    func expect(_ value: Bool, _ name: String) throws {
        guard value else { throw SessionError.invalid("TEST FAILED: \(name)") }
        print("PASS \(name)")
    }
    func tokens(_ source: NSString, _ language: TextLanguage, from point: SyntaxCheckpoint = SyntaxCheckpoint(offset: 0, state: SyntaxState())) -> [(NSRange, SyntaxToken)] {
        var result: [(NSRange, SyntaxToken)] = []
        _ = SyntaxLexer.scan(source, language: language, from: point, to: source.length) { result.append(($0, $1)) }
        return result
    }
    func has(_ list: [(NSRange, SyntaxToken)], _ source: NSString, _ needle: String, _ kind: SyntaxToken) -> Bool {
        let range = source.range(of: needle)
        return range.location != NSNotFound && list.contains { NSLocationInRange(range.location, $0.0) && $0.1 == kind }
    }
    let sql = "SELECT id, 'it''s 中文🙂' AS label FROM \"orders\" WHERE n >= 42; -- comment\n/* outer /* nested */ still */\nselect 1" as NSString
    let sqlTokens = tokens(sql, .sql)
    try expect(has(sqlTokens, sql, "SELECT", .keyword) && has(sqlTokens, sql, "中文", .string)
        && has(sqlTokens, sql, "orders", .key) && has(sqlTokens, sql, "42", .value)
        && has(sqlTokens, sql, "still", .comment), "SQL keywords, escaped strings, identifiers, numbers and nested comments")
    let yaml = "# 配置\nservice: textlet\nenabled: true\nnote: |-\n  SELECT stays text\n  # inside scalar\nnext: 2\nurl: https://example.com" as NSString
    let yamlTokens = tokens(yaml, .yaml)
    try expect(has(yamlTokens, yaml, "service", .key) && has(yamlTokens, yaml, "true", .value)
        && has(yamlTokens, yaml, "SELECT", .string) && has(yamlTokens, yaml, "# inside", .string)
        && has(yamlTokens, yaml, "next", .key), "YAML keys, booleans and indented block scalars")
    let toml = "[server.http]\nport = 8080\ntitle = \"中文🙂 # literal\"\nmessage = \"\"\"first\n# inside string\nlast\"\"\"\nenabled = true\n# outside" as NSString
    let tomlTokens = tokens(toml, .toml)
    try expect(has(tomlTokens, toml, "server", .key) && has(tomlTokens, toml, "port", .key)
        && has(tomlTokens, toml, "8080", .value) && has(tomlTokens, toml, "# inside", .string)
        && has(tomlTokens, toml, "# outside", .comment), "TOML sections, keys, numbers and multiline strings")
    let long = ("/*" + String(repeating: "中文🙂 comment\n", count: 1000) + "*/ SELECT 1") as NSString
    var points: [SyntaxCheckpoint] = []
    _ = SyntaxLexer.scan(long, language: .sql, from: SyntaxCheckpoint(offset: 0, state: SyntaxState()), to: 9000,
                         checkpoint: { points.append($0) }, emit: { _, _ in })
    let resumed = tokens(long, .sql, from: points.last!)
    try expect(has(resumed, long, "SELECT", .keyword) && resumed.first?.1 == .comment, "Sparse checkpoint resumes a long Unicode block comment")
    let oldRecord = Note(name: "settings.YML").record
    let decoded = try JSONDecoder().decode(NoteRecord.self, from: JSONEncoder().encode(oldRecord))
    try expect(decoded.syntax == nil && Note(record: decoded).language == .yaml, "Old records without syntax still load and detect uppercase extensions")
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("textlet-syntax-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: path) }
    let store = try SessionStore(directory: path)
    let note = Note(name: "example.sql", text: sql as String); note.record.syntax = "plain"
    try store.save(notes: [note], activeID: note.record.id)
    let restored = Note(record: try store.load()!.notes[0])
    try expect(restored.language == .plain && restored.record.syntax == "plain", "Explicit plain-text choice persists without changing text")
    restored.record.logPath = "/unused/large.sql"; restored.record.syntax = "sql"
    try expect(restored.language == .plain, "Read-only large-file tabs always disable highlighting")
    print("All syntax checks passed.")
}

// Short, isolated check of the actual AppKit integration; no user clipboard or input events.
func runAppearanceCheck(app: Textlet, output: URL) {
    var checks: [String: Bool] = [:]
    var source = ""
    let sql = Note(name: "query.sql", text: "-- 查询最近订单\nSELECT id, customer_name, amount\nFROM orders\nWHERE status = 'pending'\n  AND amount >= 100\nORDER BY created_at DESC\nLIMIT 20;\n")
    let yaml = Note(name: "settings.yaml", text: "# 服务配置\nservice: textlet\nport: 8080\nenabled: true\nmessage: |\n  随手记，轻一点。\n  SELECT is plain text here\nretry: 3\n")
    let toml = Note(name: "config.toml", text: "# 本地配置\n[server]\nhost = \"127.0.0.1\"\nport = 8080\nenabled = true\nmessage = \"\"\"中文🙂\n多行字符串\"\"\"\n")
    let plain = Note(name: "临时笔记", text: "今天要处理\n[ ] 修复查询超时\n[ ] 整理会议纪要\n")
    func later(_ delay: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) }
    func colored(_ needle: String, _ expected: NSColor) -> Bool {
        let range = (app.editor.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return false }
        return app.editor.layoutManager?.temporaryAttributes(atCharacterIndex: range.location, effectiveRange: nil)[.foregroundColor] as? NSColor == expected
    }
    func choose(_ language: TextLanguage) {
        let item = NSMenuItem(); item.representedObject = language.rawValue; app.changeLanguage(item)
    }
    later(0.5) {
        app.notes = [plain, sql, yaml, toml]; app.activeID = plain.record.id
        try? app.selectNote(sql.record.id, saveCurrent: false)
    }
    later(1.5) {
        app.highlighter.update()
        checks["sqlVisibleColor"] = colored("SELECT", Theme.keyword) && colored("pending", Theme.string)
        checks["opaqueMonokai"] = app.editor.backgroundColor == Theme.canvas && app.window.backgroundColor == Theme.chrome
        checks["colorIsNotStoredInDraft"] = app.editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.text
        captureTestWindow(app: app, to: output.appendingPathExtension("sql.png"))
        source = app.editor.string
        app.editor.breakUndoCoalescing()
        app.editor.insertText("-- 临时修改🙂\n", replacementRange: NSRange(location: 0, length: 0))
        app.editor.breakUndoCoalescing()
    }
    later(2) { app.active.undo.undo() }
    later(2.5) {
        checks["undoPreservesSource"] = app.editor.string == source && colored("SELECT", Theme.keyword)
        choose(.plain)
        checks["plainClearsColor"] = !colored("SELECT", Theme.keyword) && app.highlighter.language == .plain
        choose(.sql)
        checks["manualLanguageSaved"] = (try? app.store.load()?.notes.first(where: { $0.id == sql.record.id })?.syntax) == "sql"
        try? app.selectNote(yaml.record.id)
    }
    later(3.5) {
        app.highlighter.update()
        checks["yamlVisibleColor"] = colored("service", Theme.key) && colored("true", Theme.value) && colored("SELECT", Theme.string)
        captureTestWindow(app: app, to: output.appendingPathExtension("yaml.png"))
        try? app.selectNote(toml.record.id)
    }
    later(4.5) {
        app.highlighter.update()
        checks["tomlVisibleColor"] = colored("server", Theme.key) && colored("8080", Theme.value) && colored("多行", Theme.string)
        captureTestWindow(app: app, to: output.appendingPathExtension("toml.png"))
        let fixture = output.deletingLastPathComponent().appendingPathComponent("readonly.sql")
        try? "SELECT 1;\n".write(to: fixture, atomically: true, encoding: .utf8)
        app.openText(fixture, asLog: true)
    }
    later(5.5) {
        checks["logIsPlainAndReadOnly"] = app.active.isLog && app.highlighter.language == .plain && !app.editor.isEditable && !colored("SELECT", Theme.keyword)
        try? app.selectNote(sql.record.id)
    }
    later(6.5) {
        app.highlighter.update()
        checks["tabReturnRecolors"] = colored("SELECT", Theme.keyword)
        app.showReplace()
    }
    later(7.5) {
        checks["nativeReplaceStillOpens"] = app.scroller.isFindBarVisible
        captureTestWindow(app: app, to: output.appendingPathExtension("replace.png"))
        let result: [String: Any] = ["checks": checks, "memoryMiB": memorySample(), "scope": "8-second isolated smoke check, synthetic small files, 860x590 window"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output) }
        print(result)
        NSApp.terminate(nil)
    }
}
