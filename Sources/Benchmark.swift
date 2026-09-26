import AppKit

final class Benchmark {
    unowned let app: Textlet
    let output: URL
    var samples: [[String: Any]] = []
    var checks: [String: Bool] = [:]
    var latencies: [Double] = []
    var switchLatencies: [Double] = []
    var stage = "empty-window"
    var sampleTimer: Timer?
    var typingTimer: Timer?
    let startTime = ProcessInfo.processInfo.systemUptime
    var baseline: [UUID: String] = [:]
    var diagnostics: [String: Any] = [:]
    init(app: Textlet, output: URL) { self.app = app; self.output = output }
    func later(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }
    func record() {
        var item: [String: Any] = memorySample()
        item["seconds"] = ProcessInfo.processInfo.systemUptime - startTime
        item["stage"] = stage
        item["foreground"] = NSApp.isActive
        samples.append(item)
    }
    func start() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.record() }
        later(2) { self.loadFixtures() }
        later(3) { self.exercisePaste() }
        later(3.5) { self.checkPasteUndo() }
        later(4) { self.exerciseUndoA() }
        later(4.5) { self.exerciseUndoB() }
        later(5) { self.checkUndoA() }
        later(5.5) { self.checkUndoB() }
        if CommandLine.arguments.contains("--quick-check") {
            later(6) { self.checkScrolling() }
            later(8) { self.finish() }
            return
        }
        later(6) { self.startTyping() }
        later(14) {
            self.typingTimer?.invalidate()
            self.stage = "foreground-idle"
            self.checks["saveAfterEditing"] = self.app.saveSession()
        }
        later(16) { self.checkScrolling() }
        later(18) {
            self.stage = "background-idle"
            NSApp.hide(nil)
        }
        later(30) { self.finish() }
    }
    func loadFixtures() {
        let fixtureLine = "2026-09-25 INFO 会议记录 / 检查 bug：保留 \"quotes\" --flag  两个空格\t制表符 🙂\n"
        let sizes = CommandLine.arguments.contains("--stress") ? Array(repeating: 1200, count: 10) : [3, 30, 100]
        app.notes = sizes.map { Note(name: "测试 · \($0) 行", text: String(repeating: fixtureLine, count: $0)) }
        app.activeID = app.notes[0].record.id
        baseline = Dictionary(uniqueKeysWithValues: app.notes.map { ($0.record.id, $0.storage!.string) })
        do {
            for note in app.notes { try app.selectNote(note.record.id, saveCurrent: false) }
            try app.selectNote(app.notes[0].record.id, saveCurrent: false)
            checks["fixtureSave"] = app.saveSession()
            checks["plainTextAndSubstitutions"] = !app.editor.isRichText && !app.editor.isAutomaticQuoteSubstitutionEnabled
                && !app.editor.isAutomaticDashSubstitutionEnabled && !app.editor.smartInsertDeleteEnabled
                && !app.editor.isAutomaticTextReplacementEnabled && !app.editor.isAutomaticSpellingCorrectionEnabled
                && app.editor.enabledTextCheckingTypes == 0
            stage = "loaded-tabs"
        } catch { checks["fixtureLoad"] = false }
    }
    func insert(_ text: String) {
        let before = ProcessInfo.processInfo.systemUptime
        app.editor.insertText(text, replacementRange: NSRange(location: app.editor.string.utf16.count, length: 0))
        app.editor.layoutManager?.ensureLayout(forBoundingRect: app.editor.visibleRect, in: app.editor.textContainer!)
        app.editor.displayIfNeeded()
        latencies.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
    }
    func exercisePaste() {
        // A private pasteboard keeps the user's real clipboard untouched.
        let board = NSPasteboard.withUniqueName()
        board.declareTypes([.string, .rtf], owner: nil)
        let literal = "\"ASCII\" --dash  \t中文🙂\u{00a0}\n"
        board.setString(literal, forType: .string)
        board.setString("{\\rtf1\\ansi\\b bold text}", forType: .rtf)
        app.editor.setSelectedRange(NSRange(location: app.editor.string.utf16.count, length: 0))
        app.editor.pastePlainText(from: board)
        app.editor.breakUndoCoalescing()
        checks["pastePreservesLiteralCharacters"] = app.editor.string == baseline[app.activeID]! + literal
        checks["pasteRemainsPlainText"] = !app.editor.isRichText
        board.releaseGlobally()
    }
    func checkPasteUndo() {
        app.active.undo.undo()
        checks["pasteUndo"] = app.editor.string == baseline[app.activeID]
    }
    func exerciseUndoA() {
        try? app.selectNote(app.notes[0].record.id)
        insert("A: \"ascii\" --flag  \t中文📝\n")
        app.editor.breakUndoCoalescing()
    }
    func exerciseUndoB() {
        try? app.selectNote(app.notes[1].record.id)
        insert("B: curl --header 'Content-Type: application/json'\n")
        app.editor.breakUndoCoalescing()
    }
    func checkUndoA() {
        try? app.selectNote(app.notes[0].record.id)
        let note = app.active
        checks["undoAvailableA"] = note.undo.canUndo
        note.undo.undo()
        checks["undoIsolatedA"] = app.editor.string == baseline[note.record.id]
    }
    func checkUndoB() {
        try? app.selectNote(app.notes[1].record.id)
        let note = app.active
        checks["otherTabStillEdited"] = app.editor.string.hasSuffix("B: curl --header 'Content-Type: application/json'\n")
        note.undo.undo()
        checks["undoIsolatedB"] = app.editor.string == baseline[note.record.id]
        note.undo.redo()
        checks["redoIsolatedB"] = app.editor.string.hasSuffix("B: curl --header 'Content-Type: application/json'\n")
        note.undo.undo()
    }
    func startTyping() {
        stage = "foreground-editing"
        var tick = 0
        typingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if tick % 10 == 0 {
                let start = ProcessInfo.processInfo.systemUptime
                self.app.cycle(1)
                self.switchLatencies.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            self.insert("修改 \(tick)：\"--keep\"  🙂\n")
            tick += 1
        }
    }
    func checkScrolling() {
        do {
            let target = app.notes.last!.record.id
            try app.selectNote(target)
            app.editor.scrollRangeToVisible(NSRange(location: app.editor.string.utf16.count / 2, length: 0))
            let offset = app.scroller.contentView.bounds.origin.y
            checks["longTextCanScroll"] = offset > 0 && app.editor.bounds.height > app.scroller.contentSize.height
            try app.selectNote(app.notes[0].record.id)
            try app.selectNote(target)
            diagnostics["scrollBeforeSwitch"] = offset
            diagnostics["scrollAfterSwitch"] = app.scroller.contentView.bounds.origin.y
            diagnostics["scrollSavedRecord"] = app.active.record.scrollY
            diagnostics["documentHeight"] = app.editor.bounds.height
            checks["scrollRestoresAcrossTabs"] = abs(app.scroller.contentView.bounds.origin.y - offset) < 2
        } catch { checks["scrollRestoresAcrossTabs"] = false }
    }
    func finish() {
        sampleTimer?.invalidate()
        typingTimer?.invalidate()
        checks["finalSave"] = app.saveSession()
        let expected = app.notes.map { note -> [String: Any] in
            ["id": note.record.id.uuidString, "text": note.storage?.string ?? (try? app.store.text(for: note.record)) ?? "",
             "selection": note.record.selection, "name": note.record.name, "scrollY": note.record.scrollY]
        }
        let sorted = latencies.sorted()
        let report: [String: Any] = [
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": "x86_64", "pid": ProcessInfo.processInfo.processIdentifier,
            "measurement": "task_info TASK_VM_INFO.phys_footprint; MiB; own process only",
            "input": "programmatic NSTextView.insertText; includes Chinese and emoji, NOT real IME keystrokes",
            "checks": checks, "samples": samples, "diagnostics": diagnostics,
            "editP95Milliseconds": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "editMaxMilliseconds": (sorted.last ?? 0.0) as Double,
            "switchMaxMilliseconds": (switchLatencies.max() ?? 0.0) as Double,
            "textBytes": expected.reduce(0) { $0 + ($1["text"] as! String).utf8.count }
        ]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.deletingPathExtension().appendingPathExtension("expected.json"), options: .atomic)
            // Capture only our own fixture view, after all memory samples have finished.
            if let view = app.window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: output.deletingPathExtension().appendingPathExtension("png"))
            }
            print("Benchmark report: \(output.path)")
            print("Checks: \(checks)")
            fflush(stdout)
        } catch { print("Benchmark write failed: \(error)") }
        NSApp.terminate(nil)
    }
}

