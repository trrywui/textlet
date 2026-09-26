import AppKit

final class FeatureBenchmark {
    unowned let app: Textlet
    let output: URL, fixture: URL
    var checks: [String: Bool] = [:]
    var timings: [String: Double] = [:]
    var samples: [[String: Any]] = []
    var timer: Timer?
    var stage = "small-notes"
    var finished = false
    let began = ProcessInfo.processInfo.systemUptime
    var lastTick = ProcessInfo.processInfo.systemUptime
    var tickGapMax = 0.0
    let literal = #"{"id":123456789012345678901234567890,"msg":"中文🙂","list":[1,true,null]}"#
    var original = ""
    var indexStarted = 0.0
    var jsonNote: UUID!
    init(app: Textlet, output: URL, fixture: URL) { self.app = app; self.output = output; self.fixture = fixture }
    func later(_ delay: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) }
    func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        tickGapMax = max(tickGapMax, now - lastTick); lastTick = now
        var data: [String: Any] = memorySample()
        data["seconds"] = now - began; data["stage"] = stage; data["foreground"] = NSApp.isActive
        samples.append(data)
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
        original = "会议记录：待办\n" + literal + "\n保持 --flag  和 \"引号\"\n"
        app.notes = [Note(name: "会议记录", text: original),
                     Note(name: "待办 · 30 行", text: String(repeating: "排查 bug：保留 --flag  两个空格 中文🙂\n", count: 30)),
                     Note(name: "脚本 · 100 行", text: String(repeating: "curl --header 'Content-Type: application/json'\n", count: 100))]
        jsonNote = app.notes[0].record.id
        app.activeID = jsonNote
        try? app.selectNote(jsonNote, saveCurrent: false)
        later(1) { self.format() }
        later(2) { self.undo() }
        later(3) { self.openLog() }
        later(90) { if !self.finished { self.checks["completedWithin90Seconds"] = false; self.finish() } }
    }
    func format() {
        let range = (app.editor.string as NSString).range(of: literal)
        app.editor.setSelectedRange(range)
        let before = ProcessInfo.processInfo.systemUptime
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                    windowNumber: app.window.windowNumber, context: nil, characters: "J",
                                    charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        checks["commandShiftJHandled"] = NSApp.mainMenu!.performKeyEquivalent(with: event)
        timings["jsonFormatMs"] = (ProcessInfo.processInfo.systemUptime - before) * 1000
        checks["selectedJSONFormatted"] = app.editor.string.contains("  \"id\": 123456789012345678901234567890")
        checks["surroundingTextPreserved"] = app.editor.string.hasPrefix("会议记录：待办\n") && app.editor.string.hasSuffix("\n保持 --flag  和 \"引号\"\n")
        checks["rulerVisible"] = !app.ruler.isHidden && app.ruler.window != nil && app.ruler.ruleThickness > 0
    }
    func undo() {
        app.active.undo.undo()
        checks["formatUndoOneStep"] = app.editor.string == original
        app.active.undo.redo()
        checks["formatRedo"] = app.editor.string != original && app.editor.string.contains("  \"id\"")
        app.editor.setSelectedRange(NSRange(location: 0, length: 0))
        let before = app.editor.string
        do { try app.applyJSONFormat(); checks["invalidJSONRejected"] = false }
        catch { checks["invalidJSONRejected"] = app.editor.string == before }
        _ = app.saveSession()
    }
    func openLog() {
        app.showReplace()
        stage = "index-log"; indexStarted = ProcessInfo.processInfo.systemUptime
        app.logViewer.onReady = { [weak self] in self?.indexed() }
        app.openText(fixture)
    }
    func indexed() {
        app.logViewer.onReady = nil
        timings["indexSeconds"] = ProcessInfo.processInfo.systemUptime - indexStarted
        checks["automaticLargeFileMode"] = app.active.isLog && !app.editor.isEditable && !app.editor.allowsUndo
        let replaceItem = NSMenuItem(title: "替换", action: #selector(Textlet.showReplace), keyEquivalent: "r")
        checks["readOnlyReplaceDisabled"] = !app.validateMenuItem(replaceItem) && !app.scroller.isFindBarVisible
        app.showReplace()
        checks["readOnlyReplaceStaysClosed"] = !app.scroller.isFindBarVisible
        checks["pageBounded"] = app.editor.string.utf8.count <= LogFile.pageSize + 1
        checks["lineIndexReady"] = (app.logViewer.index?.lines ?? 0) > 100000
        stage = "page-navigation"
        later(0.5) {
            self.measure("middlePageMs") { self.app.logViewer.move(to: self.app.logViewer.file!.size / 2) }
            self.checks["middleAbsoluteLines"] = self.app.ruler.firstLine > 100000
        }
        later(1) {
            let before = self.app.logViewer.page!.end
            self.measure("nextPageMs") { self.app.logViewer.next() }
            self.checks["nextPageNoGap"] = self.app.logViewer.page!.start == before
        }
        later(1.5) {
            self.measure("tailPageMs") { self.app.logViewer.last() }
            self.checks["tailReachesEOF"] = self.app.logViewer.page!.end == self.app.logViewer.file!.size
        }
        later(2) {
            self.app.logViewer.first()
            self.searchMissing()
        }
    }
    func measure(_ name: String, _ body: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        body(); app.editor.displayIfNeeded(); app.ruler.displayIfNeeded()
        timings[name] = (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
    func searchMissing() {
        stage = "full-file-search"
        let started = ProcessInfo.processInfo.systemUptime
        app.logViewer.searchField.stringValue = "TEXTLET_NO_SUCH_TOKEN_0823"
        app.logViewer.onSearchFinished = { [weak self] match in
            guard let self else { return }
            self.checks["fullSearchMissing"] = match == nil
            self.timings["fullSearchSeconds"] = ProcessInfo.processInfo.systemUptime - started
            self.app.logViewer.onSearchFinished = nil
            self.later(0.5) { self.searchTail() }
        }
        app.logViewer.findNext()
    }
    func searchTail() {
        app.logViewer.searchField.stringValue = "TEXTLET_NEAR_END 中文🙂"
        app.logViewer.onSearchFinished = { [weak self] match in
            guard let self else { return }
            let selected = (self.app.editor.string as NSString).substring(with: self.app.editor.selectedRange())
            self.checks["fullSearchFindsTail"] = (match ?? 0) > self.app.logViewer.file!.size * 9 / 10
            self.checks["searchSelectsUTF8Match"] = selected == "TEXTLET_NEAR_END 中文🙂"
            self.app.logViewer.onSearchFinished = nil
            self.later(0.5) { self.switchTabs() }
        }
        app.logViewer.findNext()
    }
    func switchTabs() {
        let id = app.activeID!, offset = app.logViewer.page!.start
        let scroll = app.scroller.contentView.bounds.origin.y
        measure("logToNoteMs") { try? app.selectNote(jsonNote) }
        checks["noteEditableAgain"] = app.editor.isEditable && app.editor.allowsUndo && app.ruler.firstLine == 1
        checks["draftSurvivesLogSwitch"] = app.editor.string.contains("123456789012345678901234567890")
        measure("noteToCachedLogMs") { try? app.selectNote(id) }
        checks["cachedLogRestored"] = app.logViewer.page?.start == offset && abs(app.scroller.contentView.bounds.origin.y - scroll) < 2
        checks["logHasNoDraftBuffer"] = app.active.storage == nil && app.active.record.draftFile.isEmpty
        stage = "background-idle"
        NSApp.hide(nil)
        later(5) { self.finish() }
    }
    func finish() {
        guard !finished else { return }; finished = true
        timer?.invalidate(); sample()
        checks["savedSession"] = app.saveSession()
        do {
            let expected: [String: Any] = ["activeID": app.activeID.uuidString, "offset": app.active.record.logOffset ?? 0,
                "scrollY": app.active.record.scrollY, "firstLine": app.logViewer.page?.firstLine ?? 0,
                "notes": app.notes.filter { !$0.isLog }.map { ["id": $0.record.id.uuidString,
                    "text": $0.storage?.string ?? (try? app.store.text(for: $0.record)) ?? ""] }]
            let report: [String: Any] = ["checks": checks, "timings": timings, "samples": samples,
                "fileBytes": app.logViewer.file?.size ?? 0, "pageBytes": app.editor.string.utf8.count,
                "indexEntries": app.logViewer.index?.points.count ?? 0, "maximumMainRunLoopIntervalMs": tickGapMax * 1000]
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.deletingPathExtension().appendingPathExtension("expected.json"))
            func tree(_ view: NSView, _ indent: String = "") -> String {
                indent + "\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect) hidden=\(view.isHiddenOrHasHiddenAncestor) layer=\(view.wantsLayer)\n" + view.subviews.map { tree($0, indent + "  ") }.joined()
            }
            try tree(app.window.contentView!).write(to: output.deletingPathExtension().appendingPathExtension("views.txt"), atomically: true, encoding: .utf8)
            NSApp.unhide(nil)
            app.window.makeKeyAndOrderFront(nil)
            later(0.5) {
                if let view = self.app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: self.output.deletingPathExtension().appendingPathExtension("png"))
                }
                captureTestWindow(app: self.app, to: self.output.deletingPathExtension().appendingPathExtension("window.png"))
                NSApp.terminate(nil)
            }
            print("Feature checks: \(checks). Timings: \(timings)")
        } catch { fputs("Feature report failed: \(error)\n", stderr) }
    }
}

