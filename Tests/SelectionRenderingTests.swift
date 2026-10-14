import AppKit
import QuartzCore

// Compare cached row pixels with a fresh render after actual AppKit clicks.
// All text and windows belong to this synthetic test session.
func runSelectionRenderingTests(root: URL) throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    struct RowPixels: Equatable {
        let frame: NSRect
        let width: Int
        let height: Int
        let bytes: Data
    }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("test-output/selection-rendering-fixed-2026-10-13", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = Textlet()
    app.store = try SessionStore(directory: root)
    let body = (1...120).map { "合成测试第\($0)行 中文🙂 Sample text for selection rendering." }.joined(separator: "\n")
    let source = Note(name: "选区验证", text: body)
    let other = Note(name: "对照标签", text: "合成对照正文")
    app.notes = [source, other]
    app.activeID = source.record.id
    app.buildWindow()
    let focusWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    focusWindow.isReleasedWhenClosed = false
    defer {
        focusWindow.close()
        app.saveTimer?.invalidate()
        app.window.delegate = nil
        app.window.close()
        NotificationCenter.default.removeObserver(app)
    }
    app.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    try app.selectNote(source.record.id, saveCurrent: false)

    func settle() {
        app.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        app.editor.renderRows()
        CATransaction.flush()
    }
    func rows() throws -> [RowPixels] {
        let images = app.editor.renderedLineImages
        let frames = app.editor.renderedLineFrames
        try expect(!images.isEmpty && images.count == frames.count, "visible row images are available for pixel comparison")
        return try zip(images, frames).map { image, frame in
            guard let data = image.dataProvider?.data else { throw SessionError.invalid("无法读取合成测试行图片") }
            return RowPixels(frame: frame, width: image.width, height: image.height, bytes: data as Data)
        }
    }
    func saveView(_ name: String) throws {
        let rect = app.editor.visibleRect
        let scale = app.window.backingScaleFactor
        let width = Int(ceil(rect.width * scale)), height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let layer = app.editor.layer else { throw SessionError.invalid("无法绘制合成测试视图") }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SessionError.invalid("无法保存合成测试视图")
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
    func clickVisibleText() throws {
        let layout = app.editor.layoutManager!, container = app.editor.textContainer!
        let glyph = app.editor.renderedGlyphRange.location
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = app.editor.convert(NSPoint(x: app.editor.textContainerOrigin.x + rect.minX + 2,
            y: app.editor.textContainerOrigin.y + rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        }
        // NSTextView tracks the release inside mouseDown; provide that event
        // through the test application's own event queue.
        NSApp.postEvent(event(.leftMouseUp), atStart: true)
        app.editor.mouseDown(with: event(.leftMouseDown))
        settle()
        try expect(app.editor.selectedRange().length == 0, "an AppKit click cancels the logical selection")
    }
    let cases = ["warm-cache", "cache-rebuild", "resize", "scroll-new-rows", "focus-change", "inactive-resize", "font-change"]
    var findings: [[String: Any]] = []
    var residueCases: [String] = []
    for name in cases {
        app.window.makeKeyAndOrderFront(nil)
        focusWindow.orderOut(nil)
        app.window.setContentSize(NSSize(width: 860, height: 590))
        try app.selectNote(source.record.id)
        app.editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        app.editor.setSelectedRange(NSRange(location: 0, length: 0))
        app.scroller.contentView.scroll(to: .zero)
        app.editor.discardRowCache()
        settle()
        app.editor.selectAll(nil)
        settle()
        let before = app.editor.rowRasterizations
        switch name {
        case "cache-rebuild": app.editor.discardRowCache()
        case "resize": app.window.setContentSize(NSSize(width: 960, height: 590))
        case "scroll-new-rows":
            app.editor.layoutManager!.ensureLayout(for: app.editor.textContainer!)
            app.scroller.contentView.scroll(to: NSPoint(x: 0, y: 1000))
            app.scroller.reflectScrolledClipView(app.scroller.contentView)
        case "focus-change", "inactive-resize":
            focusWindow.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            if name == "inactive-resize" { app.window.setContentSize(NSSize(width: 960, height: 590)) }
        case "font-change": app.editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        default: break
        }
        settle()
        let generatedWhileSelected = app.editor.rowRasterizations - before
        let selected = try rows()
        try expect(app.editor.selectedRange().length == source.storage!.length
            && app.editor.selectedRanges.first?.rangeValue.length == source.storage!.length,
            "row drawing preserves the real selection exposed to input and copying")
        let selectionLayer = app.editor.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first
        try expect(selectionLayer?.path?.isEmpty == false, "the separate vector layer still displays the selection")
        try saveView(name + "-selected")
        app.window.makeKeyAndOrderFront(nil)
        settle()
        let beforeClick = app.editor.rowRasterizations
        let bytesBeforeClick = app.editor.renderedBitmapBytes
        let tilesBeforeClick = app.editor.cachedTileCount
        try clickVisibleText()
        let cached = try rows()
        let generatedAfterClick = app.editor.rowRasterizations - beforeClick
        let bytesAfterClick = app.editor.renderedBitmapBytes
        try expect(generatedAfterClick == 0 && bytesAfterClick == bytesBeforeClick
            && app.editor.cachedTileCount == tilesBeforeClick,
            "cancelling selection reuses row images without growing the bitmap cache")
        try expect(selectionLayer?.path?.isEmpty == true, "clicking clears the vector selection background")
        try saveView(name + "-clicked-cached")
        // A fresh render uses the SAME text, selection, viewport and focus. Any
        // differing pixels are stale cache state, not a changed document.
        app.editor.discardRowCache()
        settle()
        let fresh = try rows()
        try expect(zip(cached, fresh).allSatisfy { $0.frame == $1.frame && $0.width == $1.width && $0.height == $1.height }
            && cached.count == fresh.count, "cached and fresh rows have matching geometry")
        let differingRows = zip(cached, fresh).filter { $0 != $1 }.count
        let retainedSelection = cached == selected
        try saveView(name + "-clicked-fresh")
        if differingRows > 0 { residueCases.append(name) }
        let finding: [String: Any] = ["case": name, "selectionLengthAfterClick": app.editor.selectedRange().length,
            "rowsRegeneratedWhileSelected": generatedWhileSelected, "rowsRegeneratedAfterClick": generatedAfterClick,
            "cachedRowsDifferFromFresh": differingRows, "cachedRowsEqualSelected": retainedSelection,
            "bitmapBytesAfterClick": bytesAfterClick,
            "bitmapBytesBeforeClick": bytesBeforeClick]
        findings.append(finding)
        print("SELECTION_RENDERING \(String(decoding: try JSONSerialization.data(withJSONObject: finding, options: [.sortedKeys]), as: UTF8.self))")
        if differingRows > 0 {
            try app.selectNote(other.record.id)
            settle()
            try app.selectNote(source.record.id)
            settle()
            let returned = try rows()
            app.editor.discardRowCache()
            settle()
            let returnedFresh = try rows()
            try expect(returned == returnedFresh, "switching away and back clears the stale row pixels")
        }
    }
    try JSONSerialization.data(withJSONObject: findings, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("results.json"))
    try expect(residueCases.isEmpty, "cancelled selection must not remain in cached row images; reproduced cases: \(residueCases.joined(separator: ", "))")

    app.scroller.contentView.scroll(to: .zero)
    app.editor.setSelectedRange(NSRange(location: 0, length: 0))
    settle()
    let plain = try rows()
    let storage = app.editor.textStorage!, layout = app.editor.layoutManager!
    storage.addAttribute(.backgroundColor, value: NSColor.systemPurple, range: NSRange(location: 0, length: 6))
    settle()
    let documentBackground = try rows()
    try expect(documentBackground != plain, "document background attributes remain visible in row images")
    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange, forCharacterRange: NSRange(location: 8, length: 6))
    layout.addTemporaryAttribute(.foregroundColor, value: Theme.keyword, forCharacterRange: NSRange(location: 16, length: 8))
    app.editor.invalidateRows()
    settle()
    let styled = try rows()
    try expect(styled != documentBackground, "temporary background and syntax attributes remain visible")
    app.editor.selectAll(nil)
    app.editor.discardRowCache()
    settle()
    let styledSelected = try rows()
    try expect(styledSelected == styled, "selection cannot alter cached document or temporary colors")
    try clickVisibleText()
    let styledClicked = try rows()
    try expect(styledClicked == styled, "clicking preserves legitimate text backgrounds and syntax colors")

    app.editor.setSelectedRange(NSRange(location: 0, length: 0))
    app.editor.setMarkedText(NSAttributedString(string: "组合🙂", attributes: [
        .underlineStyle: NSUnderlineStyle.single.rawValue, .backgroundColor: NSColor.systemYellow
    ]), selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
    let marked = app.editor.markedRange(), caret = app.editor.selectedRange(), selections = app.editor.selectedRanges
    settle()
    let markedPixels = try rows()
    let markedDiagnostics = app.editor.rowDiagnostics.first ?? ""
    try saveView("marked-cached")
    app.editor.discardRowCache()
    settle()
    let markedFresh = try rows()
    try saveView("marked-fresh")
    let markedState: [String: Any] = ["markedBefore": NSStringFromRange(marked), "markedAfter": NSStringFromRange(app.editor.markedRange()),
        "caretBefore": NSStringFromRange(caret), "caretAfter": NSStringFromRange(app.editor.selectedRange()),
        "hasMarkedText": app.editor.hasMarkedText(), "selectionsPreserved": app.editor.selectedRanges == selections,
        "cachedRowCount": markedPixels.count, "freshRowCount": markedFresh.count,
        "differingRows": zip(markedPixels, markedFresh).filter { $0 != $1 }.count,
        "cachedFirstFrame": markedPixels.first.map { NSStringFromRect($0.frame) } ?? "",
        "freshFirstFrame": markedFresh.first.map { NSStringFromRect($0.frame) } ?? "",
        "cachedFirstAttributes": markedDiagnostics, "freshFirstAttributes": app.editor.rowDiagnostics.first ?? ""]
    print("MARKED_RENDERING \(String(decoding: try JSONSerialization.data(withJSONObject: markedState, options: [.sortedKeys]), as: UTF8.self))")
    try expect(app.editor.hasMarkedText() && app.editor.markedRange() == marked
        && app.editor.selectedRange() == caret && app.editor.selectedRanges == selections && markedPixels == markedFresh,
        "cached drawing preserves marked text, its selection, and its decoration")
    let beforeMarkedRender = app.editor.rowRasterizations
    app.editor.renderRows()
    try expect(app.editor.rowRasterizations - beforeMarkedRender == 1,
        "composition refreshes only its active row and reuses the other visible rows")
    app.editor.insertText("组合🙂", replacementRange: marked)
    settle()
    try expect(!app.editor.hasMarkedText() && app.editor.string.hasPrefix("组合🙂"), "marked text still commits normally after rendering")
    let committed = try rows()
    try saveView("committed-cached")
    app.editor.discardRowCache()
    settle()
    let committedFresh = try rows()
    try saveView("committed-fresh")
    let committedDifferences = zip(committed, committedFresh).enumerated().compactMap { index, pair -> [String: Any]? in
        let (cached, fresh) = pair
        guard cached != fresh else { return nil }
        return ["row": index, "cachedFrame": NSStringFromRect(cached.frame), "freshFrame": NSStringFromRect(fresh.frame),
            "cachedBytes": cached.bytes.count, "freshBytes": fresh.bytes.count,
            "differingBytes": zip(cached.bytes, fresh.bytes).filter { $0 != $1 }.count]
    }
    print("COMMITTED_RENDERING \(String(decoding: try JSONSerialization.data(withJSONObject: committedDifferences, options: [.sortedKeys]), as: UTF8.self))")
    try expect(committed == committedFresh, "committing composition removes transient decoration from cached rows")
    print("All selection rendering tests passed.")
}
