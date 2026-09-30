import AppKit

func runTitleTests(root: URL) throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    let note = Note(name: "文本2", automaticTitle: true)
    func replace(_ text: String) {
        note.storage!.mutableString.setString(text)
        note.dirty = true
        note.refreshContentTitle()
    }
    try expect(note.displayName == "文本2", "empty automatic title uses its original number")
    for newline in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
        replace(" \t" + newline + "  采购清单 中文🙂 \t" + newline + "苹果")
        try expect(note.displayName == "采购清单 中文🙂", "title uses first nonblank line across \(newline.debugDescription)")
    }
    try expect(note.record.name == "文本2" && note.language == .plain, "content title does not change the base name or syntax")
    replace("config.sql\n正文")
    try expect(note.displayName == "config.sql" && note.language == .plain, "a filename in the first line does not change syntax detection")
    replace("文本100\n正文")
    try expect(Note.nextName(in: [note]) == "文本3", "a numbered content title does not consume new-tab numbers")
    replace("\n \t\r\n\u{00a0}\u{3000}")
    try expect(note.displayName == "文本2", "all-whitespace content restores the original number")
    replace(String(repeating: "🙂", count: 100_000))
    try expect(note.displayName == String(repeating: "🙂", count: 80) + "…", "very long first line is bounded without splitting emoji")
    replace(String(repeating: "a", count: 159) + "👩‍💻" + "remaining")
    try expect(note.displayName == String(repeating: "a", count: 159) + "👩‍💻…", "preview preserves a composed emoji at the truncation boundary")
    replace(String(repeating: " \n", count: 10_000) + "最后的内容")
    try expect(note.displayName == "最后的内容", "leading blank lines do not hide the first content line")
    replace("标题\n正文")
    note.storage!.mutableString.append("更新")
    try expect(!note.refreshContentTitle(editedFrom: 5) && note.displayName == "标题", "editing below the title keeps it unchanged")
    note.storage!.mutableString.deleteCharacters(in: NSRange(location: 0, length: 3))
    note.refreshContentTitle(editedFrom: 0)
    try expect(note.displayName == "正文更新", "deleting the title line uses the following content")

    let store = try SessionStore(directory: root)
    replace("采购清单\n苹果")
    let named = Note(name: "文本9", text: "文件正文")
    let custom = Note(name: "固定标题", text: "另一行内容", automaticTitle: true)
    custom.rename(to: "文本10")
    let log = Note(record: NoteRecord(id: UUID(), name: "server.log", draftFile: "", selection: 0, scrollY: 0,
        logPath: "/not-opened/server.log", automaticTitle: true, contentTitle: "日志正文"))
    try expect(named.displayName == "文本9", "opened filenames resembling numbered titles stay fixed")
    try expect(custom.displayName == "文本10", "manual rename overrides content even when it resembles an automatic name")
    try expect(log.displayName == "server.log", "read-only log titles always use the filename")
    try store.save(notes: [note, named, custom, log], activeID: note.record.id)
    note.storage = nil
    try expect(note.displayName == "采购清单", "releasing an inactive text buffer keeps its content title")
    let restored = try store.load()!.notes.map { Note(record: $0) }
    try expect(restored.map(\.displayName) == ["采购清单", "文本9", "文本10", "server.log"], "titles and naming modes survive a session round trip")
    try expect(restored.allSatisfy { $0.storage == nil }, "restored titles do not retain every text buffer")
    let restoredBody = try store.text(for: restored[0].record)
    try expect(restoredBody == "采购清单\n苹果", "title extraction leaves body text unchanged")

    // Old records have neither title field, regardless of their original name.
    let oldNames = ["临时笔记", "笔记 2", "文本1", "自定义标题", "query.sql"]
    let old = oldNames.map { name -> Note in
        let value = Note(name: name, text: "不应用的新标题")
        value.record.automaticTitle = nil
        return value
    }
    let oldStore = try SessionStore(directory: root.appendingPathComponent("legacy"))
    try oldStore.save(notes: old, activeID: old[0].record.id)
    let oldRecords = try oldStore.load()!.notes
    try expect(oldRecords.allSatisfy { $0.automaticTitle == nil }, "old sessions remain readable without an automatic-title flag")
    try expect(oldRecords.map { Note(record: $0).displayName } == oldNames, "every existing tab keeps its old display name")
    print("All title tests passed.")
}

