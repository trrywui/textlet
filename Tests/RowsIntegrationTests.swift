#if ROW_RENDERER
import AppKit

func captureRowsLayers(app: Textlet, to output: URL) {
    guard let view = app.window.contentView, let layer = view.layer else { return }
    app.editor.renderRows(); app.window.displayIfNeeded()
    let scale = app.window.backingScaleFactor
    guard let context = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    context.scaleBy(x: scale, y: scale); layer.render(in: context)
    if let image = context.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output) }
}

func runRowsIntegrationCheck(app: Textlet, output: URL) {
    var checks: [String: Bool] = [:]
    var samples: [[String: Any]] = []
    var timing: [Double] = []
    var diagnostics: [String: Any] = [:]
    var stage = "small", editing = false, tick = 0
    let began = ProcessInfo.processInfo.systemUptime
    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Textlet experimental renderer test")
    let sql = Note(name: "query.sql", text: "-- 查询中文🙂\nSELECT id, name FROM users WHERE id > 10;\n")
    let draft = Note(name: "实验草稿", text: "短文本\n中文与英文 English 🙂\n")
    let dense = Note(name: "多行文本", text: (1...180).map { "第 \($0) 行：中文🙂 English 0123456789 " + String(repeating: "abcdefgh 中文 ", count: 10) }.joined(separator: "\n"))
    func later(_ delay: Double, _ action: @escaping () -> Void) {
        let quick = CommandLine.arguments.contains("--quick-check")
        if quick && delay > 0.5 && delay < 39 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick && delay >= 39 ? delay - 38 : delay), execute: action)
    }
    func imagePixels() -> [Data] {
        app.window.displayIfNeeded(); app.editor.renderRows()
        // Data's hash can sample only a prefix (transparent top padding here).
        // Compare every pixel instead of interpreting equal hashes as equal images.
        return app.editor.renderedLineImages.compactMap { image in
            guard let data = image.dataProvider?.data else { return nil }
            return Data(bytes: CFDataGetBytePtr(data), count: CFDataGetLength(data))
        }
    }
    func hasPaint() -> Bool {
        app.editor.renderedLineImages.contains { image in
            guard let data = image.dataProvider?.data else { return false }
            let bytes = data as Data
            return bytes.contains(where: { $0 != 0 })
        }
    }
    func snapshot(_ name: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", String(ProcessInfo.processInfo.processIdentifier)]
        let path = output.appendingPathExtension(name + ".vmmap.txt").path
        FileManager.default.createFile(atPath: path, contents: nil)
        process.standardOutput = FileHandle(forWritingAtPath: path); process.standardError = process.standardOutput
        try? process.run()
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        var value: [String: Any] = memorySample()
        value["stage"] = stage; value["seconds"] = ProcessInfo.processInfo.systemUptime - began
        value["active"] = NSApp.isActive; value["width"] = app.window.contentView!.bounds.width
        value["height"] = app.window.contentView!.bounds.height; value["scale"] = app.window.backingScaleFactor
        value["tiles"] = app.editor.renderedTileCount; value["bitmapBytes"] = app.editor.renderedBitmapBytes
        samples.append(value)
    }
    let edits = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        guard editing else { return }
        let start = ProcessInfo.processInfo.systemUptime
        app.editor.insertText(tick % 2 == 0 ? "A" : "B", replacementRange: NSRange(location: 0, length: 1))
        app.editor.renderRows(); app.window.displayIfNeeded()
        timing.append((ProcessInfo.processInfo.systemUptime - start) * 1000); tick += 1
    }
    later(0.5) {
        app.notes = [draft, sql, dense]; app.activeID = draft.record.id
        try! app.selectNote(draft.record.id, saveCurrent: false)
#if TEXTLET_EXPERIMENTAL
        checks["experimentalApplicationIdentity"] = AppEdition.name == "Textlet 实验版" && AppEdition.sessionDirectory == "Textlet-Rows-Experiment" && Bundle.main.bundleIdentifier == "local.textlet.rows-experiment"
#else
        checks["formalApplicationIdentity"] = AppEdition.name == "Textlet" && AppEdition.sessionDirectory == "Textlet" && Bundle.main.bundleIdentifier == "io.github.trrywui.textlet"
#endif
        checks["windowMatchesEdition"] = app.window.title == AppEdition.name
    }
    later(1) { editing = true }
    later(4) { editing = false; app.window.zoom(nil); stage = "large-resize" }
    later(7) { stage = "large-edit"; editing = true }
    later(13) { snapshot("large-edit") }
    later(15) { editing = false; stage = "large-idle" }
    later(24) { snapshot("large-idle") }
    later(26) { try! app.selectNote(dense.record.id); stage = "dense-load" }
    later(28) { stage = "dense-edit"; editing = true }
    later(34) { editing = false; stage = "dense-scroll" }
    for i in 0..<10 {
        later(34 + Double(i) * 0.25) {
            app.editor.scrollRangeToVisible(NSRange(location: app.editor.textStorage!.length * i / 10, length: 0))
            app.editor.renderRows()
        }
    }
    later(37) { snapshot("dense-scroll") }
    later(39) {
        timer.invalidate(); edits.invalidate()
        checks["visibleTilesBounded"] = app.editor.renderedTileCount < 150 && app.editor.renderedTileCount > 0
        checks["glyphsActuallyPainted"] = hasPaint()
        let offset = app.scroller.contentView.bounds.origin.y
        try! app.selectNote(draft.record.id); try! app.selectNote(dense.record.id)
        checks["scrollRestored"] = abs(app.scroller.contentView.bounds.origin.y - offset) < 2
        try! app.selectNote(sql.record.id)
        app.highlighter.update(); app.editor.renderRows()
        let colored = imagePixels()
        diagnostics["coloredRows"] = app.editor.rowDiagnostics
        diagnostics["coloredRasters"] = app.editor.rowRasterizations
        diagnostics["coloredAttributes"] = String(describing: app.editor.layoutManager!.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil))
        diagnostics["coloredTiles"] = app.editor.renderedTileCount
        captureRowsLayers(app: app, to: output.appendingPathExtension("colored.png"))
        app.highlighter.reset(.plain); app.editor.renderRows()
        let plain = imagePixels()
        diagnostics["plainRows"] = app.editor.rowDiagnostics
        diagnostics["plainRasters"] = app.editor.rowRasterizations
        for (i, image) in app.editor.renderedLineImages.enumerated() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathExtension("plain-tile-\(i).png"))
        }
        checks["plainModeChangesPixels"] = colored != plain
        diagnostics["plainAttributes"] = String(describing: app.editor.layoutManager!.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil))
        captureRowsLayers(app: app, to: output.appendingPathExtension("plain.png"))
        app.highlighter.reset(.sql); app.highlighter.update(); app.editor.renderRows()
        checks["highlightChangesPixels"] = colored == imagePixels()
        app.editor.setSelectedRange(NSRange(location: 0, length: 4)); app.editor.renderRows()
        captureRowsLayers(app: app, to: output.appendingPathExtension("selection.png"))
        if let first = app.editor.renderedLineImages.first {
            try? NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])?.write(to: output.appendingPathExtension("tile.png"))
        }
        app.editor.setSelectedRange(NSRange(location: 0, length: 0))
        app.editor.breakUndoCoalescing()
        let before = app.editor.string
        app.editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        checks["nativeMarkedText"] = app.editor.hasMarkedText()
        app.editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        app.editor.breakUndoCoalescing()
        checks["nativeChineseCommit"] = !app.editor.hasMarkedText() && app.editor.string == "中文" + before
        app.active.undo.undo()
        checks["compositionUndo"] = app.editor.string == before
        app.editor.renderRows()
        // Compare cached output with a fresh raster of the identical TextKit state.
        // Include positions as well as pixels so stale/moved rows cannot pass.
        try! app.selectNote(dense.record.id)
        app.window.setContentSize(NSSize(width: 1680, height: 940))
        app.editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        app.editor.renderRows()
        func compareFresh(_ name: String) {
            let cached = imagePixels(), frames = app.editor.renderedLineFrames
            app.editor.discardRowCache()
            checks["cachePixels-" + name] = cached == imagePixels() && frames == app.editor.renderedLineFrames
        }
        let rasters = app.editor.rowRasterizations
        app.editor.insertText("A", replacementRange: NSRange(location: 0, length: 0))
        app.editor.renderRows()
        checks["headEditReusesUnaffectedRows"] = app.editor.rowRasterizations - rasters < app.editor.renderedTileCount / 2
        compareFresh("head-insert")
        app.editor.insertText("中文🙂\nnew paragraph\r\n", replacementRange: NSRange(location: 0, length: 0))
        compareFresh("multiline-paste")
        let newline = (app.editor.string as NSString).range(of: "\n")
        app.editor.insertText("", replacementRange: newline)
        compareFresh("delete-newline")
        app.editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 5, length: 0))
        compareFresh("marked-text")
        app.editor.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        compareFresh("composition-commit")
        app.editor.breakUndoCoalescing(); app.active.undo.undo()
        compareFresh("undo")
        app.active.undo.redo(); compareFresh("redo")
        app.window.setContentSize(NSSize(width: 1150, height: 750))
        compareFresh("resize-wrap")
        app.scroller.contentView.scroll(to: NSPoint(x: 0, y: 301.5))
        compareFresh("partial-row-scroll")
        app.scroller.contentView.scroll(to: NSPoint(x: 0, y: 1201.5)); app.editor.renderRows()
        app.scroller.contentView.scroll(to: NSPoint(x: 0, y: 301.5))
        compareFresh("scroll-back")
        let storage = app.editor.textStorage!
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: storage.length))
        compareFresh("storage-color")
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular), range: NSRange(location: 0, length: storage.length))
        compareFresh("font-layout")
        let mixed = Note(name: "cache-unicode", text: String(repeating: "中文🙂 e\u{301} office العربية\tEnglish\r\n第二段\u{2028}继续\n", count: 35))
        app.notes.append(mixed); try! app.selectNote(mixed.record.id)
        var random: UInt64 = 42
        for index in 0..<24 {
            random = random &* 6364136223846793005 &+ 1
            let text = app.editor.string as NSString
            let offset = Int(random % UInt64(text.length))
            var range = text.rangeOfComposedCharacterSequence(at: offset)
            if index % 3 == 0 { range.length = 0 }
            let inserts = ["🙂", "\n", "", "ab\r\n中", "\t", "e\u{301}"]
            app.editor.insertText(inserts[index % inserts.count], replacementRange: range)
            app.editor.scrollRangeToVisible(NSRange(location: range.location, length: 0))
            compareFresh("unicode-edit-\(index)")
        }
        app.editor.renderRows()
        let visibleBytes = app.editor.renderedLineImages.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        checks["cacheBudgetBounded"] = app.editor.renderedBitmapBytes <= max(app.editor.rowCacheBudgetBytes, visibleBytes)
        let items = app.editor.touchBar?.itemIdentifiers
        app.editor.updateTextTouchBarItems()
        checks["touchBarItemsPreserved"] = items == app.editor.touchBar?.itemIdentifiers && app.editor.allowsCharacterPickerTouchBarItem
        diagnostics["touchBarItems"] = String(describing: items)
        try! app.selectNote(sql.record.id); app.highlighter.update()
        compareFresh("switch-highlight")
        app.showReplace()
    }
    later(40) {
        captureRowsLayers(app: app, to: output.appendingPathExtension("find.png"))
        checks["nativeFindBar"] = app.scroller.isFindBarVisible
        checks["save"] = app.saveSession()
        let sorted = timing.sorted()
        let result: [String: Any] = ["checks": checks, "diagnostics": diagnostics, "samples": samples, "edits": tick,
             "editP95Milliseconds": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
             "scope": "Own process phys_footprint; layer screenshots and functionality checks after memory samples; no real IME key events"]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Rows checks: \(checks)"); fflush(stdout)
        ProcessInfo.processInfo.endActivity(activity)
        NSApp.terminate(nil)
    }
}
#endif
