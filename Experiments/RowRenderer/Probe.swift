import AppKit

final class Probe {
    unowned let app: Experiment
    let output: URL
    let began = ProcessInfo.processInfo.systemUptime
    var stage = "launch", editing = false, tick = 0
    var samples: [[String: Any]] = []
    var durations: [String: [Double]] = [:]
    var sampleTimer: Timer?, editTimer: Timer?
    var activity: NSObjectProtocol?
    init(app: Experiment, output: URL) { self.app = app; self.output = output }
    func later(_ delay: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    func sample() {
        var value: [String: Any] = memorySample()
        value["stage"] = stage; value["seconds"] = ProcessInfo.processInfo.systemUptime - began
        value["active"] = NSApp.isActive; value["width"] = app.window.contentView!.bounds.width
        value["height"] = app.window.contentView!.bounds.height; value["scale"] = app.window.backingScaleFactor
        value["textUTF16Length"] = app.rows?.text.length ?? app.native!.string.utf16.count
        if let rows = app.rows { value["visibleTiles"] = rows.rowLayers.count; value["bitmapBytesEstimate"] = rows.bitmapBytes }
        samples.append(value)
    }
    func snapshot(_ name: String) {
        guard CommandLine.arguments.contains("--vmmap") else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", String(ProcessInfo.processInfo.processIdentifier)]
        let path = output.appendingPathExtension(name + ".vmmap.txt").path
        FileManager.default.createFile(atPath: path, contents: nil)
        process.standardOutput = FileHandle(forWritingAtPath: path); process.standardError = process.standardOutput
        try? process.run()
    }
    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Isolated renderer comparison")
        print("\(app.mode) PID \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        stage = "small-idle"
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.sample() }
        editTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.editing else { return }
            let start = ProcessInfo.processInfo.systemUptime
            self.app.edit(self.tick); self.tick += 1
            self.durations[self.stage, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        later(2) { self.stage = "small-edit"; self.editing = true }
        later(6) { self.editing = false; self.stage = "large-resize"; self.app.window.zoom(nil) }
        later(9) { self.stage = "large-edit"; self.editing = true }
        later(15) { self.snapshot("large-edit") }
        later(17) { self.editing = false; self.stage = "large-idle" }
        later(28) { self.snapshot("large-idle") }
        later(30) { self.stage = "dense-load"; self.app.setText(denseText) }
        later(32) { self.stage = "dense-edit"; self.editing = true }
        later(39) { self.editing = false; self.stage = "dense-scroll" }
        for i in 0..<20 { later(39 + Double(i) * 0.2) { self.app.scroll(CGFloat(i) / 19) } }
        later(43.5) { self.snapshot("dense-scroll") }
        later(44) { self.stage = "dense-idle" }
        later(49) { self.app.setText(sparseText); self.stage = "small-again"; self.app.window.setContentSize(NSSize(width: 860, height: 590)) }
        later(54) { self.finish() }
    }
    func finish() {
        sample(); sampleTimer?.invalidate(); editTimer?.invalidate(); editing = false
        let timing = durations.mapValues { values -> [String: Double] in
            let sorted = values.sorted()
            return ["count": Double(values.count), "p50ms": sorted[sorted.count / 2], "p95ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "maxMs": sorted.last!]
        }
        let result: [String: Any] = ["mode": app.mode, "samples": samples, "edits": tick, "editTimingIncludingDisplay": timing,
                                     "measurement": "TASK_VM_INFO.phys_footprint; own process; screenshot only after sampling; CPU edit+display timing excludes GPU completion"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { fputs("Write failed: \(error)\n", stderr); exit(1) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        print("Finished \(app.mode) \(memorySample())"); fflush(stdout)
        if CommandLine.arguments.contains("--capture") {
            app.window.zoom(nil); app.setText(denseText)
            later(1) {
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(self.app.window.windowNumber), .boundsIgnoreFraming) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: self.output.appendingPathExtension("png"))
                }
                NSApp.terminate(nil)
            }
        } else { NSApp.terminate(nil) }
    }
}