// Use real editor notifications and undo, with only synthetic session content.
func checkTitleEditing(app: Textlet) throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let originalIDs = Set(app.notes.map { $0.record.id })
    let originalActive = app.activeID!
    defer {
        for id in app.notes.map({ $0.record.id }) where !originalIDs.contains(id) { try? app.removeNote(id) }
        try? app.selectNote(originalActive)
    }
    func tab(_ note: Note) -> NoteTab {
        app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.first { $0.id == note.record.id }!
    }
    func edit(_ text: String, range: NSRange) {
        app.active.undo.beginUndoGrouping()
        app.editor.insertText(text, replacementRange: range)
        app.editor.breakUndoCoalescing()
        app.active.undo.endUndoGrouping()
    }
    app.newNote()
    let note = app.active
    // These edits run in one timer callback; model separate user editing events.
    note.undo.groupsByEvent = false
    let baseName = note.record.name
    let originalTab = tab(note)
    edit("\n  采购清单 中文🙂  \n苹果", range: NSRange(location: 0, length: 0))
    checks["typedFirstNonblankLineUpdatesTitle"] = tab(note).label.stringValue == "采购清单 中文🙂"
    checks["titleTooltipAndAccessibilityUpdate"] = tab(note).toolTip?.hasPrefix("采购清单 中文🙂") == true
        && tab(note).accessibilityLabel() == "采购清单 中文🙂"
    let range = (app.editor.string as NSString).range(of: "采购清单")
    edit("旅行计划", range: range)
    checks["editingTitleUpdatesExistingTab"] = tab(note) === originalTab && tab(note).label.stringValue == "旅行计划 中文🙂"
    note.undo.undo()
    checks["undoRestoresContentTitle"] = tab(note).label.stringValue == "采购清单 中文🙂" && app.editor.string == "\n  采购清单 中文🙂  \n苹果"
    note.undo.redo()
    checks["redoRestoresContentTitle"] = tab(note).label.stringValue == "旅行计划 中文🙂"
    edit(" \t\n", range: NSRange(location: 0, length: app.editor.string.utf16.count))
    checks["whitespaceRestoresOriginalNumberInTab"] = tab(note).label.stringValue == baseName
    edit("", range: NSRange(location: 0, length: app.editor.string.utf16.count))
    checks["clearingRestoresOriginalNumberInTab"] = tab(note).label.stringValue == baseName
    edit("config.sql\n正文", range: NSRange(location: 0, length: 0))
    checks["contentTitleKeepsPlainSyntaxAndBaseName"] = note.language == .plain && note.record.name == baseName
    let expectedNext = Note.nextName(in: app.notes)
    app.newNote()
    checks["newTabNumberSurvivesContentTitles"] = app.active.record.name == expectedNext
    checks["inactiveTabKeepsContentTitle"] = tab(note).label.stringValue == "config.sql"
    try app.selectNote(note.record.id)
    note.rename(to: "手动标题")
    app.renderTabs()
    edit("正文已变化", range: NSRange(location: 0, length: app.editor.string.utf16.count))
    checks["manualRenameStaysFixedDuringEditing"] = tab(note).label.stringValue == "手动标题"

    let source = app.store.directory.appendingPathComponent("source.sql")
    try Data("-- 文件首行\nSELECT 1;".utf8).write(to: source)
    app.openText(source)
    let file = app.active
    checks["openedFileKeepsFilenameAndSyntax"] = tab(file).label.stringValue == "source.sql" && file.language == .sql
    edit("-- 更新的首行", range: NSRange(location: 0, length: 7))
    checks["editingOpenedFileKeepsFilename"] = tab(file).label.stringValue == "source.sql"
    return checks
}
