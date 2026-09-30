import AppKit
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let controller = Textlet()
application.delegate = controller
let mode = Textlet.argument("--probe-mode") ?? "baseline"
let output = URL(fileURLWithPath: Textlet.argument("--probe-output")!)
let started = ProcessInfo.processInfo.systemUptime
var stage = "launch"
var editing = false
var tick = 0
var samples = [[String: Any]]()
var activity: NSObjectProtocol?
func sample() {
    guard controller.window != nil else { return }
    var row: [String: Any] = memorySample()
    row["stage"] = stage
    row["seconds"] = ProcessInfo.processInfo.systemUptime - started
    row["active"] = NSApp.isActive
    row["width"] = controller.window.contentView!.bounds.width
    row["height"] = controller.window.contentView!.bounds.height
    row["scale"] = controller.window.backingScaleFactor
    samples.append(row)
}
func later(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
func dump(_ name: String) {
    sample()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    p.arguments = ["-summary", String(ProcessInfo.processInfo.processIdentifier)]
    let path = output.appendingPathExtension(name + ".vmmap.txt").path
    FileManager.default.createFile(atPath: path, contents: nil)
    p.standardOutput = FileHandle(forWritingAtPath: path)
    p.standardError = p.standardOutput
    try? p.run()
}
func tree(_ view: NSView, _ indent: String = "") -> String {
    "\(indent)\(type(of: view)) \(view.frame) wantsLayer=\(view.wantsLayer) layer=\(String(describing: view.layer.map { type(of: $0) })) flatten=\(view.canDrawSubviewsIntoLayer)\n" + view.subviews.map { tree($0, indent + "  ") }.joined()
}
later(1) {
    activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Isolated window memory diagnosis")
    controller.notes = [Note(name: "内存诊断", text: "SELECT 1;\n短文本窗口内存测试。\n只替换第一个字符。\n")]
    controller.activeID = controller.notes[0].record.id
    try! controller.selectNote(controller.activeID, saveCurrent: false)
    if mode == "flatten" {
        controller.window.contentView!.wantsLayer = true
        controller.window.contentView!.canDrawSubviewsIntoLayer = true
        controller.window.contentView!.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    if mode == "flat-color" {
        controller.scroller.drawsBackground = false
        controller.scroller.contentView.drawsBackground = false
    }
    if mode == "editor-layer" { controller.editor.wantsLayer = true; controller.editor.layerContentsRedrawPolicy = .onSetNeedsDisplay }
    controller.window.makeFirstResponder(controller.editor)
    stage = "small-idle"
    print("PID \(ProcessInfo.processInfo.processIdentifier) mode \(mode)"); fflush(stdout)
}
let sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in sample() }
let editTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
    guard editing else { return }
    controller.editor.insertText(tick % 2 == 0 ? "A" : "B", replacementRange: NSRange(location: 0, length: 1))
    tick += 1
}
later(4) { stage = "small-edit"; editing = true }
later(8) { dump("small-edit"); editing = false }
later(10) { stage = "large-resize"; controller.window.zoom(nil) }
later(14) { stage = "large-idle"; dump("large-idle") }
later(19) { stage = "large-edit"; editing = true }
later(26) {
    dump("large-edit"); editing = false; stage = "large-settle"
    try? tree(controller.window.contentView!.superview ?? controller.window.contentView!).write(to: output.appendingPathExtension("tree.txt"), atomically: true, encoding: .utf8)
}
later(40) { dump("large-settled") }
later(43) { stage = "small-again"; controller.window.setContentSize(NSSize(width: 860, height: 590)) }
later(53) {
    sample()
    let result: [String: Any] = ["mode": mode, "samples": samples, "edits": tick, "textLength": controller.editor.string.utf16.count]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    print("Finished \(mode): \(memorySample())"); fflush(stdout)
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    NSApp.terminate(nil)
}
application.run()
