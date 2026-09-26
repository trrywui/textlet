import AppKit

private final class WeakProbe {
    weak var value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
}

// Synthetic fixtures only. The identical harness can also be compiled with 0.2 sources.
final class InteractionBenchmark {
    unowned let app: Textlet
    let output: URL
    var timer: Timer?
    var cycling = false
    var activity: NSObjectProtocol?
    let previousApplication = NSWorkspace.shared.frontmostApplication
    var samples: [[String: Any]] = []
    var checks: [String: Bool] = [:]
    var stage = "small-window"
    var search: NSTextField?, replacement: NSTextField?
    private var probes: [WeakProbe] = []
    var original = ""
    var tick = 0
    let began = ProcessInfo.processInfo.systemUptime
    let quick = CommandLine.arguments.contains("--quick-check")
    let baseline = CommandLine.arguments.contains("--baseline")
    let findBoard = NSPasteboard(name: .find)
    var savedFind: [(NSPasteboard.PasteboardType, Data)] = []
    init(app: Textlet, output: URL) { self.app = app; self.output = output }
    func later(_ delay: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body) }
    func action(_ value: NSTextFinder.Action) {
        let item = NSMenuItem(); item.tag = value.rawValue
        app.editor.performFindPanelAction(item)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func sample() {
        var value: [String: Any] = memorySample()
        value["stage"] = stage; value["seconds"] = ProcessInfo.processInfo.systemUptime - began
        value["foreground"] = NSApp.isActive
        value["width"] = app.window.contentView!.bounds.width; value["height"] = app.window.contentView!.bounds.height
        value["scale"] = app.window.backingScaleFactor
        samples.append(value)
    }
    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Textlet isolated performance test")
        savedFind = (findBoard.types ?? []).compactMap { type in findBoard.data(forType: type).map { (type, $0) } }
        let row = "会议记录：待解决 bug 中文🙂 curl --header 'x'\n"
        app.notes = [3, 30, 100].map { Note(name: "测试 \($0)", text: String(repeating: row, count: $0)) }
        app.activeID = app.notes[0].record.id
        try? app.selectNote(app.activeID, saveCurrent: false)
        original = app.editor.string
        print("Interaction PID: \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sample() }
        later(2) { self.checkTabClicks() }
        later(3) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: self.app.window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
            if self.baseline { self.action(.showReplaceInterface) }
            else { self.checks["commandROpensReplace"] = NSApp.mainMenu!.performKeyEquivalent(with: event) }
        }
        later(4) { self.prepareReplace() }
        later(5) { self.singleReplace() }
        later(6) {
            self.app.active.undo.undo()
            self.checks["singleReplaceUndo"] = self.app.editor.string == self.original
        }
        later(7) { self.action(.replaceAll) }
        later(8) {
            self.checks["replaceAll"] = self.app.editor.string == self.original.replacingOccurrences(of: "bug", with: "修复🙂 -- \"ok\"")
            self.app.active.undo.undo()
            self.checks["replaceAllUndo"] = self.app.editor.string == self.original
        }
        later(9) {
            self.app.active.undo.redo()
            self.checks["replaceAllRedo"] = self.app.editor.string == self.original.replacingOccurrences(of: "bug", with: "修复🙂 -- \"ok\"")
            try? self.app.selectNote(self.app.notes[1].record.id)
            self.original = self.app.editor.string
        }
        later(10) { self.action(.replaceAll) }
        later(11) {
            self.checks["replaceAllUsesNewTab"] = self.app.editor.string == self.original.replacingOccurrences(of: "bug", with: "修复🙂 -- \"ok\"")
            self.app.active.undo.undo()
            self.checks["replaceUndoStaysInNewTab"] = self.app.editor.string == self.original
            self.action(.hideFindInterface)
            self.stage = "small-window-cycles"; self.startCycles()
        }
        later(29) {
            self.stage = "large-window-cycles"
            self.app.window.setContentSize(NSSize(width: 1680, height: 946))
            self.app.window.setFrameTopLeftPoint(NSPoint(x: 0, y: NSScreen.main!.frame.maxY - 25))
        }
        later(49) {
            self.cycling = false; self.stage = "large-background-idle"
            if let previous = self.previousApplication, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate(options: [])
            } else { NSApp.deactivate() }
        }
        later(59) {
            self.stage = "small-again-cycles"
            NSApp.activate(ignoringOtherApps: true)
            self.startCycles()
            self.app.window.setContentSize(NSSize(width: 860, height: 590))
        }
        later(79) {
            self.cycling = false; self.stage = "background-idle"
            if let previous = self.previousApplication, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate(options: [])
            } else { NSApp.deactivate() }
        }
        later(89) { self.finish() }
        if quick {
            later(13) { self.cycling = false }
            later(17) { self.finish() }
        }
    }
    func checkTabClicks() {
        guard !baseline else { return }
        let bar = app.tabScroller.superview!
        let blank = NSPoint(x: 700, y: 20)
        func click(_ point: NSPoint, count: Int) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: bar.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
            bar.hitTest(bar.convert(point, to: bar.superview))?.mouseDown(with: event)
        }
        let before = app.notes.count
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 30, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            bar.scrollWheel(with: wheel)
            checks["emptyStripScrollReturns"] = app.notes.count == before
        }
        click(blank, count: 1)
        checks["singleBlankClickDoesNotCreate"] = app.notes.count == before
        click(blank, count: 2)
        checks["doubleBlankClickCreatesOne"] = app.notes.count == before + 1 && app.editor.string.isEmpty && app.editor.isEditable
        click(blank, count: 3)
        checks["tripleClickDoesNotAddAgain"] = app.notes.count == before + 1
        let tab = app.tabStack.arrangedSubviews[0]
        click(bar.convert(NSPoint(x: 25, y: 16), from: tab), count: 2)
        checks["doubleTabClickOnlySelects"] = app.notes.count == before + 1 && app.activeID == app.notes[0].record.id
        let plus = bar.subviews.compactMap { $0 as? NSButton }.first!
        let hit = bar.hitTest(bar.convert(NSPoint(x: plus.frame.midX, y: plus.frame.midY), to: bar.superview))
        checks["plusRemainsClickable"] = hit === plus || hit?.isDescendant(of: plus) == true
        app.notes.removeLast(); app.renderTabs(); _ = app.saveSession()
    }
    func prepareReplace() {
        guard let bar = app.scroller.findBarView else { checks["replaceFieldsVisible"] = false; return }
        let fields = descendants(bar).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        search = fields.first { $0 is NSSearchField }
        replacement = fields.first { !($0 is NSSearchField) }
        checks["replaceFieldsVisible"] = search != nil && replacement != nil && app.scroller.isFindBarVisible
        if !baseline, let replacement {
            app.window.makeFirstResponder(replacement)
            if let editor = replacement.currentEditor() as? NSTextView {
                checks["replacementKeepsLiteralCharacters"] = !editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled && !editor.smartInsertDeleteEnabled
            } else { checks["replacementKeepsLiteralCharacters"] = false }
        }
        if let bar = app.scroller.findBarView {
            let rect = app.ruler.convert(bar.bounds, from: bar)
            checks["rulerStartsBelowFindBar"] = app.ruler.textDrawingRect.minY >= rect.maxY
        }
        set(search, "bug"); set(replacement, "修复🙂 -- \"ok\"")
    }
    func set(_ field: NSTextField?, _ text: String) {
        guard let field else { return }
        app.window.makeFirstResponder(field)
        field.stringValue = text
        field.currentEditor()?.string = text
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        app.window.makeFirstResponder(app.editor)
        if let action = field.action { _ = field.sendAction(action, to: field.target) }
    }
    func singleReplace() {
        app.editor.setSelectedRange((app.editor.string as NSString).range(of: "bug"))
        action(.replace)
        let range = (original as NSString).range(of: "bug")
        checks["singleReplace"] = app.editor.string == (original as NSString).replacingCharacters(in: range, with: "修复🙂 -- \"ok\"")

    }
    func startCycles() {
        cycling = true
        cycleOnce()
    }
    func cycleOnce() {
        guard cycling else { return }
        autoreleasepool {
            app.cycle(1)
            let note = app.active
            let before = app.editor.string
            app.editor.breakUndoCoalescing()
            app.editor.insertText("临时修改🙂", replacementRange: NSRange(location: 0, length: 0))
            app.editor.breakUndoCoalescing()
            note.undo.undo()
            checks["cyclesPreserveText"] = (checks["cyclesPreserveText"] ?? true) && app.editor.string == before
            if tick % 10 == 0 {
                app.newNote()
                let temporary = app.active
                probes.append(WeakProbe(temporary))
                probes.append(WeakProbe(temporary.storage))
                probes.append(WeakProbe(app.tabStack.arrangedSubviews.last))
                app.notes.removeLast()
                try? app.selectNote(app.notes[0].record.id, saveCurrent: false)
            }
            tick += 1
        }
        later(0.1) { self.cycleOnce() }
    }
    func finish() {
        timer?.invalidate(); cycling = false; sample()
        if !quick { checks["atLeast100Cycles"] = tick >= 100 }
        checks["closedObjectsReleased"] = probes.allSatisfy { $0.value == nil }
        if !quick { checks["backgroundActuallyInactive"] = samples.contains { $0["stage"] as? String == "large-background-idle" && $0["foreground"] as? Bool == false } }
        checks["threeTabsRemain"] = app.notes.count == 3 && app.tabStack.arrangedSubviews.count == 3
        checks["sessionSaved"] = app.saveSession()
        let visualEffects = descendants(app.scroller).filter { $0 is NSVisualEffectView && !$0.isHiddenOrHasHiddenAncestor }.map { ["width": $0.bounds.width, "height": $0.bounds.height] }
        let report: [String: Any] = ["checks": checks, "samples": samples, "cycles": tick, "baseline": baseline,
            "pid": ProcessInfo.processInfo.processIdentifier, "visibleEffects": visualEffects,
            "noteBytes": app.notes.reduce(0) { $0 + ($1.storage?.string.utf8.count ?? 0) }]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)

        } catch { print("Report failed: \(error)") }
        NSApp.unhide(nil)
        app.window.makeKeyAndOrderFront(nil)
        action(.showReplaceInterface)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.app.window.contentView?.layoutSubtreeIfNeeded()
            if let view = self.app.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: self.output.appendingPathExtension("view.png"))
            }
            captureTestWindow(app: self.app, to: self.output.appendingPathExtension("window.png"))
            let tabs = self.app.tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.map { tab in
                ["name": tab.label.stringValue, "frame": NSStringFromRect(tab.frame), "labelFrame": NSStringFromRect(tab.label.frame),
                 "visible": NSStringFromRect(tab.label.visibleRect), "hidden": tab.label.isHiddenOrHasHiddenAncestor] as [String: Any]
            }
            try? JSONSerialization.data(withJSONObject: tabs, options: [.prettyPrinted, .sortedKeys]).write(to: self.output.appendingPathExtension("tabs.json"))
            self.action(.hideFindInterface)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                _ = self.app.saveSession()
                let expected = self.app.notes.map { note in
                    ["id": note.record.id.uuidString, "text": note.storage?.string ?? (try? self.app.store.text(for: note.record)) ?? "",
                     "selection": note.record.selection, "name": note.record.name, "scrollY": note.record.scrollY] as [String: Any]
                }
                try? JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
                    .write(to: self.output.deletingPathExtension().appendingPathExtension("expected.json"))
                self.findBoard.clearContents()
                for (type, data) in self.savedFind { self.findBoard.setData(data, forType: type) }
                print("Interaction checks: \(self.checks), cycles: \(self.tick)")
                if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity) }
                NSApp.terminate(nil)
            }
        }
    }
}
