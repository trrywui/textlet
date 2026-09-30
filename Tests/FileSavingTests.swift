import AppKit

func runFileSavingTests(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    let source = root.appendingPathComponent("script.sh")
    let original = "#!/bin/sh\r\necho '中文🙂'\r\n"
    try Data(original.utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
    let note = try DocumentFile.open(source)
    try expect(!note.needsFileSave && note.record.file?.path == source.path, "opened file starts clean and keeps its path")
    note.storage!.mutableString.append("# pending\r\n"); note.dirty = true; note.refreshFileModification()
    try expect(note.needsFileSave, "editing a linked file marks it unsaved")
    let store = try SessionStore(directory: root.appendingPathComponent("session"))
    try store.save(notes: [note], activeID: note.record.id)
    let stillOriginal = try String(contentsOf: source, encoding: .utf8)
    try expect(stillOriginal == original && note.needsFileSave, "session backup neither writes the source nor clears its dirty state")
    let restored = Note(record: try store.load()!.notes[0])
    try expect(restored.needsFileSave && restored.record.file?.path == source.path, "linked path and unsaved state survive restoration")
    let pending = try store.text(for: restored.record)
    try expect(pending == original + "# pending\r\n", "restoration keeps the unsaved body")
    let version = try DocumentFile.version(at: source)
    try DocumentFile.write(note, text: pending, to: source, expected: version)
    let saved = try String(contentsOf: source, encoding: .utf8)
    let permissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
    try expect(saved == pending && !note.needsFileSave && permissions == 0o755, "explicit save writes back, clears dirty state and preserves executable permissions")
    note.storage!.mutableString.setString(""); note.refreshFileModification()
    try expect(note.needsFileSave, "clearing a linked file remains an unsaved change")
    note.storage!.mutableString.setString(pending); note.refreshFileModification()
    try expect(!note.needsFileSave, "returning to saved content clears the unsaved marker")

    let stale = try DocumentFile.version(at: source)
    try Data("external edit".utf8).write(to: source)
    var rejected = false
    do { try DocumentFile.write(note, text: "must not overwrite", to: source, expected: stale) } catch { rejected = true }
    let external = try String(contentsOf: source, encoding: .utf8)
    try expect(rejected && external == "external edit", "a changed destination is rejected before writing")
    try FileManager.default.removeItem(at: source)
    note.refreshFileState()
    try expect(note.fileMissing && note.needsFileSave, "missing clean source becomes unsaved even without local edits")
    try store.save(notes: [note], activeID: note.record.id)
    let missing = Note(record: try store.load()!.notes[0])
    let missingText = try store.text(for: missing.record)
    try expect(missing.fileMissing && missing.needsFileSave && missingText == pending, "missing file restores its original content and missing state")

    for (suffix, encoding, bom) in [("utf8", String.Encoding.utf8, [UInt8](arrayLiteral: 0xef, 0xbb, 0xbf)),
        ("utf16", .utf16LittleEndian, [0xff, 0xfe]), ("utf16be", .utf16BigEndian, [0xfe, 0xff])] {
        let url = root.appendingPathComponent(suffix + ".txt")
        var bytes = Data(bom); bytes.append(original.data(using: encoding)!)
        try bytes.write(to: url)
        let encoded = try DocumentFile.open(url)
        try expect(encoded.storage!.string == original, "\(suffix) BOM is decoded without entering the editor")
        let changed = original + "下一行\r\n"
        try DocumentFile.write(encoded, text: changed, to: url, expected: try DocumentFile.version(at: url))
        var expected = Data(bom); expected.append(changed.data(using: encoding)!)
        let actual = try Data(contentsOf: url)
        try expect(actual == expected, "\(suffix) encoding, BOM and CRLF survive an explicit save")
    }
    let draft = Note(name: "文本1", text: "草稿", automaticTitle: true)
    let destination = root.appendingPathComponent("saved.sql")
    try DocumentFile.write(draft, text: draft.storage!.string, to: destination, expected: .absent, asUTF8: true)
    try expect(!draft.needsFileSave && draft.record.file?.path == destination.path && draft.displayName == "saved.sql" && draft.language == .sql,
               "first save binds a draft to its filename and syntax")
    let old = Note(name: "old.sql", text: "old imported draft")
    try expect(old.needsFileSave && old.record.file == nil, "legacy drafts never acquire a guessed original path")
    print("All file saving tests passed.")
}

func checkFileSaving(app: Textlet) throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let oldIDs = Set(app.notes.map { $0.record.id }), oldActive = app.activeID!
    defer {
        for id in app.notes.map({ $0.record.id }) where !oldIDs.contains(id) { try? app.removeNote(id) }
        try? app.selectNote(oldActive)
    }
    let directory = app.store.directory.appendingPathComponent("file-fixtures")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("draft.sql")
    app.newNote()
    let note = app.active
    note.undo.groupsByEvent = false
    func edit(_ text: String) {
        note.undo.beginUndoGrouping()
        app.editor.insertText(text, replacementRange: NSRange(location: 0, length: app.editor.string.utf16.count))
        app.editor.breakUndoCoalescing(); note.undo.endUndoGrouping()
    }
    checks["emptyDraftHasUnsavedCircle"] = note.needsFileSave
    edit("SELECT 1;\r\n")
    var panels = 0
    checks["firstSaveChoosesPath"] = app.saveNote(note, chooseDestination: { _ in panels += 1; return destination }) && panels == 1
    checks["firstSaveUsesFilenameAndCleanState"] = note.displayName == "draft.sql" && !note.needsFileSave
    edit("SELECT 2;\r\n")
    checks["linkedEditShowsUnsavedState"] = note.needsFileSave
    note.undo.undo()
    checks["undoToSavedContentsClearsCircle"] = !note.needsFileSave
    note.undo.redo()
    checks["redoMarksLinkedFileUnsaved"] = note.needsFileSave
    checks["directSaveSkipsPanel"] = app.saveNote(note, chooseDestination: { _ in panels += 1; return nil }) && panels == 1
    let saved = try String(contentsOf: destination, encoding: .utf8)
    checks["directSaveWritesSource"] = saved == "SELECT 2;\r\n"
    let count = app.notes.count
    app.openText(destination)
    checks["openingLinkedFileReusesTab"] = app.notes.count == count && app.active === note
    edit("local pending")
    try Data("external contents".utf8).write(to: destination)
    var conflicts = 0
    checks["conflictCanCancel"] = !app.saveNote(note, resolveConflict: { _ in conflicts += 1; return .cancel }) && conflicts == 1
    let external = try String(contentsOf: destination, encoding: .utf8)
    checks["cancelPreservesBothVersions"] = external == "external contents" && app.editor.string == "local pending" && note.needsFileSave
    checks["conflictCanOverwrite"] = app.saveNote(note, resolveConflict: { _ in .overwrite }) && !note.needsFileSave
    let overwritten = try String(contentsOf: destination, encoding: .utf8)
    checks["overwriteUsesEditorContent"] = overwritten == "local pending"
    try FileManager.default.moveItem(at: destination, to: directory.appendingPathComponent("moved.sql"))
    // Let the filesystem notification arrive without application activation or explicit refresh.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
    checks["fileMoveUpdatesMissingStateWithoutPolling"] = note.fileMissing && note.needsFileSave
    let tab = app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.first { $0.id == note.record.id }!
    checks["missingFileButtonIsRed"] = tab.subviews.compactMap { $0 as? NSButton }.first?.contentTintColor == .systemRed
    let panel = app.makeSavePanel(for: note)
    checks["missingFilePanelKeepsEditableFilename"] = panel.nameFieldStringValue == "draft.sql"
    let before = panels
    checks["missingSaveCancellationKeepsState"] = !app.saveNote(note, chooseDestination: { _ in panels += 1; return nil })
        && panels == before + 1 && note.fileMissing && !FileManager.default.fileExists(atPath: destination.path)
    let replacement = directory.appendingPathComponent("renamed.sql")
    checks["missingSaveSelectsNewPath"] = app.saveNote(note, chooseDestination: { _ in replacement })
        && note.record.file?.path == replacement.path && !note.needsFileSave
    edit("after relocation")
    checks["subsequentSaveUsesNewPath"] = app.saveNote(note, chooseDestination: { _ in panels += 1; return nil }) && panels == before + 1
    let relocated = try String(contentsOf: replacement, encoding: .utf8)
    checks["relocatedFileHasLatestContent"] = relocated == "after relocation"
    try Data("another external version".utf8).write(to: replacement)
    let alternate = directory.appendingPathComponent("conflict-copy.sql")
    checks["conflictCanSaveAs"] = app.saveNote(note, chooseDestination: { _ in alternate }, resolveConflict: { _ in .saveAs })
        && note.record.file?.path == alternate.path
    let untouched = try String(contentsOf: replacement, encoding: .utf8)
    checks["conflictSaveAsPreservesExternalFile"] = untouched == "another external version"
    app.closeNote(note.record.id)
    checks["cleanLinkedFileClosesWithoutPrompt"] = !app.notes.contains { $0 === note }
    return checks
}

