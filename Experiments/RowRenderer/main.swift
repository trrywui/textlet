import AppKit
import Darwin

let canvas = NSColor(srgbRed: 0.153, green: 0.157, blue: 0.133, alpha: 1)
let ink = NSColor(srgbRed: 0.945, green: 0.941, blue: 0.91, alpha: 1)
let sparseText = "SELECT 1;\n短文本窗口内存测试。\n只替换第一个字符。\n"
let denseText = (1...180).map { "第 \($0) 行：中文🙂 English 0123456789，验证窗口铺满、自动折行与滚动。 " + String(repeating: "abcdefgh 中文 ", count: 10) }.joined(separator: "\n")
func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func memorySample() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return [:] }
    return ["footprintMiB": Double(info.phys_footprint) / 1_048_576, "residentMiB": Double(info.resident_size) / 1_048_576,
            "peakFootprintMiB": Double(info.ledger_phys_footprint_peak) / 1_048_576]
}

final class Experiment: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mode = argument("--mode") ?? "rows"
    var window: NSWindow!
    var rows: RowEditor?
    var native: NSTextView?
    var scroller: NSScrollView?
    var benchmark: Probe?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 590), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.title = (mode == "native" ? "系统输入框对照" : "Textlet 逐行绘制实验") + " · 不自动保存"
        window.minSize = NSSize(width: 480, height: 320); window.center()
        if mode == "native" {
            let storage = NSTextStorage(), layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(size: NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true; layout.addTextContainer(container)
            let editor = NSTextView(frame: window.contentView!.bounds, textContainer: container)
            editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
            editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
            editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            editor.textContainerInset = NSSize(width: 20, height: 20)
            container.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 23; paragraph.maximumLineHeight = 23
            editor.defaultParagraphStyle = paragraph
            editor.typingAttributes = [.font: editor.font!, .paragraphStyle: paragraph, .foregroundColor: ink]
            editor.backgroundColor = canvas; editor.textColor = ink
            editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextCompletionEnabled = false; editor.enabledTextCheckingTypes = 0
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.verticalScrollElasticity = .none; scroll.documentView = editor
            window.contentView!.addSubview(scroll); native = editor; scroller = scroll
        } else {
            let editor = RowEditor(frame: window.contentView!.bounds)
            editor.autoresizingMask = [.width, .height]; window.contentView = editor; rows = editor
        }
        menu()
        setText(sparseText)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(rows ?? native)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTests(); NSApp.terminate(nil) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        } else if let path = argument("--benchmark") {
            benchmark = Probe(app: self, output: URL(fileURLWithPath: path)); benchmark?.start()
        }
    }
    func setText(_ text: String) {
        if let rows { rows.setText(text) }
        if let native {
            native.string = text
            native.textStorage?.addAttributes(native.typingAttributes, range: NSRange(location: 0, length: native.string.utf16.count))
            native.setSelectedRange(NSRange(location: 0, length: 0)); native.scrollRangeToVisible(NSRange(location: 0, length: 0))
            native.undoManager?.removeAllActions()
        }
    }
    func edit(_ tick: Int) {
        let value = tick % 2 == 0 ? "A" : "B", range = NSRange(location: 0, length: 1)
        if let rows { rows.insertText(value, replacementRange: range) }
        if let native { native.insertText(value, replacementRange: range) }
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    func scroll(_ progress: CGFloat) {
        if let rows { rows.scrollY = rows.maxScroll * progress; rows.render() }
        if let scroller, let native {
            native.layoutManager?.ensureLayout(for: native.textContainer!)
            scroller.contentView.scroll(to: NSPoint(x: 0, y: max(0, native.frame.height - scroller.contentSize.height) * progress))
            scroller.reflectScrolledClipView(scroller.contentView)
        }
        window.displayIfNeeded()
    }
    func menu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (name, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let testItem = NSMenuItem(); testItem.title = "实验"; main.addItem(testItem)
        let test = NSMenu(title: "实验"); testItem.submenu = test
        for (name, action) in [("载入短文本", #selector(loadSparse)), ("载入多行文本", #selector(loadDense)), ("查看内存", #selector(showMemory))] {
            let item = test.addItem(withTitle: name, action: action, keyEquivalent: ""); item.target = self
        }
        NSApp.mainMenu = main
    }
    @objc func loadSparse() { setText(sparseText) }
    @objc func loadDense() { setText(denseText) }
    @objc func showMemory() {
        let memory = memorySample()
        let alert = NSAlert(); alert.messageText = "实验内存"
        alert.informativeText = String(format: "当前 %.1f MiB，运行峰值 %.1f MiB\n窗口 %.0f × %.0f，%.0f×\n仅本进程；不包含 WindowServer。",
            memory["footprintMiB"] ?? 0, memory["peakFootprintMiB"] ?? 0, window.contentView!.bounds.width, window.contentView!.bounds.height, window.backingScaleFactor)
        alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = Experiment()
application.delegate = delegate
application.run()
