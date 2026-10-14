import AppKit

func runTabSelectionTests(root: URL) throws {
    _ = NSApplication.shared
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    func bitmap() throws -> NSBitmapImageRep {
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw SessionError.invalid("无法创建标签测试位图")
        }
        return image
    }
    func draw(_ tab: NoteTab, into image: NSBitmapImageRep, clear: Bool = false, rect: NSRect? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        if clear { Theme.chrome.setFill(); tab.bounds.fill() }
        if let rect { NSBezierPath(rect: rect).addClip() }
        tab.draw(rect ?? tab.bounds)
    }
    func matches(_ image: NSBitmapImageRep, x: Int, y: Int, _ expected: NSColor) -> Bool {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              let reference = expected.usingColorSpace(.sRGB) else { return false }
        return abs(color.redComponent - reference.redComponent) < 0.02
            && abs(color.greenComponent - reference.greenComponent) < 0.02
            && abs(color.blueComponent - reference.blueComponent) < 0.02
            && color.alphaComponent > 0.99
    }

    let names = ["A", "B", "C"]
    let contents = names.map { "\($0) 的正文" }
    let notes = zip(names, contents).map { Note(name: $0, text: $1) }
    let tabs = notes.map { NoteTab(note: $0) }
    let images = try tabs.map { _ in try bitmap() }
    for (tab, image) in zip(tabs, images) { draw(tab, into: image, clear: true) }

    // 模拟滚动视图复用绘图缓存；取消选中时必须自行清除旧高亮。
    for selected in [1, 2, 0, 2, 1] {
        for index in tabs.indices {
            tabs[index].selected = index == selected
            draw(tabs[index], into: images[index])
        }
        try expect(tabs.indices.allSatisfy { index in
            matches(images[index], x: 6, y: 16, index == selected ? Theme.canvas : Theme.chrome)
        }, "switching to \(notes[selected].record.name) repaints exactly one tab background")
        try expect(tabs.indices.allSatisfy { index in
            // 位图从顶部开始计数，下划线位于视图底部。
            matches(images[index], x: 80, y: 31, index == selected ? Theme.accent : Theme.chrome)
        }, "switching to \(notes[selected].record.name) clears every old tab underline")
    }

    tabs[1].selected = true
    draw(tabs[1], into: images[1])
    tabs[1].selected = false
    draw(tabs[1], into: images[1], rect: NSRect(x: 0, y: 0, width: 160, height: 3))
    try expect(matches(images[1], x: 80, y: 31, Theme.chrome), "partial repaint erases a deselected tab underline")

    let app = Textlet()
    app.store = try SessionStore(directory: root)
    app.notes = notes
    app.activeID = notes[1].record.id
    app.buildWindow()
    defer {
        app.saveTimer?.invalidate()
        app.window.delegate = nil
        app.window.close()
        NotificationCenter.default.removeObserver(app)
    }
    try app.selectNote(notes[1].record.id, saveCurrent: false)
    let originalTabs = app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }
    for index in [2, 0, 1, 2, 1] {
        let target = originalTabs.first { $0.id == notes[index].record.id }!
        target.onSelect?()
        let currentTabs = app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }
        try expect(app.activeID == target.id && app.editor.string == contents[index]
            && currentTabs.filter(\.selected).map(\.id) == [target.id],
            "clicking \(notes[index].record.name) keeps content and tab selection in sync")
        try expect(currentTabs.allSatisfy { $0.label.textColor == ($0.selected ? Theme.text : Theme.muted) },
            "clicking \(notes[index].record.name) updates every tab title color")
        try expect(currentTabs.count == originalTabs.count && zip(currentTabs, originalTabs).allSatisfy { $0 === $1 },
            "switching to \(notes[index].record.name) reuses all tab controls")
    }
    print("All tab selection tests passed.")
}

