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