func checkRestoredUI(app: Textlet, expectedURL: URL) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        do {
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as! [[String: Any]]
            var correct = expected.count == app.notes.count
            var details: [[String: Any]] = []
            for entry in expected {
                let id = UUID(uuidString: entry["id"] as! String)!
                try app.selectNote(id)
                correct = correct && app.editor.string == entry["text"] as! String
                correct = correct && app.active.record.name == entry["name"] as! String
                correct = correct && app.editor.selectedRange().location == entry["selection"] as! Int
                if let offset = entry["scrollY"] as? Double {
                    correct = correct && abs(app.scroller.contentView.bounds.origin.y - offset) < 2
                }
                details.append(["name": app.active.record.name,
                                "textMatches": app.editor.string == entry["text"] as! String,
                                "selectionExpected": entry["selection"]!, "selectionActual": app.editor.selectedRange().location,
                                "scrollExpected": entry["scrollY"] ?? 0, "scrollActual": app.scroller.contentView.bounds.origin.y])
            }
            let report: [String: Any] = ["restorePassed": correct, "tabCount": app.notes.count,
                                         "memory": memorySample(), "details": details]
            let destination = expectedURL.deletingPathExtension().appendingPathExtension("restore.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
            print("UI restoration: \(correct); \(destination.path)")
            fflush(stdout)
        } catch { print("UI restoration failed: \(error)") }
        NSApp.terminate(nil)
    }
}