func runTabSelectionBoundaryTests(root: URL) throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    let app = Textlet()
    app.store = try SessionStore(directory: root)
    let body = String(repeating: "长正文 中文🙂，用于验证标签切换的选区边界。\n", count: 240)
    let long = Note(name: "文本1", text: body)
    let short = Note(name: "文本2", text: "中🙂文")
    let empty = Note(name: "文本3")
    app.notes = [long, short, empty]
    app.activeID = long.record.id
    app.buildWindow()
    defer {
        app.saveTimer?.invalidate()
        app.window.delegate = nil
        app.window.close()
        NotificationCenter.default.removeObserver(app)
    }
    // Use a key window and real tab gestures, including the font update path
    // that was absent from the equal-length, non-key-window selection fixtures.
    app.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    app.window.contentView?.layoutSubtreeIfNeeded()
    try app.selectNote(long.record.id, saveCurrent: false)
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: app.window.windowNumber, context: nil, eventNumber: 1,
            clickCount: clicks, pressure: 0)!
    }
    func click(_ note: Note) {
        let tab = app.tabStack.arrangedSubviews.first { ($0 as? NoteTab)?.id == note.record.id }!
        let point = tab.convert(NSPoint(x: 30, y: 16), to: nil)
        tab.mouseDown(with: mouse(.leftMouseDown, at: point))
        tab.mouseUp(with: mouse(.leftMouseUp, at: point))
    }
    func consistent(_ note: Note, text: String, caret: Int) -> Bool {
        app.active === note && app.editor.string == text && !app.switching
            && app.editor.selectedRange() == NSRange(location: caret, length: 0)
            && app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.filter(\.selected).map(\.id) == [note.record.id]
    }
    let end = body.utf16.count
    app.editor.setSelectedRange(NSRange(location: end, length: 0))
    let blankPoint = app.tabBar.convert(NSPoint(x: 10, y: 2), to: nil)
    app.tabBar.mouseDown(with: mouse(.leftMouseDown, at: blankPoint, clicks: 2))
    let created = app.active
    try expect(app.notes.count == 4 && created !== long && consistent(created, text: "", caret: 0),
        "double-clicking the empty strip from a long document's end creates a consistent empty tab")
    try expect(long.record.selection == end, "new-tab selection reset preserves the old caret")

    for target in [short, empty] {
        try app.selectNote(long.record.id)
        app.editor.setSelectedRange(NSRange(location: end - 12, length: 12))
        click(target)
        try expect(consistent(target, text: target === short ? "中🙂文" : "", caret: 0),
            "mouse switching from a trailing selection to \(target.record.name) finishes with a valid caret")
        try expect(long.record.selection == end - 12, "temporary selection reset does not overwrite the old selection location")
    }

    short.record.selection = Int.max
    try app.selectNote(long.record.id)
    click(short)
    try expect(consistent(short, text: "中🙂文", caret: 4), "restored caret clamps to the UTF-16 length including emoji")
    try app.selectNote(long.record.id)
    short.record.selection = -8
    click(short)
    try expect(consistent(short, text: "中🙂文", caret: 0), "negative restored caret clamps to zero")

    long.undo.groupsByEvent = false
    try app.selectNote(long.record.id)
    long.undo.beginUndoGrouping()
    app.editor.insertText("追加🙂", replacementRange: NSRange(location: end, length: 0))
    app.editor.breakUndoCoalescing()
    long.undo.endUndoGrouping()
    let editedBody = body + "追加🙂"
    app.editor.scrollRangeToVisible(NSRange(location: editedBody.utf16.count, length: 0))
    let savedScroll = Double(max(0, app.scroller.contentView.bounds.origin.y + app.scroller.contentView.contentInsets.top))
    let savedCaret = app.editor.selectedRange().location
    click(empty)
    try expect(long.undo.canUndo && long.record.selection == savedCaret && long.record.scrollY == savedScroll,
        "switching preserves undo history, caret, and the old viewport")
    click(long)
    try expect(consistent(long, text: editedBody, caret: savedCaret)
        && abs(Double(app.scroller.contentView.bounds.origin.y + app.scroller.contentView.contentInsets.top) - savedScroll) < 1,
        "switching back restores the caret and viewport")
    long.undo.undo()
    try expect(app.editor.string == body && empty.storage?.string == "" && short.storage?.string == "中🙂文",
        "undo after switching affects only the edited tab")

    try expect(app.saveSession(), "boundary fixtures save before entering the background")
    app.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
    try expect(short.storage == nil && empty.storage == nil, "backgrounding releases inactive buffers without undo history")
    app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    app.editor.setSelectedRange(NSRange(location: end - 12, length: 12))
    click(short)
    try expect(consistent(short, text: "中🙂文", caret: 0), "activation followed by a click reloads the shorter inactive body safely")
    for target in [empty, long, created, short, long, empty] {
        click(target)
        try expect(app.active === target && !app.switching
            && app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.filter(\.selected).map(\.id) == [target.record.id],
            "successive mouse clicks keep the editor and selected tab in sync")
    }

    click(long)
    app.editor.setSelectedRange(NSRange(location: 2, length: 3))
    let missing = Note(record: NoteRecord(id: UUID(), name: "缺失正文", draftFile: "missing.txt", selection: 0, scrollY: 0))
    app.notes.append(missing)
    let oldRange = app.editor.selectedRange()
    var rejected = false
    do { try app.selectNote(missing.record.id, saveCurrent: false) }
    catch { rejected = true }
    try expect(rejected && app.active === long && app.editor.string == body
        && !app.switching && app.editor.selectedRange() == oldRange,
        "a failed target-body load leaves the current editor and switching state intact")
    app.notes.removeAll { $0 === missing }
    print("All tab selection boundary tests passed.")
}
