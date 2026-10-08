import AppKit

func runFileSavingTests(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    for sample in ["", "\0\r\n中文🙂e\u{301}", String(repeating: "a", count: 65_535) + "🙂中文\r\n",
                   String(repeating: "中文👩‍💻\0\r\n", count: 20_000)] {
        try expect(DocumentFile.textDigest(sample as NSString) == DocumentFile.digest(Data(sample.utf8)),
            "chunked fingerprint matches existing UTF-8 digest (\(sample.utf16.count) units)")
    }
    var malformedUnits: [unichar] = [0x61, 0xd800, 0x62]
    let malformed = NSString(characters: &malformedUnits, length: malformedUnits.count)
    try expect(DocumentFile.textDigest(malformed) == DocumentFile.digest(Data((malformed as String).utf8)),
        "malformed UTF-16 retains prior fingerprint behavior")
    // Exercise every UTF-16 code unit and surrogate pairs at both chunk edges.
    var allUnits = (0...65535).map { unichar($0) }
    let exhaustive = NSString(characters: &allUnits, length: allUnits.count)
    try expect(DocumentFile.textDigest(exhaustive) == DocumentFile.digest(Data((exhaustive as String).utf8)),
        "fingerprint covers all UTF-16 units including malformed sequences")
    for position in [0, 32766, 32767, 32768, 65535] {
        for suffix: [unichar] in [[0xd83d, 0xde42], [0xd800], [0xdc00], [0xd800, 0xd800, 0xdc00], [0xdc00, 0xd800], [0xd800, 0x61, 0xdc00]] {
            var units = [unichar](repeating: 0x61, count: position) + suffix + [0x62]
            let sample = NSString(characters: &units, length: units.count)
            try expect(DocumentFile.textDigest(sample) == DocumentFile.digest(Data((sample as String).utf8)),
                "fingerprint preserves UTF-16 boundary \(position), \(suffix)")
        }
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

func runFileWatchTests(root: URL) throws {
    let fm = FileManager.default, initialCount = FileWatch.watchedDirectoryCount
    let directory = root.appendingPathComponent("watched")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let a = directory.appendingPathComponent("a.txt"), b = directory.appendingPathComponent("b.txt")
    try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
    var aEvents = 0, bEvents = 0
    var first: FileWatch? = FileWatch(url: a) { aEvents += 1 }
    var second: FileWatch? = FileWatch(url: b) { bEvents += 1 }
    weak var releasedFirst = first, releasedSecond = second
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    func waitUntil(_ condition: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 2)
        while !condition() && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
    try expect(FileWatch.watchedDirectoryCount == initialCount + 1, "same-directory tabs share a directory watcher")
    try Data("unrelated".utf8).write(to: directory.appendingPathComponent("other.txt"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    try expect(aEvents == 0 && bEvents == 0, "unrelated directory changes do not refresh tab state")
    try Data("replacement".utf8).write(to: a, options: .atomic)
    waitUntil { aEvents > 0 }
    try expect(aEvents > 0 && bEvents == 0, "atomic replacement notifies only the affected file")
    var before = aEvents
    let handle = try FileHandle(forWritingTo: a)
    try handle.write(contentsOf: Data("updated".utf8)); try handle.close()
    waitUntil { aEvents > before }
    try expect(aEvents > before, "replacement inode remains watched for subsequent edits")
    before = aEvents
    try fm.moveItem(at: directory, to: root.appendingPathComponent("moved"))
    waitUntil { aEvents > before && bEvents > 0 }
    try expect(aEvents > before && bEvents > 0, "moving a parent directory reports both missing files")
    before = aEvents
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("restored".utf8).write(to: a)
    waitUntil { aEvents > before }
    try expect(aEvents > before, "recreated directory and file resume observation")
    // Move and recreate the same path before events are delivered.
    before = aEvents
    try fm.moveItem(at: directory, to: root.appendingPathComponent("moved-again"))
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("new inode".utf8).write(to: a)
    waitUntil { aEvents > before }
    try expect(aEvents > before, "immediate directory replacement is detected")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    let beforeB = bEvents
    try Data("b returns".utf8).write(to: b)
    waitUntil { bEvents > beforeB }
    try expect(bEvents > beforeB, "all subscribers follow a replaced directory")
    first = nil
    try expect(releasedFirst == nil && FileWatch.watchedDirectoryCount == initialCount + 1,
        "closing one tab releases its watcher and keeps shared observation")
    second = nil
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    try expect(releasedSecond == nil && FileWatch.watchedDirectoryCount == initialCount,
        "closing the final tab releases the shared directory watcher")
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
    try replacingContentsKeepingMtime(destination, with: "SELECT 3;\r\n")
    let end = Date(timeIntervalSinceNow: 2)
    while !note.fileChangedExternally && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    checks["sameMetadataReplacementUpdatesTabWithoutPolling"] = note.fileChangedExternally && note.needsFileSave
    var metadataConflicts = 0
    checks["sameMetadataConflictCanCancel"] = !app.saveNote(note, resolveConflict: { _ in metadataConflicts += 1; return .cancel }) && metadataConflicts == 1
    let metadataExternal = try String(contentsOf: destination, encoding: .utf8)
    checks["sameMetadataCancelPreservesBothVersions"] = metadataExternal == "SELECT 3;\r\n" && app.editor.string == saved
    checks["sameMetadataOverwriteUpdatesBaseline"] = app.saveNote(note, resolveConflict: { _ in .overwrite }) && !note.needsFileSave
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
