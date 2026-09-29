import AppKit

// The identical workload runs in both complete application builds. No screenshots,
// imports or real sessions are involved; main.swift requires a fresh test directory.
func runRenderingComparison(app: Textlet, output: URL) {
    let probe = RenderingComparison(app: app, output: output)
    probe.start()
}

private final class RenderingComparison {
    unowned let app: Textlet
    let output: URL
    let began = ProcessInfo.processInfo.systemUptime
    let shortText = "短文本\n中文与英文 English 🙂\n"
    let denseText = (1...180).map { "第 \($0) 行：中文🙂 English 0123456789 " + String(repeating: "abcdefgh 中文 ", count: 10) }.joined(separator: "\n")
    var stage = "setup"
    var samples: [[String: Any]] = []
    var timings: [String: [Double]] = [:]
    var operations: [String: Int] = [:]
    var events: [[String: Any]] = []
    var timer: Timer?
    var short: Note!, dense: Note!
    var activity: NSObjectProtocol?
    init(app: Textlet, output: URL) { self.app = app; self.output = output }
    func later(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func changeStage(_ name: String) {
        stage = name
        events.append(["stage": name, "seconds": ProcessInfo.processInfo.systemUptime - began])
    }
    func display() {
        var visible = app.editor.visibleRect
        visible.origin.x -= app.editor.textContainerOrigin.x
        visible.origin.y -= app.editor.textContainerOrigin.y
        app.editor.layoutManager!.ensureLayout(forBoundingRect: visible, in: app.editor.textContainer!)
#if ROW_RENDERER
        app.editor.renderRows()
#endif
        app.editor.displayIfNeeded()
        app.window.displayIfNeeded()
    }
    func sample() {
        var sample: [String: Any] = memorySample()
        sample["stage"] = stage
        sample["seconds"] = ProcessInfo.processInfo.systemUptime - began
        sample["active"] = NSApp.isActive
        sample["keyWindow"] = app.window.isKeyWindow
        sample["width"] = app.window.contentView!.bounds.width
        sample["height"] = app.window.contentView!.bounds.height
        sample["scale"] = app.window.backingScaleFactor
        sample["textUTF16Length"] = app.editor.textStorage!.length
        sample["font"] = app.editor.font?.fontName ?? ""
        sample["fontSize"] = app.editor.font?.pointSize ?? 0
#if ROW_RENDERER
        sample["tiles"] = app.editor.renderedTileCount
        sample["bitmapBytes"] = app.editor.renderedBitmapBytes
#endif
        samples.append(sample)
    }
    func snapshot() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", String(ProcessInfo.processInfo.processIdentifier)]
        let path = output.appendingPathExtension(stage + ".vmmap.txt").path
        FileManager.default.createFile(atPath: path, contents: nil)
        process.standardOutput = FileHandle(forWritingAtPath: path)
        process.standardError = process.standardOutput
        try? process.run()
    }
    // Fixed operation counts, spaced 150ms apart after completion. A slower frame
    // lengthens the stage instead of silently dropping edits from one condition.
    func edit(_ remaining: Int, then completion: @escaping () -> Void) {
        guard remaining > 0 else { completion(); return }
        let started = ProcessInfo.processInfo.systemUptime
        app.editor.insertText(remaining % 2 == 0 ? "A" : "B", replacementRange: NSRange(location: 0, length: 1))
        display()
        timings[stage, default: []].append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        operations[stage, default: 0] += 1
        later(0.15) { self.edit(remaining - 1, then: completion) }
    }
    func scroll(_ index: Int) {
        guard index < 20 else {
            snapshot()
            changeStage("dense-idle")
            later(11) { self.snapshot(); self.finish() }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let offset = (app.editor.textStorage!.length - 1) * index / 19
        app.editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
        display()
        timings[stage, default: []].append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        operations[stage, default: 0] += 1
        later(0.2) { self.scroll(index + 1) }
    }
    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Textlet same-condition renderer comparison")
        short = Note(name: "短文本", text: shortText)
        dense = Note(name: "满屏文本", text: denseText)
        app.notes = [short, dense]; app.activeID = short.record.id
        try! app.selectNote(short.record.id, saveCurrent: false)
        app.window.setContentSize(NSSize(width: 860, height: 590))
        app.window.center()
        app.setFontSize(14)
        display()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.sample() }
        later(1) {
            self.changeStage("small-edit")
            self.edit(24) {
                self.changeStage("large-resize")
                self.app.window.zoom(nil)
                self.later(3) {
                    self.changeStage("large-edit")
                    self.edit(54) {
                        self.snapshot()
                        self.changeStage("large-idle")
                        self.later(11) {
                            self.snapshot()
                            self.changeStage("dense-load")
                            try! self.app.selectNote(self.dense.record.id)
                            self.app.setFontSize(14)
                            self.display()
                            self.later(2) {
                                self.changeStage("dense-edit")
                                self.edit(40) {
                                    self.snapshot()
                                    self.changeStage("dense-scroll")
                                    self.scroll(0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func finish() {
        sample(); timer?.invalidate()
        let expected: [String: Int] = ["small-edit": 24, "large-edit": 54, "dense-edit": 40, "dense-scroll": 20]
        let measured = samples.filter { $0["stage"] as? String != "setup" }
        let checks: [String: Bool] = [
            "allOperationsCompleted": operations == expected,
            "allMeasuredSamplesForeground": measured.allSatisfy { $0["active"] as? Bool == true && $0["keyWindow"] as? Bool == true },
            "retina2xThroughout": measured.allSatisfy { $0["scale"] as? CGFloat == 2 },
            "denseTextLengthPreserved": app.editor.textStorage!.length == denseText.utf16.count,
            "scrolledToDocumentEnd": NSMaxRange(app.editor.layoutManager!.characterRange(forGlyphRange: app.editor.layoutManager!.glyphRange(forBoundingRect: app.editor.visibleRect.offsetBy(dx: -app.editor.textContainerOrigin.x, dy: -app.editor.textContainerOrigin.y), in: app.editor.textContainer!), actualGlyphRange: nil)) >= denseText.utf16.count - 1
        ]
        let timing = timings.mapValues { values -> [String: Double] in
            let sorted = values.sorted()
            return ["count": Double(sorted.count), "p50ms": sorted[sorted.count / 2], "p95ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "maxMs": sorted.last!]
        }
#if ROW_RENDERER
        let mode = "rows"
#else
        let mode = "native"
#endif
        let result: [String: Any] = ["mode": mode, "checks": checks, "operations": operations,
            "samples": samples, "events": events, "timings": timing,
            "fixture": ["short": shortText, "dense": denseText],
            "scope": "Complete app; process phys_footprint MiB only; no screenshots; CPU edit/layout/display excludes GPU completion"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { fputs("Comparison report failed: \(error)\n", stderr); exit(1) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        print("Rendering comparison \(mode): \(checks)"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
