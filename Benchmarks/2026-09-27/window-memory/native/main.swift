import AppKit
import Darwin
func argument(_ name: String) -> String? {
 guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
 return CommandLine.arguments[i+1]
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let mode = "native"
let output = URL(fileURLWithPath: argument("--probe-output")!)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 590), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "原生 NSTextView 内存基线"
window.center()
let scroller = NSScrollView(frame: window.contentView!.bounds)
scroller.autoresizingMask = [.width, .height]
scroller.hasVerticalScroller = true
scroller.autohidesScrollers = true
let storage = NSTextStorage()
let layout = NSLayoutManager()
storage.addLayoutManager(layout)
let container = NSTextContainer(size: NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude))
container.widthTracksTextView = true
layout.addTextContainer(container)
let editor = NSTextView(frame: scroller.bounds, textContainer: container)
editor.isRichText = false
editor.isVerticallyResizable = true
editor.isHorizontallyResizable = false
editor.autoresizingMask = [.width]
editor.minSize = .zero
editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
editor.backgroundColor = NSColor(srgbRed: 0.153, green: 0.157, blue: 0.133, alpha: 1)
editor.textColor = .white
editor.allowsUndo = true
scroller.documentView = editor
window.contentView!.addSubview(scroller)
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
func memorySample() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return [:] }
    return ["footprintMiB": Double(info.phys_footprint) / 1_048_576,
            "residentMiB": Double(info.resident_size) / 1_048_576,
            "peakResidentMiB": Double(info.resident_size_peak) / 1_048_576,
            "peakFootprintMiB": Double(info.ledger_phys_footprint_peak) / 1_048_576]
}

let started = ProcessInfo.processInfo.systemUptime
var stage = "launch"
var editing = false
var tick = 0
var samples = [[String: Any]]()
var activity: NSObjectProtocol?
func sample() {
    
    var row: [String: Any] = memorySample()
    row["stage"] = stage
    row["seconds"] = ProcessInfo.processInfo.systemUptime - started
    row["active"] = NSApp.isActive
    row["width"] = window.contentView!.bounds.width
    row["height"] = window.contentView!.bounds.height
    row["scale"] = window.backingScaleFactor
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
    editor.string = "SELECT 1;\n短文本窗口内存测试。\n只替换第一个字符。\n"
    window.makeFirstResponder(editor)
    stage = "small-idle"
    print("PID \(ProcessInfo.processInfo.processIdentifier) mode \(mode)"); fflush(stdout)
}
let sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in sample() }
let editTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
    guard editing else { return }
    editor.insertText(tick % 2 == 0 ? "A" : "B", replacementRange: NSRange(location: 0, length: 1))
    tick += 1
}
later(4) { stage = "small-edit"; editing = true }
later(8) { dump("small-edit"); editing = false }
later(10) { stage = "large-resize"; window.zoom(nil) }
later(14) { stage = "large-idle"; dump("large-idle") }
later(19) { stage = "large-edit"; editing = true }
later(26) {
    dump("large-edit"); editing = false; stage = "large-settle"
    try? tree(window.contentView!.superview ?? window.contentView!).write(to: output.appendingPathExtension("tree.txt"), atomically: true, encoding: .utf8)
}
later(40) { dump("large-settled") }
later(43) { stage = "small-again"; window.setContentSize(NSSize(width: 860, height: 590)) }
later(53) {
    sample()
    let result: [String: Any] = ["mode": mode, "samples": samples, "edits": tick, "textLength": editor.string.utf16.count]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    print("Finished \(mode): \(memorySample())"); fflush(stdout)
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    NSApp.terminate(nil)
}
application.run()
