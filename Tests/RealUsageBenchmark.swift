import AppKit
import CoreGraphics
import Darwin

// Measure the complete application while it receives keyboard and scroll events.
// Events are posted to this test process only; the user's running Textlet is never
// targeted. getrusage reports CPU time consumed by this process.
func runRealUsageBenchmark(app: Textlet, output: URL) {
    RealUsageBenchmark(app: app, output: output).start()
}

private struct CPUReading {
    let wall: Double
    let cpu: Double
}

private func processCPUReading() -> CPUReading {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        return CPUReading(wall: ProcessInfo.processInfo.systemUptime, cpu: 0)
    }
    func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    return CPUReading(wall: ProcessInfo.processInfo.systemUptime,
                      cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime))
}

private func jsonSafe(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        return dictionary.mapValues(jsonSafe)
    }
    if let dictionary = value as? [String: Double] {
        return dictionary
    }
    if let array = value as? [Any] {
        return array.map(jsonSafe)
    }
    if let value = value as? CGFloat { return Double(value) }
    if let value = value as? Float { return Double(value) }
    if value is String || value is NSNumber || value is NSNull { return value }
    if let value = value as? Int { return value }
    if let value = value as? Bool { return value }
    return String(describing: value)
}

private final class RealUsageBenchmark {
    unowned let app: Textlet
    let output: URL
    let began = ProcessInfo.processInfo.systemUptime
    let denseText = (1...240).map {
        "第 \($0) 行：中文🙂 English 0123456789 " + String(repeating: "abcdefgh 中文 ", count: 10)
    }.joined(separator: "\n")
    let inputCharacters = Array("asdfjklqwertyuiopzxcvbnm ")
    var stage = "setup"
    var samples: [[String: Any]] = []
    var events: [[String: Any]] = []
    var checks: [String: Bool] = [:]
    var inputSent = 0
    var scrollSent = 0
    var scrollMoved = 0
    var inputStartLength = 0
    var scrollStartY: CGFloat = 0
    var timer: Timer?
    var lastCPU = processCPUReading()
    var activity: NSObjectProtocol?
    var boundaries: [String: (CPUReading, CPUReading)] = [:]
    var stageStart = processCPUReading()
    var scheduledStart = 0.0
    var deliveryLateness: [String: [Double]] = [:]
    let position = Textlet.argument("--benchmark-position") ?? "head"
    let interval = 1 / max(1, Double(Textlet.argument("--benchmark-rate") ?? "20") ?? 20)
    let scrollSpan = max(1, Int(Textlet.argument("--benchmark-scroll-span") ?? "80") ?? 80)

    init(app: Textlet, output: URL) {
        self.app = app
        self.output = output
    }

