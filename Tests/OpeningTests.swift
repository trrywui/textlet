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
    let binary = store.directory.appendingPathComponent("binary.txt")
    try Data("%PDF-1.7\n".utf8).write(to: binary)
    for mode in [false, true] {
        let ids = app.notes.map { $0.record.id }
        var rejected = false
        do { try app.openDocument(binary, asLog: mode) }
        catch { rejected = error.localizedDescription == "此文件不是受支持的文本文件" }
        checks["binaryRejectedBeforeCreatingTab-\(mode)"] = rejected && app.notes.map { $0.record.id } == ids
            && app.active === original && app.editor.string == "preserve unsaved text"
    }
    let binaryHandle = try FileHandle(forWritingTo: binary)
    try binaryHandle.truncate(atOffset: 1_073_741_824); try binaryHandle.close()
    let beforeLargeBinary = app.notes.map { $0.record.id }
    var rejectedLargeBinary = false
    do { try app.openDocument(binary) }
    catch { rejectedLargeBinary = error.localizedDescription == "此文件不是受支持的文本文件" }
    checks["largeBinaryRejectedWithoutTabOrIndex"] = rejectedLargeBinary && app.notes.map { $0.record.id } == beforeLargeBinary
        && app.active === original && app.active.logFile == nil && app.active.logIndex == nil

    let first = store.directory.appendingPathComponent("first.custom")
    let last = store.directory.appendingPathComponent("last.custom")
    for url in [first, last] { try Data("plain text 中文\n".utf8).write(to: url) }
    let countBeforeBatch = app.notes.count
    var sawBinaryAlert = false
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let deadline = Date().addingTimeInterval(3)
    let dismiss = Timer(timeInterval: 0.02, repeats: true) { _ in
        if let content = NSApp.modalWindow?.contentView {
            let views = descendants(content)
            sawBinaryAlert = sawBinaryAlert || views.compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "此文件不是受支持的文本文件" }
            views.compactMap { $0 as? NSButton }.first { $0.title == "好" }?.performClick(nil)
        }
        if Date() > deadline { NSApp.abortModal() }
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }
    RunLoop.main.add(dismiss, forMode: .modalPanel); RunLoop.main.add(dismiss, forMode: .common)
    app.application(NSApplication.shared, openFiles: [first.path, binary.path, last.path])
    dismiss.invalidate()
    checks["finderBatchContinuesAfterBinaryFailure"] = sawBinaryAlert && app.notes.count == countBeforeBatch + 2
        && app.active.record.file?.path == DocumentFile.canonical(last).path
    checks["finderBatchPreservesUnsavedText"] = original.storage?.string == "preserve unsaved text"
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
    checks["openingRecoversAfterBackupFailure"] = app.active.record.file?.path == DocumentFile.canonical(another).path && app.lastSaveError == nil
    if checks["openingRecoversAfterBackupFailure"] != true {
        print("Recovery diagnostic: source=\(another.path), opened=\(app.active.record.file?.path ?? "nil"), backup=\(app.lastSaveError ?? "none")")
    }

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

func runOpeningCheck(app: Textlet, output: URL) {
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
        do {
            let checks = try checkOpening(app: app)
            let failures = checks.filter { !$0.value }.keys.sorted()
            let report: [String: Any] = ["checks": checks, "failures": failures]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("Opening checks: \(checks.count), failures: \(failures)"); fflush(stdout)
            if !failures.isEmpty { exit(1) }
            NSApp.terminate(nil)
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