func checkFeatureRestore(app: Textlet, path: String) {
    let started = ProcessInfo.processInfo.systemUptime
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        guard !app.logViewer.loading || ProcessInfo.processInfo.systemUptime - started > 60 else { return }
        timer?.invalidate()
        do {
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
            var checks: [String: Bool] = [:]
            checks["activeLogRestored"] = app.activeID.uuidString == expected["activeID"] as? String && app.active.isLog
            checks["bytePositionRestored"] = app.logViewer.page?.start == (expected["offset"] as? NSNumber)?.int64Value
            checks["lineNumberRestored"] = app.ruler.firstLine == expected["firstLine"] as? Int
            checks["viewportRestored"] = abs(app.scroller.contentView.bounds.origin.y - (expected["scrollY"] as! Double)) < 2
            for note in expected["notes"] as! [[String: String]] {
                if let actual = app.notes.first(where: { $0.record.id.uuidString == note["id"] }) {
                    checks["note-\(actual.record.id)"] = try app.store.text(for: actual.record) == note["text"]
                } else { checks["missingNote"] = false }
            }
            let report: [String: Any] = ["checks": checks, "memory": memorySample(), "seconds": ProcessInfo.processInfo.systemUptime - started]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("restore.json"))
            print("Feature restore: \(checks)")
        } catch { fputs("Restore failed: \(error)\n", stderr) }
        captureTestWindow(app: app, to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("window.png"))
        NSApp.terminate(nil)
    }
}

func captureTestWindow(app: Textlet, to url: URL) {
    // Only this synthetic fixture window; never capture the desktop or other apps.
    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(app.window.windowNumber), .boundsIgnoreFraming) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