    func later(_ delay: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    func setStage(_ value: String) {
        let reading = processCPUReading()
        boundaries[stage] = (stageStart, reading)
        stage = value; stageStart = reading; lastCPU = reading
        events.append(["stage": value, "seconds": reading.wall - began, "cpuSeconds": reading.cpu])
        if let path = Textlet.argument("--benchmark-phase-log") {
            try? value.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func sample() {
        let reading = processCPUReading()
        let wallDelta = max(0.000001, reading.wall - lastCPU.wall)
        let cpuDelta = max(0, reading.cpu - lastCPU.cpu)
        var value: [String: Any] = memorySample()
        value["stage"] = stage
        value["seconds"] = reading.wall - began
        value["cpuSeconds"] = reading.cpu
        value["cpuPercentOfOneCore"] = cpuDelta / wallDelta * 100
        value["active"] = NSApp.isActive
        value["keyWindow"] = app.window.isKeyWindow
        value["width"] = Double(app.window.contentView!.bounds.width)
        value["height"] = Double(app.window.contentView!.bounds.height)
        value["scale"] = Double(app.window.backingScaleFactor)
        value["textUTF16Length"] = app.editor.textStorage!.length
        value["scrollY"] = Double(app.scroller.contentView.bounds.origin.y)
        value["lineNumberLabelCount"] = app.ruler.cachedLabelCount
        value["lineNumberCacheHits"] = app.ruler.labelCacheHits
        value["lineNumberMeasurements"] = app.ruler.labelMeasurements
#if ROW_RENDERER
        value["tiles"] = app.editor.renderedTileCount
        value["bitmapBytes"] = app.editor.renderedBitmapBytes
        value["rasterizations"] = app.editor.rowRasterizations
        value["cacheHits"] = app.editor.rowCacheHits
        value["renderPasses"] = app.editor.rowRenderPasses
        value["cachedTiles"] = app.editor.cachedTileCount
        value["skippedTouchBarFormatUpdates"] = app.editor.skippedTouchBarFormatUpdates
#endif
        samples.append(value)
        lastCPU = reading
    }

    func display() {
        app.window.displayIfNeeded()
        app.editor.displayIfNeeded()
    }

    func stageSummary(_ name: String) -> [String: Any] {
        let values = samples.filter { $0["stage"] as? String == name }
        let cpu = values.compactMap { $0["cpuPercentOfOneCore"] as? Double }.sorted()
        let footprints = values.compactMap { $0["footprintMiB"] as? Double }
        let boundary = boundaries[name]!
        let duration = boundary.1.wall - boundary.0.wall
        let cpuSeconds = boundary.1.cpu - boundary.0.cpu
        let lateness = (deliveryLateness[name] ?? []).sorted()
        let lastFootprint = footprints.isEmpty ? 0.0 : footprints[footprints.count - 1]
        return [
            "samples": values.count,
            "avgCpuPercentOfOneCore": cpuSeconds / duration * 100,
            "wallSeconds": duration,
            "deliveryLatenessP95Milliseconds": lateness.isEmpty ? 0 : lateness[min(lateness.count - 1, Int(Double(lateness.count) * 0.95))] * 1000,
            "p50CpuPercentOfOneCore": cpu.isEmpty ? 0 : cpu[cpu.count / 2],
            "p95CpuPercentOfOneCore": cpu.isEmpty ? 0 : cpu[min(cpu.count - 1, Int(Double(cpu.count) * 0.95))],
            "maxCpuPercentOfOneCore": cpu.max() ?? 0,
            "cpuSecondsMeasured": cpuSeconds,
            "maxFootprintMiB": footprints.max() ?? 0,
            "lastFootprintMiB": lastFootprint,
            "maxPeakFootprintMiB": values.compactMap { $0["peakFootprintMiB"] as? Double }.max() ?? 0
        ]
    }

    func postKey(_ character: Character) {
        // These are key-down/key-up events routed through the target app's window
        // and NSTextView key binding path, rather than insertText(_:).
        let keyCodes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, ";": 41, "'": 39,
            ",": 43, "n": 45, "m": 46, ".": 47, "/": 44, " ": 49
        ]
        guard let keyCode = keyCodes[character] else { return }
        let text = String(character)
        let windowNumber = app.window.windowNumber
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: windowNumber, context: nil,
                                       characters: text, charactersIgnoringModifiers: text,
                                       isARepeat: false, keyCode: keyCode) {
            app.window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: windowNumber, context: nil,
                                     characters: text, charactersIgnoringModifiers: text,
                                     isARepeat: false, keyCode: keyCode) {
            app.window.sendEvent(up)
        }
        inputSent += 1
    }

    func sendNextKey(_ remaining: Int) {
        guard remaining > 0 else {
            later(1) {
                self.checks["keyEventsChangedText"] = self.app.editor.textStorage!.length == self.inputStartLength + 160
                self.setStage("input-idle")
                self.later(8) { self.beginScroll() }
            }
            return
        }
        deliveryLateness[stage, default: []].append(max(0, ProcessInfo.processInfo.systemUptime - scheduledStart - Double(inputSent) * interval))
        postKey(inputCharacters[inputSent % inputCharacters.count])
        later(max(0, scheduledStart + Double(inputSent) * interval - ProcessInfo.processInfo.systemUptime)) { self.sendNextKey(remaining - 1) }
    }

    func beginInput() {
        app.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inputStartLength = app.editor.textStorage!.length
        let location = position == "tail" ? inputStartLength : position == "middle" ? inputStartLength / 2 : 0
        app.editor.setSelectedRange(NSRange(location: location, length: 0))
        app.editor.scrollRangeToVisible(app.editor.selectedRange())
        display()
        app.window.makeFirstResponder(app.editor)
        setStage("continuous-input"); scheduledStart = stageStart.wall
        sendNextKey(160)
    }

    func postScroll(_ delta: Int32) {
        // Route a trackpad-style scroll-wheel event through NSScrollView's handler.
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) {
            if let appKitEvent = NSEvent(cgEvent: event) {
                let before = app.scroller.contentView.bounds.origin.y
                app.scroller.scrollWheel(with: appKitEvent)
                scrollSent += 1
                if abs(app.scroller.contentView.bounds.origin.y - before) > 0.01 { scrollMoved += 1 }
            }
        }
    }

