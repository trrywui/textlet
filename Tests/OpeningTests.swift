import AppKit

private final class FailingSessionStore: SessionStore {
    var savesUntilFailure: Int?
    override func save(notes: [Note], activeID: UUID, windowFrame: NSRect? = nil) throws {
        if let remaining = savesUntilFailure {
            guard remaining > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
            savesUntilFailure = remaining - 1
        }
        try super.save(notes: notes, activeID: activeID, windowFrame: windowFrame)
    }
}

func checkOpening(app: Textlet) throws -> [String: Bool] {
    let oldStore = app.store!, oldNotes = app.notes, oldActive = app.activeID!
    app.capturePosition()
    let store = try FailingSessionStore(directory: oldStore.directory.appendingPathComponent("opening-session"))
    defer {
        app.saveTimer?.invalidate(); app.saveTimer = nil
        app.store = oldStore; app.notes = oldNotes
        try? app.selectNote(oldActive, saveCurrent: false)
        app.lastSaveError = nil; app.updateStatus()
    }
    app.store = store
    let original = Note(name: "original", text: "preserve unsaved text")
    app.notes = [original]
    try app.selectNote(original.record.id, saveCurrent: false)
    var checks: [String: Bool] = [:]
    let url = store.directory.appendingPathComponent("source.txt")
    try Data("disk text".utf8).write(to: url)
    try app.openDocument(url)
    let editable = app.active
    app.editor.insertText(" pending", replacementRange: NSRange(location: app.editor.string.utf16.count, length: 0))
    let pendingText = app.editor.string
    try app.openDocument(url, asLog: true)
    let log = app.active
    checks["explicitLogOpenIsReadOnly"] = log.isLog && !app.editor.isEditable && !app.editor.allowsUndo && !app.saveNote(log)
    let sourceText = try String(contentsOf: url, encoding: .utf8)
    checks["logOpenPreservesUnsavedEditorAndSource"] = editable.storage?.string == pendingText && editable.needsFileSave && sourceText == "disk text"
    let count = app.notes.count
    try app.openDocument(url, asLog: true)
    checks["repeatedLogOpenReusesTab"] = app.active === log && app.notes.count == count
    let alias = store.directory.appendingPathComponent("alias.txt")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
    // Also exercise an older session whose log path was not canonicalized.
    log.record.logPath = alias.path
    try app.openDocument(url, asLog: true)
    try app.openDocument(alias, asLog: true)
    checks["logAliasesAndLegacyPathsReuseTab"] = app.active === log && app.notes.count == count
    try app.openDocument(alias)
    checks["editableModeReusesOwnTab"] = app.active === editable && app.editor.isEditable
        && app.editor.string == pendingText && app.notes.count == count

    let large = store.directory.appendingPathComponent("large.log")
    try Data(repeating: 0x61, count: 8 * 1_048_576 + 1).write(to: large)
    try app.openDocument(large)
    let largeLog = app.active
    try app.openDocument(large, asLog: true)
    checks["automaticAndExplicitLogModesShareTab"] = largeLog.isLog && app.active === largeLog && app.notes.count == count + 1
    try app.selectNote(editable.record.id)

    let another = store.directory.appendingPathComponent("another.txt")
    try Data("another text".utf8).write(to: another)
    let ids = app.notes.map { $0.record.id }
    store.savesUntilFailure = 0
    for mode in [false, true] {
        var failed = false
        do { try app.openDocument(another, asLog: mode) } catch { failed = true }
        checks["failedOpenRollsBack-\(mode)"] = failed && app.notes.map { $0.record.id } == ids
            && app.active === editable && app.editor.string == pendingText
            && app.tabStack.arrangedSubviews.compactMap { ($0 as? NoteTab)?.id } == ids
    }
    var selectionFailed = false
    do { try app.selectNote(original.record.id) } catch { selectionFailed = true }
    checks["selectionReportsBackupFailure"] = selectionFailed && app.active === editable
    store.savesUntilFailure = nil
    try app.openDocument(another)
    checks["openingRecoversAfterBackupFailure"] = app.active.record.file?.path == another.path && app.lastSaveError == nil

    for mode in [false, true] {
        let finalURL = store.directory.appendingPathComponent("final-\(mode).txt")
        try Data("final text".utf8).write(to: finalURL)
        store.savesUntilFailure = 1
        let backedUp = try app.openDocument(finalURL, asLog: mode)
        let visible = app.active
        checks["finalBackupFailureKeepsVisibleTab-\(mode)"] = !backedUp && visible.isLog == mode
            && app.tabStack.arrangedSubviews.contains { ($0 as? NoteTab)?.id == visible.record.id }
            && app.lastSaveError != nil
        store.savesUntilFailure = nil
        let saved = app.saveSession()
        let restored = try store.load()
        checks["finalBackupCanBeRetried-\(mode)"] = saved && restored?.activeID == visible.record.id
            && restored?.notes.contains { $0.id == visible.record.id } == true
    }
    return checks
}
