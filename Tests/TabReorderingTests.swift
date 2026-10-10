import AppKit

private final class ReorderingSessionStore: SessionStore {
    var saveCalls = 0
    override func save(notes: [Note], activeID: UUID, windowFrame: NSRect? = nil) throws {
        saveCalls += 1
        try super.save(notes: notes, activeID: activeID, windowFrame: windowFrame)
    }
}

func runTabReorderingTests(root: URL) throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    let app = Textlet()
    let store = try ReorderingSessionStore(directory: root)
    app.store = store
    let notes = ["A", "B", "C"].map { Note(name: $0, text: "\($0) 的正文") }
    app.notes = notes
    app.activeID = notes[1].record.id
    app.buildWindow()
    defer {
        app.tabBar.reordering?.cancel()
        app.saveTimer?.invalidate()
        app.window.delegate = nil
        app.window.close()
        NotificationCenter.default.removeObserver(app)
    }
    try app.selectNote(notes[1].record.id, saveCurrent: false)
    let first = app.tabStack.arrangedSubviews[0] as! NoteTab
    let firstPoint = first.convert(NSPoint(x: 30, y: 16), to: nil)
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
    }
    func tab(_ note: Note) -> NoteTab {
        app.tabStack.arrangedSubviews.first { ($0 as? NoteTab)?.id == note.record.id } as! NoteTab
    }
    func point(_ note: Note, x: CGFloat = 10) -> NSPoint {
        tab(note).convert(NSPoint(x: x, y: 16), to: nil)
    }
    func drag(_ note: Note, to destination: NSPoint) {
        let source = tab(note)
        source.mouseDown(with: mouse(.leftMouseDown, at: point(note, x: 30)))
        source.mouseDragged(with: mouse(.leftMouseDragged, at: destination))
        source.mouseUp(with: mouse(.leftMouseUp, at: destination))
    }
    first.mouseDown(with: mouse(.leftMouseDown, at: firstPoint))
    try expect(app.activeID == notes[1].record.id && app.editor.string == "B 的正文",
               "pressing an inactive tab does not load its content before release")
    first.mouseUp(with: mouse(.leftMouseUp, at: firstPoint))
    try expect(app.activeID == notes[0].record.id && app.editor.string == "A 的正文",
               "a plain click selects the tab on release")

    try app.selectNote(notes[1].record.id)
    app.editor.insertText("!", replacementRange: NSRange(location: app.editor.string.utf16.count, length: 0))
    app.editor.breakUndoCoalescing()
    app.editor.setSelectedRange(NSRange(location: 2, length: 1))
    try expect(app.saveSession(), "reordering fixtures are saved")
    notes[2].storage = nil
    let storage = app.editor.textStorage!
    let originalTabs = app.tabStack.arrangedSubviews
    let third = originalTabs[2] as! NoteTab
    let origin = third.convert(NSPoint(x: 30, y: 16), to: nil)
    let destination = first.convert(NSPoint(x: 10, y: 16), to: nil)
    third.mouseDown(with: mouse(.leftMouseDown, at: origin))
    third.mouseDragged(with: mouse(.leftMouseDragged, at: destination))
    try expect(app.notes.map(\.record.name) == ["A", "B", "C"] && notes[2].storage == nil,
               "drag preview keeps the original order and leaves inactive content unloaded")
    try expect(zip(app.tabStack.arrangedSubviews, originalTabs).allSatisfy { $0 === $1 },
               "drag preview does not rearrange the visible tab controls")
    let beforeCommit = store.saveCalls
    third.mouseUp(with: mouse(.leftMouseUp, at: destination))
    try expect(app.notes.map(\.record.name) == ["C", "A", "B"],
               "releasing an inactive tab before the first tab changes its order")
    try expect(store.saveCalls == beforeCommit + 1, "a changed order commits the session exactly once")
    try expect(app.activeID == notes[1].record.id && app.editor.textStorage === storage
        && app.editor.string == "B 的正文!" && app.editor.selectedRange() == NSRange(location: 2, length: 1)
        && notes[1].undo.canUndo && notes[2].storage == nil,
        "reordering preserves active content, selection, undo, and unloaded buffers")
    let reorderedTabs = app.tabStack.arrangedSubviews
    try expect(reorderedTabs[0] === originalTabs[2] && reorderedTabs[1] === originalTabs[0]
        && reorderedTabs[2] === originalTabs[1], "reordering reuses every tab control")
    let restored = try store.load()!
    try expect(restored.notes.map(\.name) == ["C", "A", "B"] && restored.activeID == notes[1].record.id,
               "the reordered session restores its order and active tab")

    var before = store.saveCalls
    let source = tab(notes[2])
    let start = point(notes[2], x: 30)
    let nearby = point(notes[2], x: 38)
    source.mouseDown(with: mouse(.leftMouseDown, at: start))
    source.mouseDragged(with: mouse(.leftMouseDragged, at: nearby))
    source.mouseDragged(with: mouse(.leftMouseDragged, at: start))
    source.mouseUp(with: mouse(.leftMouseUp, at: start))
    try expect(store.saveCalls == before && app.activeID == notes[1].record.id,
               "dragging back to the original slot neither saves nor selects the dragged tab")
    drag(notes[2], to: point(notes[2], x: 34))
    try expect(store.saveCalls == before && app.activeID == notes[1].record.id,
               "movement of exactly 4pt starts a drag rather than a click")
    drag(notes[2], to: point(notes[2], x: 33))
    try expect(app.activeID == notes[2].record.id && app.editor.string == "C 的正文",
               "movement below 4pt remains a normal click")
    try app.selectNote(notes[1].record.id)
    before = store.saveCalls
    drag(notes[2], to: point(notes[1], x: 150))
    try expect(app.notes.map(\.record.name) == ["A", "B", "C"] && store.saveCalls == before + 1,
               "a rightward drag crosses multiple tabs with one save")
    drag(notes[2], to: point(notes[1]))
    try expect(app.notes.map(\.record.name) == ["A", "C", "B"], "a tab can be inserted between two other tabs")
    try app.selectNote(notes[0].record.id)
    app.nextNote()
    try expect(app.activeID == notes[2].record.id, "next-tab navigation follows the manually changed adjacency")
    app.nextNote()
    app.previousNote()
    try expect(app.activeID == notes[2].record.id, "previous-tab navigation follows the manually changed adjacency")
    try app.selectNote(notes[1].record.id)
    drag(notes[2], to: point(notes[0]))
    let lastFrame = app.tabStack.arrangedSubviews.last!.frame
    let blank = app.tabStack.convert(NSPoint(x: lastFrame.maxX + 20, y: lastFrame.midY), to: nil)
    drag(notes[2], to: blank)
    try expect(app.notes.map(\.record.name) == ["A", "B", "C"], "dropping in trailing strip space moves a tab to the end")
    drag(notes[2], to: point(notes[0]))
    before = store.saveCalls
    drag(notes[2], to: tab(notes[2]).convert(NSPoint(x: 30, y: -50), to: nil))
    try expect(app.notes.map(\.record.name) == ["C", "A", "B"] && store.saveCalls == before,
               "release outside the tab strip cancels without saving")
    let close = source.subviews.compactMap { $0 as? NSButton }.first!
    let closePoint = source.convert(NSPoint(x: close.frame.midX, y: close.frame.midY), to: source.superview)
    try expect(source.hitTest(closePoint) === close, "the close button still receives its own mouse events")

    // Fail a real filesystem commit, rather than mocking the reorder transaction.
    let manifest = store.directory.appendingPathComponent("session.json")
    let manifestBytes = try Data(contentsOf: manifest)
    try FileManager.default.removeItem(at: manifest)
    try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    before = store.saveCalls
    var failed = false
    do { try app.moveNote(notes[1].record.id, to: 0) } catch { failed = true }
    try FileManager.default.removeItem(at: manifest)
    try manifestBytes.write(to: manifest)
    try expect(failed && store.saveCalls == before + 1 && app.notes.map(\.record.name) == ["C", "A", "B"]
        && app.tabStack.arrangedSubviews.map { ($0 as! NoteTab).id } == app.notes.map(\.record.id)
        && app.activeID == notes[1].record.id && app.editor.textStorage === storage && notes[1].undo.canUndo,
        "a failed session write restores the original order without replacing content or controls")
    try expect(app.lastSaveError != nil, "a failed order commit is reported")
    try expect(app.saveSession(), "the session remains writable after a failed order commit")
    let moving = app.tabStack.arrangedSubviews[2] as! NoteTab
    let movingOrigin = moving.convert(NSPoint(x: 30, y: 16), to: nil)
    let leading = (app.tabStack.arrangedSubviews[0] as! NoteTab).convert(NSPoint(x: 10, y: 16), to: nil)
    moving.mouseDown(with: mouse(.leftMouseDown, at: movingOrigin))
    moving.mouseDragged(with: mouse(.leftMouseDragged, at: leading))
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: app.window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    app.window.sendEvent(escape)
    moving.mouseUp(with: mouse(.leftMouseUp, at: leading))
    try expect(app.notes.map(\.record.name) == ["C", "A", "B"] && app.activeID == notes[1].record.id,
               "Escape cancels the gesture even though the editor keeps keyboard focus")

    app.notes.append(contentsOf: (1...8).map { Note(name: "额外\($0)") })
    app.renderTabs(scrollToSelection: false)
    try expect(app.saveSession(), "overflowing tab fixtures are saved")
    let clip = app.tabScroller.contentView
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
    let scrollSource = app.tabStack.arrangedSubviews[0] as! NoteTab
    let scrollOrigin = scrollSource.convert(NSPoint(x: 30, y: 16), to: nil)
    let rightEdge = clip.convert(NSPoint(x: clip.bounds.maxX - 3, y: clip.bounds.midY), to: nil)
    let scrollOrder = app.notes.map(\.record.id)
    scrollSource.mouseDown(with: mouse(.leftMouseDown, at: scrollOrigin))
    scrollSource.mouseDragged(with: mouse(.leftMouseDragged, at: rightEdge))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))
    try expect(clip.bounds.minX > 0 && app.notes.map(\.record.id) == scrollOrder,
               "holding a dragged tab at the right edge scrolls without committing a new order")
    let center = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
    scrollSource.mouseDragged(with: mouse(.leftMouseDragged, at: center))
    let stopped = clip.bounds.minX
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
    try expect(clip.bounds.minX == stopped, "leaving the edge immediately stops automatic scrolling")
    scrollSource.mouseDragged(with: mouse(.leftMouseDragged, at: rightEdge))
    app.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: app.window))
    let cancelled = clip.bounds.minX
    scrollSource.mouseUp(with: mouse(.leftMouseUp, at: rightEdge))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
    try expect(clip.bounds.minX == cancelled && app.notes.map(\.record.id) == scrollOrder,
               "window focus loss cancels sorting and stops the edge timer without restoring the viewport")
    let leftEdge = clip.convert(NSPoint(x: clip.bounds.minX + 3, y: clip.bounds.midY), to: nil)
    let leftSource = tab(notes[1])
    leftSource.mouseDown(with: mouse(.leftMouseDown, at: point(notes[1], x: 30)))
    leftSource.mouseDragged(with: mouse(.leftMouseDragged, at: leftEdge))
    let beforeLeft = clip.bounds.minX
    let trackingDeadline = Date(timeIntervalSinceNow: 0.12)
    while clip.bounds.minX == beforeLeft && Date() < trackingDeadline {
        if !RunLoop.main.run(mode: .eventTracking, before: trackingDeadline) { break }
    }
    try expect(clip.bounds.minX < beforeLeft, "edge scrolling also runs in the event-tracking mode")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    try expect(clip.bounds.minX == 0, "left-edge scrolling stops at the beginning of the strip")
    app.window.sendEvent(escape)
    leftSource.mouseUp(with: mouse(.leftMouseUp, at: leftEdge))
    before = store.saveCalls
    leftSource.mouseDown(with: mouse(.leftMouseDown, at: point(notes[1], x: 30)))
    leftSource.mouseDragged(with: mouse(.leftMouseDragged, at: leftEdge))
    app.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification, object: NSApp))
    leftSource.mouseUp(with: mouse(.leftMouseUp, at: leftEdge))
    try expect(app.notes.map(\.record.id) == scrollOrder && store.saveCalls == before + 1
        && app.activeID == notes[1].record.id && app.editor.textStorage === storage,
        "backgrounding cancels sorting and only performs the existing background session save")

    let pending = tab(notes[2])
    pending.mouseDown(with: mouse(.leftMouseDown, at: point(notes[2], x: 30)))
    pending.mouseDragged(with: mouse(.leftMouseDragged, at: point(notes[1])))
    app.newNote()
    let added = app.active
    pending.mouseUp(with: mouse(.leftMouseUp, at: leading))
    try expect(app.notes.map(\.record.id) == scrollOrder + [added.record.id] && added.record.name == "文本1",
               "new-tab creation cancels the old gesture and appends the new tab")
    try app.removeNote(added.record.id)
    try app.selectNote(notes[1].record.id)

    let fileURL = root.appendingPathComponent("source.txt")
    let fileBytes = Data("来源文件内容\r\n中文🙂".utf8)
    try fileBytes.write(to: fileURL)
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
    let openingSource = tab(notes[1])
    openingSource.mouseDown(with: mouse(.leftMouseDown, at: point(notes[1], x: 30)))
    openingSource.mouseDragged(with: mouse(.leftMouseDragged, at: point(notes[2])))
    let fileOpened = try app.openDocument(fileURL)
    try expect(fileOpened, "the file fixture opens")
    let opened = app.active
    openingSource.mouseUp(with: mouse(.leftMouseUp, at: leading))
    try expect(app.notes.map(\.record.id) == scrollOrder + [opened.record.id],
               "opening a file cancels the old gesture and keeps the file appended")
    try app.selectNote(notes[1].record.id)
    let logURL = root.appendingPathComponent("read-only.log")
    try Data("日志第一行\n第二行\n".utf8).write(to: logURL)
    let log = Note(record: NoteRecord(id: UUID(), name: "只读日志", draftFile: "", selection: 0,
                                     scrollY: 0, logPath: logURL.path, logOffset: 0))
    app.notes.append(log)
    app.renderTabs(scrollToSelection: false)
    try expect(app.saveSession(), "mixed file and log fixtures are saved")
    app.tabStack.scrollToVisible(tab(log).frame)
    before = store.saveCalls
    drag(log, to: point(opened))
    let unchangedFile = try Data(contentsOf: fileURL)
    try expect(app.notes.suffix(2).map(\.record.name) == ["只读日志", "source.txt"] && store.saveCalls == before + 1
        && log.storage == nil && log.logFile == nil && log.logIndex == nil
        && unchangedFile == fileBytes && app.activeID == notes[1].record.id && app.editor.textStorage === storage,
        "file and log tabs share the order without writing the source file or starting a log index")
    let mixedSession = try store.load()!
    try expect(mixedSession.notes.suffix(2).map(\.name) == ["只读日志", "source.txt"]
        && mixedSession.notes.last!.file?.path == DocumentFile.canonical(fileURL).path,
        "mixed tab order restores with its file and log associations")

    try app.moveNote(notes[1].record.id, to: 1)
    try app.removeNote(notes[1].record.id)
    try expect(app.activeID == notes[2].record.id,
               "closing the active tab chooses its left neighbor in the manually changed order")
    print("All tab reordering tests passed.")
}