    func sendNextScroll(_ remaining: Int) {
        guard remaining > 0 else {
            later(1) {
                let values = self.samples.filter { $0["stage"] as? String == "continuous-scroll" }
                let y = values.compactMap { $0["scrollY"] as? Double }
                self.checks["scrollEventsMovedViewport"] = (y.max() ?? 0) - (y.min() ?? 0) > 2
                self.setStage("scroll-idle")
                self.later(8) { self.finish() }
            }
            return
        }
        let index = 160 - remaining
        deliveryLateness[stage, default: []].append(max(0, ProcessInfo.processInfo.systemUptime - scheduledStart - Double(index) * interval))
        postScroll((index / scrollSpan) % 2 == 0 ? 55 : -55)
        later(max(0, scheduledStart + Double(index + 1) * interval - ProcessInfo.processInfo.systemUptime)) { self.sendNextScroll(remaining - 1) }
    }

    func beginScroll() {
        // Moving to the scroll fixture is setup work, not idle CPU consumption.
        setStage("scroll-setup")
        app.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        app.editor.setSelectedRange(NSRange(location: app.editor.textStorage!.length / 2, length: 0))
        app.editor.scrollRangeToVisible(app.editor.selectedRange())
        display()
        scrollStartY = app.scroller.contentView.bounds.origin.y
        setStage("continuous-scroll"); scheduledStart = stageStart.wall
        sendNextScroll(160)
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Textlet real input and scroll CPU test")
        let note = Note(name: "CPU测试", text: denseText)
        app.notes = [note]
        app.activeID = note.record.id
        try! app.selectNote(note.record.id, saveCurrent: false)
        app.window.setContentSize(NSSize(width: 1680, height: 940))
        app.window.center()
        app.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        app.window.makeFirstResponder(app.editor)
        display()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
        later(0.5) {
            self.app.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        later(2) { self.beginInput() }
    }

    func finish() {
        sample()
        boundaries[stage] = (stageStart, processCPUReading())
        timer?.invalidate()
        let measured = samples.filter { $0["stage"] as? String != "setup" }
        checks["inputOperationCount"] = inputSent == 160
        checks["scrollOperationCount"] = scrollSent == 160
        checks["allMeasuredSamplesForeground"] = measured.allSatisfy { ($0["active"] as? Bool ?? false) && ($0["keyWindow"] as? Bool ?? false) }
        checks["retina2xThroughout"] = measured.allSatisfy { $0["scale"] as? Double == 2 }
        checks["inputEventsChangedText"] = checks["keyEventsChangedText"] == true
        checks["scrollEventsMovedViewport"] = checks["scrollEventsMovedViewport"] == true
        checks["idleSamplesCollected"] = samples.filter { ["input-idle", "scroll-idle"].contains($0["stage"] as? String) }.count >= 100
        let summaries = ["continuous-input", "input-idle", "continuous-scroll", "scroll-idle"].reduce(into: [String: [String: Any]]()) {
            $0[$1] = stageSummary($1)
        }
        let result: [String: Any] = [
            "checks": checks,
            "mode": AppEdition.name,
            "position": position,
            "requestedEventsPerSecond": 1 / interval,
            "scrollDirectionChangeEvery": scrollSpan,
            "cacheBudgetMiB": ProcessInfo.processInfo.environment["TEXTLET_ROW_CACHE_MIB"] ?? "default",
            "inputSent": inputSent,
            "scrollSent": scrollSent,
            "scrollMovedEvents": scrollMoved,
            "inputStartLength": inputStartLength,
            "finalLength": app.editor.textStorage!.length,
            "scrollStartY": Double(scrollStartY),
            "scrollFinalY": Double(app.scroller.contentView.bounds.origin.y),
            "summaries": summaries,
            "samples": samples,
            "events": events,
            "scope": "NSEvent key-down/key-up events routed through the target window and CGEvent scroll deltas sent through NSScrollView; getrusage user+system CPU time; idle stages follow each operation; no real Chinese IME candidate selection"
        ]
        let safeResult = jsonSafe(result)
        do { try JSONSerialization.data(withJSONObject: safeResult, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { fputs("Real usage report failed: \(error)\n", stderr); exit(1) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        print("Real usage checks: \(checks)"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