func runFileSessionCheck(app: Textlet, output: URL) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        do {
            let directory = app.store.directory.appendingPathComponent("sources")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var fixtures: [Note] = []
            for name in ["clean.txt", "edited.txt", "missing-clean.txt", "missing-edited.txt"] {
                let url = directory.appendingPathComponent(name)
                try Data("original \(name)".utf8).write(to: url)
                let note = try DocumentFile.open(url)
                if name.contains("edited") { note.storage!.mutableString.append(" + unsaved 中文🙂"); note.dirty = true; note.refreshFileModification() }
                if name.hasPrefix("missing") { try FileManager.default.removeItem(at: url); note.refreshFileState() }
                fixtures.append(note)
            }
            fixtures.append(Note(name: "文本1", text: "未保存草稿", automaticTitle: true))
            app.notes = fixtures
            try app.selectNote(fixtures[1].record.id, saveCurrent: false)
            app.window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            captureTestWindow(app: app, to: output.appendingPathExtension("png"))
            let expected: [[String: Any]] = fixtures.map { note in
                ["id": note.record.id.uuidString, "name": note.record.name, "text": note.storage!.string,
                 "selection": 0, "needsFileSave": note.needsFileSave, "fileMissing": note.fileMissing,
                 "filePath": note.record.file?.path ?? "", "displayName": note.displayName]
            }
            try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            guard app.applicationShouldTerminate(NSApp) == .terminateNow else { throw SessionError.invalid("hot exit backup failed") }
            let original = try String(contentsOf: directory.appendingPathComponent("edited.txt"), encoding: .utf8)
            guard original == "original edited.txt" else { throw SessionError.invalid("hot exit wrote the source") }
            print("File hot-exit fixtures saved; source files unchanged.")
        } catch { print("File hot-exit fixture failed: \(error)") }
        NSApp.terminate(nil)
    }
}
