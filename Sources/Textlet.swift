import AppKit
import Darwin

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

func disableTextSubstitutions(in editor: NSTextView) {
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.enabledTextCheckingTypes = 0
    editor.isAutomaticTextCompletionEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.isGrammarCheckingEnabled = false
    editor.smartInsertDeleteEnabled = false
}

final class EditorWindow: NSWindow {
    weak var tabReordering: TabReordering?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, tabReordering?.cancel() == true { return }
        super.sendEvent(event)
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let fieldEditor = firstResponder as? NSTextView, fieldEditor.isFieldEditor {
            disableTextSubstitutions(in: fieldEditor)
        }
        return accepted
    }
}

#if ROW_RENDERER
typealias EditorRenderingView = RowRenderingTextView
#else
typealias EditorRenderingView = NSTextView
#endif

final class EditorView: EditorRenderingView {
    override func paste(_ sender: Any?) {
        pastePlainText(from: .general)
    }
    func pastePlainText(from board: NSPasteboard) {
        guard isEditable else { return }
        guard let text = board.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
}

// Keep the tab strip transient even when AppKit updates the system scroller style.
final class TabScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}

// Keep AppKit's scrolling and fade timing; customize only the tab thumb's drawing.
final class TabScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thumb = NSRect(x: knob.minX, y: isFlipped ? bounds.maxY - 4 : bounds.minY + 1,
                           width: knob.width, height: 3)
        NSColor(white: 0.70, alpha: 1).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

final class EditorScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    override func tile() {
        super.tile()
        onViewportLayout?()
    }
}

final class BackgroundView: NSView {
#if ROW_RENDERER
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.chrome.cgColor }
#endif
    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    override var isOpaque: Bool { true }
}

// Hit-test only the empty strip; existing tabs and controls keep their normal actions.
final class TabBarView: NSView {
    var onNewNote: (() -> Void)?
    var reordering: TabReordering?
    weak var scroller: NSScrollView?
    private var forwardingScroll = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NoteTab || current is NSControl { return hit }
            view = current.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onNewNote?() }
        else { super.mouseDown(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        // NSScrollView may pass unconsumed scrolling back up its responder chain.
        guard !forwardingScroll, let scroller else { super.scrollWheel(with: event); return }
        forwardingScroll = true
        defer { forwardingScroll = false }
        scroller.scrollWheel(with: event)
    }
}

final class NoteTab: NSView {
    private struct State: Equatable {
        let title: String, path: String?
        let dirty: Bool, missing: Bool, external: Bool, log: Bool
    }
    private static let unsavedImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "关闭文本")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 6, weight: .regular))
    private static let savedImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭文本")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular))
    private var displayedState: State?
    let id: UUID
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    weak var reordering: TabReordering?
    private var middleMousePressed = false
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            label.textColor = selected ? Theme.text : Theme.muted
            needsDisplay = true
        }
    }
    init(note: Note) {
        id = note.record.id
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        label.stringValue = note.displayName
        label.textColor = Theme.muted
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        close.bezelStyle = .inline
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = Theme.muted
        close.target = self
        close.action = #selector(closeNote)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(close)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 160), heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18), close.heightAnchor.constraint(equalToConstant: 18)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(note.displayName)
        toolTip = note.displayName
        updateState(for: note)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateTitle(for note: Note) {
        let title = note.displayName
        guard label.stringValue != title else { return }
        label.stringValue = title
        setAccessibilityLabel(title)
        toolTip = title
    }
    func updateState(for note: Note) {
        let next = State(title: note.displayName, path: note.record.file?.path, dirty: note.needsFileSave,
            missing: note.fileMissing, external: note.fileChangedExternally, log: note.isLog)
        guard displayedState != next else { return }
        if displayedState?.dirty != next.dirty { close.image = next.dirty ? Self.unsavedImage : Self.savedImage }
        displayedState = next
        updateTitle(for: note)
        close.contentTintColor = note.fileMissing ? .systemRed : (note.needsFileSave ? Theme.accent : Theme.muted)
        let state = note.isLog ? "只读日志" : note.fileMissing ? "原文件已移走或删除，尚未保存"
            : note.fileChangedExternally ? "原文件已被外部修改" : note.needsFileSave ? "尚未保存到文件" : "已保存到文件"
        close.toolTip = "关闭文本（\(state)）"
        close.setAccessibilityLabel("关闭\(note.displayName)，\(state)")
        toolTip = [note.displayName, note.record.file?.path, state].compactMap { $0 }.joined(separator: "\n")
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === label ? self : hit
    }
    override func mouseDown(with event: NSEvent) { reordering?.begin(self, with: event) }
    override func mouseDragged(with event: NSEvent) { reordering?.drag(self, with: event) }
    override func mouseUp(with event: NSEvent) { reordering?.end(self, with: event) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        middleMousePressed = true
    }
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        let shouldClose = middleMousePressed && visibleRect.contains(convert(event.locationInWindow, from: nil))
        middleMousePressed = false
        if shouldClose { onClose?() }
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    @objc private func closeNote() { onClose?() }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 清除自身缓存中的旧高亮，不依赖滚动视图或父视图重绘背景。
        Theme.chrome.setFill()
        bounds.intersection(dirtyRect).fill()
        if selected {
            Theme.canvas.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 0, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

final class Textlet: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextStorageDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var editor: EditorView!
    var scroller: NSScrollView!
    var ruler: LineNumberRuler!
    var highlighter: SyntaxHighlighter!
    var logViewer: LogViewer!
    var tabBar: TabBarView!
    var tabStack: NSStackView!
    var tabScroller: NSScrollView!
    let status = NSTextField(labelWithString: "")
    let position = NSTextField(labelWithString: "")
    var store: SessionStore!
    var notes: [Note] = []
    var activeID: UUID!
    var switching = false
    var saveTimer: Timer?
    var pendingOpen: [String] = []
    var fileAssociationWindowController: FileAssociationWindowController?
    var lastSaveError: String?
    var restoredWindowFrame: NSRect?
    var activationRefreshPending = false
    var active: Note { notes.first(where: { $0.record.id == activeID })! }

    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        do {
            // Store drafts under Textlet's application-specific directory.
            let base = Self.argument("--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(AppEdition.sessionDirectory, isDirectory: true)
            store = try SessionStore(directory: base)
            if let session = try store.load() {
                notes = session.notes.map { Note(record: $0) }
                activeID = session.activeID
                restoredWindowFrame = session.windowFrame
            } else {
                notes = [Note(name: Note.nextName(in: notes), automaticTitle: true)]
                activeID = notes[0].record.id
            }
            buildMenus()
            buildWindow()
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try selectNote(activeID, saveCurrent: false)
            _ = saveSession()
            // Ask for activation after launch has finished registering the application.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            if let notice = store.recoveryNotice { showMessage("已恢复草稿", notice) }
            for path in pendingOpen { openText(URL(fileURLWithPath: path)) }
            pendingOpen.removeAll()
        } catch {
            showMessage("Textlet 无法读取草稿", error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    func buildWindow() {
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppEdition.name
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.chrome
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        if let frame = restoredWindowFrame,
           let restored = Self.visibleWindowFrame(frame, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize) {
            window.setFrame(restored, display: false)
        }
        window.contentView = BackgroundView(frame: window.contentView!.bounds)
        let content = window.contentView!

        let top = TabBarView()
        tabBar = top
        top.onNewNote = { [weak self] in self?.newNote() }
        top.translatesAutoresizingMaskIntoConstraints = false
        tabStack = NSStackView()
        tabStack.orientation = .horizontal
        tabStack.spacing = 3
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroller = TabScrollView()
        tabScroller.drawsBackground = false
        tabScroller.hasHorizontalScroller = true
        tabScroller.horizontalScroller = TabScroller()
        tabScroller.autohidesScrollers = true
        tabScroller.scrollerStyle = .overlay
        tabScroller.documentView = tabStack
        top.scroller = tabScroller
        tabScroller.translatesAutoresizingMaskIntoConstraints = false
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建文本")!,
                            target: self, action: #selector(newNote))
        plus.isBordered = false
        plus.toolTip = "新建文本 ⌘N"
        plus.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(tabScroller)
        top.addSubview(plus)
        let reordering = TabReordering(bar: top, stack: tabStack, scroller: tabScroller)
        top.reordering = reordering
        (window as? EditorWindow)?.tabReordering = reordering
        reordering.onMove = { [weak self] id, index in
            do { try self?.moveNote(id, to: index) }
            catch { self?.showMessage("无法保存标签顺序", error.localizedDescription) }
        }

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Contiguous layout keeps saved pixel offsets stable when swapping text storage.
        // We still request only the visible region, instead of sizeToFit() for the whole document.
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        editor = EditorView(frame: NSRect(x: 0, y: 0, width: 860, height: 510), textContainer: container)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        disableTextSubstitutions(in: editor)
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 20, height: 18)
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.backgroundColor = Theme.canvas
        editor.textColor = Theme.text
        editor.insertionPointColor = Theme.accent
        editor.selectedTextAttributes = [.backgroundColor: Theme.selection, .foregroundColor: Theme.text]
        highlighter = SyntaxHighlighter(editor: editor)
        editor.delegate = self
        editor.setAccessibilityLabel("文本正文")
        scroller = EditorScrollView()
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.drawsBackground = true
        scroller.clipsToBounds = true
        scroller.backgroundColor = Theme.canvas
        scroller.documentView = editor
        scroller.wantsLayer = false
        scroller.contentView.wantsLayer = false
        editor.wantsLayer = false
#if ROW_RENDERER
        content.wantsLayer = true
        content.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scroller.drawsBackground = false
        scroller.contentView.drawsBackground = false
        editor.wantsLayer = true
        editor.layerContentsRedrawPolicy = .onSetNeedsDisplay
#endif
        scroller.verticalScrollElasticity = .none
        scroller.horizontalScrollElasticity = .none
        scroller.translatesAutoresizingMaskIntoConstraints = false
        ruler = LineNumberRuler(scrollView: scroller, editor: editor)
        highlighter.onHighlight = { [weak self] in
            self?.ruler?.needsDisplay = true
#if ROW_RENDERER
            self?.editor.invalidateRows()
#endif
        }
        (scroller as? EditorScrollView)?.onViewportLayout = { [weak self] in self?.ruler?.needsDisplay = true }
        scroller.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                              name: NSView.boundsDidChangeNotification, object: scroller.contentView)
        logViewer = LogViewer(app: self)
        logViewer.build()

        let bottom = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        for field in [status, position] {
            field.font = .systemFont(ofSize: 10.5)
            field.textColor = Theme.muted
            field.translatesAutoresizingMaskIntoConstraints = false
            bottom.addSubview(field)
        }
        status.lineBreakMode = .byTruncatingMiddle
        position.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.addSubview(top)
        content.addSubview(scroller)
        content.addSubview(ruler)
        content.addSubview(logViewer.bar)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor), top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor), top.heightAnchor.constraint(equalToConstant: 42),
            tabScroller.leadingAnchor.constraint(equalTo: top.leadingAnchor), tabScroller.topAnchor.constraint(equalTo: top.topAnchor),
            tabScroller.bottomAnchor.constraint(equalTo: top.bottomAnchor), tabScroller.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -5),
            tabStack.heightAnchor.constraint(equalToConstant: 40),
            plus.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -12), plus.centerYAnchor.constraint(equalTo: top.centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 28), plus.heightAnchor.constraint(equalToConstant: 28),
            logViewer.bar.topAnchor.constraint(equalTo: top.bottomAnchor),
            logViewer.bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), logViewer.bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ruler.leadingAnchor.constraint(equalTo: content.leadingAnchor), ruler.widthAnchor.constraint(equalToConstant: ruler.ruleThickness),
            ruler.topAnchor.constraint(equalTo: scroller.topAnchor), ruler.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            scroller.topAnchor.constraint(equalTo: logViewer.bar.bottomAnchor), scroller.leadingAnchor.constraint(equalTo: ruler.trailingAnchor),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroller.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor), bottom.heightAnchor.constraint(equalToConstant: 26),
            status.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 14), status.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            position.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -14), position.centerYAnchor.constraint(equalTo: bottom.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: position.leadingAnchor, constant: -12)
        ])
    }

    func buildMenus() {
        let bar = NSMenu()
        func group(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            bar.addItem(item)
            return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ target: AnyObject? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = target
            menu.addItem(entry)
        }
        let app = group(AppEdition.name)
        item(app, "关于 \(AppEdition.name)", #selector(about), "", self)
        app.addItem(.separator())
        item(app, "文件关联…", #selector(showFileAssociations), "", self)
        app.addItem(.separator())
        item(app, "隐藏 \(AppEdition.name)", #selector(NSApplication.hide(_:)), "h", NSApp)
        item(app, "退出 \(AppEdition.name)", #selector(NSApplication.terminate(_:)), "q", NSApp)
        let file = group("文件")
        item(file, "新建文本", #selector(newNote), "n", self)
        item(file, "打开文本…", #selector(openPanel), "o", self)
        item(file, "以只读日志模式打开…", #selector(openLogPanel), "", self)
        item(file, "保存", #selector(saveText), "s", self)
        item(file, "另存为…", #selector(saveTextAs), "S", self)
        item(file, "导出副本…", #selector(exportText), "", self)
        item(file, "重命名文本…", #selector(renameNote), "", self)
        file.addItem(.separator())
        item(file, "关闭文本…", #selector(closeCurrent), "w", self)
        let edit = group("编辑")
        item(edit, "撤销", Selector(("undo:")), "z")
        item(edit, "重做", Selector(("redo:")), "Z")
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "复制", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴纯文本", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        let format = NSMenuItem(title: "格式化 JSON", action: #selector(formatJSON), keyEquivalent: "j")
        format.keyEquivalentModifierMask = [.command, .shift]
        format.target = self
        edit.addItem(format)
        edit.addItem(.separator())
        let find = NSMenuItem(title: "查找…", action: #selector(showFind), keyEquivalent: "f")
        find.target = self
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        item(edit, "替换…", #selector(showReplace), "r", self)
        item(edit, "查找下一个", #selector(findNext), "g", self)
        let view = group("窗口")
        item(view, "下一个标签", #selector(nextNote), "}", self)
        item(view, "上一个标签", #selector(previousNote), "{", self)
        item(view, "放大文字", #selector(largerFont), "+", self)
        item(view, "缩小文字", #selector(smallerFont), "-", self)
        let syntax = group("语法")
        let automatic = NSMenuItem(title: "按文件名自动识别", action: #selector(changeLanguage(_:)), keyEquivalent: "")
        automatic.target = self; automatic.representedObject = "auto"
        syntax.addItem(automatic); syntax.addItem(.separator())
        for language in TextLanguage.allCases {
            let choice = NSMenuItem(title: language.title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            choice.target = self; choice.representedObject = language.rawValue; syntax.addItem(choice)
        }
        let help = group("帮助")
        item(help, "性能信息…", #selector(performance), "", self)
        item(help, "打开草稿目录", #selector(showDraftFolder), "", self)
        NSApp.mainMenu = bar
    }

    func capturePosition() {
        guard editor != nil, activeID != nil, !switching else { return }
        if active.isLog {
            guard !logViewer.loading, let page = logViewer.page else { return }
            active.record.logOffset = page.start
            active.record.scrollY = Double(max(0, scroller.contentView.bounds.origin.y + scroller.contentView.contentInsets.top))
            return
        }
        active.record.selection = editor.selectedRange().location
        active.record.scrollY = Double(max(0, scroller.contentView.bounds.origin.y + scroller.contentView.contentInsets.top))
    }

    func selectNote(_ id: UUID, saveCurrent: Bool = true) throws {
        guard let next = notes.first(where: { $0.record.id == id }) else { throw SessionError.invalid("标签不存在") }
        tabBar?.reordering?.cancel()
        if saveCurrent {
            capturePosition()
            editor.breakUndoCoalescing()
            guard saveSession() else { throw SessionError.invalid(lastSaveError ?? "会话保存失败") }
        }
        if !next.isLog, next.storage == nil { next.storage = NSTextStorage(string: try store.text(for: next.record)) }
        next.refreshContentTitle()
        highlighter.reset(.plain)
        switching = true
        editor.textStorage?.delegate = nil
        // Preserve the old position above, then discard its selection before
        // replacing the body: AppKit's font updates can query it immediately.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        activeID = id
        if next.isLog {
            let hideFind = NSMenuItem(); hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue
            editor.performFindPanelAction(hideFind)
            logViewer.select(next)
            switching = false
            renderTabs(); updateStatus()
            return
        }
        logViewer.leave()
        editor.isEditable = true; editor.allowsUndo = true
        window.contentView?.layoutSubtreeIfNeeded()
        editor.setFrameSize(NSSize(width: scroller.contentSize.width, height: editor.frame.height))
        editor.textStorage?.delegate = nil
        let storage = next.storage!
        let font = editor.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        if storage.length > 0, storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont != font {
            storage.setAttributes([.font: font, .foregroundColor: Theme.text],
                                  range: NSRange(location: 0, length: storage.length))
        }
        editor.layoutManager!.replaceTextStorage(storage)
        storage.delegate = self
        ruler.reset()
        editor.setSelectedRange(NSRange(location: min(max(0, next.record.selection), storage.length), length: 0))
        editor.typingAttributes = [.font: editor.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                   .foregroundColor: Theme.text]
        // Notify NSTextView's finder that replacing the entire storage changed the document.
        // Keep switching=true so this does not mark the newly selected draft as edited.
        editor.didChangeText()
        // Acquiring focus can scroll to the caret. Restore the saved viewport AFTER that.
        window.makeFirstResponder(editor)
        // Let NSTextView lazily size and lay out the visible region. sizeToFit() forces
        // every line to be shaped on every tab switch, even when the caret is at the top.
        editor.needsDisplay = true
        editor.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: next.record.scrollY,
                                                                  width: scroller.contentSize.width,
                                                                  height: scroller.contentSize.height),
                                          in: editor.textContainer!)
        let maxY = max(0, editor.bounds.height - scroller.contentView.bounds.height)
        let inset = scroller.contentView.contentInsets.top
        scroller.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, next.record.scrollY) - inset)))
        scroller.reflectScrolledClipView(scroller.contentView)
        switching = false
        highlighter.reset(next.language)
        renderTabs()
        updateStatus()
    }

    func renderTabs(scrollToSelection: Bool = true) {
        let existing = Dictionary(uniqueKeysWithValues: tabStack.arrangedSubviews.compactMap {
            ($0 as? NoteTab).map { ($0.id, $0) }
        })
        let wanted = Set(notes.map { $0.record.id })
        if existing.count != wanted.count || existing.keys.contains(where: { !wanted.contains($0) }) {
            tabBar.reordering?.cancel()
        }
        for (id, tab) in existing where !wanted.contains(id) {
            tabStack.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        for (index, note) in notes.enumerated() {
            let id = note.record.id
            let tab = existing[id] ?? NoteTab(note: note)
            if existing[id] == nil {
                tab.onSelect = { [weak self] in
                    guard let self, self.activeID != id else { return }
                    do { try self.selectNote(id) }
                    catch { self.showMessage("无法打开草稿", error.localizedDescription) }
                }
                tab.onClose = { [weak self] in self?.closeNote(id) }
            }
            tab.reordering = tabBar.reordering
            if tabStack.arrangedSubviews.firstIndex(of: tab) != index {
                if tab.superview != nil { tabStack.removeArrangedSubview(tab); tab.removeFromSuperview() }
                tabStack.insertArrangedSubview(tab, at: index)
            }
            watchFile(note)
            tab.updateState(for: note)
            tab.selected = id == activeID
        }
        tabStack.layoutSubtreeIfNeeded()
        tabStack.setFrameSize(tabStack.fittingSize)
        if scrollToSelection, let selected = tabStack.arrangedSubviews.compactMap({ $0 as? NoteTab }).first(where: \.selected) {
            tabStack.scrollToVisible(selected.frame)
        }
    }

    func moveNote(_ id: UUID, to index: Int) throws {
        guard notes.indices.contains(index), let oldIndex = notes.firstIndex(where: { $0.record.id == id }) else {
            throw SessionError.invalid("标签位置无效")
        }
        guard index != oldIndex else { return }
        tabBar.reordering?.cancel()
        let oldNotes = notes
        let note = notes.remove(at: oldIndex)
        notes.insert(note, at: index)
        guard saveSession() else {
            notes = oldNotes
            throw SessionError.invalid(lastSaveError ?? "会话保存失败")
        }
        // Move only the dragged control; all intervening controls stay attached.
        if let tab = tabStack.arrangedSubviews.first(where: { ($0 as? NoteTab)?.id == id }) {
            tabStack.removeArrangedSubview(tab)
            tab.removeFromSuperview()
            tabStack.insertArrangedSubview(tab, at: index)
        }
        renderTabs(scrollToSelection: false)
    }

    func textDidChange(_ notification: Notification) {
        guard !switching, !active.isLog else { return }
        active.dirty = true
        active.refreshFileModification()
        updateTabState(active)
        status.stringValue = "正在备份编辑内容…"
        scheduleSave()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !switching, activeID != nil else { return }
        if active.isLog { return }
        highlighter?.schedule()
        position.stringValue = "\(active.language.title) · 第 \(ruler.counter.line(at: editor.selectedRange().location, in: editor.textStorage!.mutableString)) 行 · \(active.encodingTitle)"
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            ruler.counter.invalidate(from: editedRange.location); ruler.needsDisplay = true
            highlighter?.invalidate(from: editedRange.location)
            if !switching, activeID != nil, active.refreshContentTitle(editedFrom: editedRange.location) {
                tabStack.arrangedSubviews.compactMap { $0 as? NoteTab }.first { $0.id == activeID }?.updateTitle(for: active)
            }
        }
    }
    @objc func viewportChanged() { ruler?.needsDisplay = true; highlighter?.schedule() }
    func undoManager(for view: NSTextView) -> UndoManager? {
        guard activeID != nil, !active.isLog else { return nil }
        return active.undo
    }
    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in _ = self?.saveSession() }
    }
    @discardableResult func saveSession() -> Bool {
        guard store != nil, !notes.isEmpty else { return true }
        saveTimer?.invalidate()
        saveTimer = nil
        capturePosition()
        do {
            try store.save(notes: notes, activeID: activeID, windowFrame: window?.frame)
            lastSaveError = nil
            updateStatus()
            return true
        } catch {
            lastSaveError = error.localizedDescription
            status.stringValue = "草稿保存失败，请导出备份"
            status.toolTip = error.localizedDescription
            return false
        }
    }
    func updateStatus() {
        guard editor != nil else { return }
        if active.isLog { logViewer.updateStatus(); return }
        status.stringValue = lastSaveError != nil ? "编辑内容备份失败，请保存文件" : active.fileMissing ? "原文件已移走或删除 · 编辑内容已备份"
            : active.fileChangedExternally ? "原文件已被外部修改 · 编辑内容已备份"
            : active.needsFileSave ? "尚未保存到文件 · 编辑内容已备份" : "文件已保存"
        position.stringValue = "\(active.language.title) · \(active.encodingTitle)"
    }
    func applicationDidResignActive(_ notification: Notification) {
        tabBar?.reordering?.cancel()
        guard saveSession() else { return }
        for note in notes where note.record.id != activeID && !note.undo.canUndo && !note.undo.canRedo {
            note.storage = nil
        }
        // Return unused allocator pages after releasing inactive buffers. This never
        // discards live text or undo history and does not run on the editing thread.
        DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        tabBar?.reordering?.cancel()
        if saveSession() { return .terminateNow }
        showMessage("草稿尚未保存", "请先导出文本再退出。\n\(lastSaveError ?? "")")
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    func windowDidResignKey(_ notification: Notification) { tabBar?.reordering?.cancel() }
    func windowWillClose(_ notification: Notification) { tabBar?.reordering?.cancel() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if editor == nil { pendingOpen.append(contentsOf: filenames) }
        else {
            window?.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            for path in filenames { openText(URL(fileURLWithPath: path)) }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func newNote() {
        tabBar?.reordering?.cancel()
        let oldActiveID = activeID
        let note = Note(name: Note.nextName(in: notes), automaticTitle: true)
        notes.append(note)
        // Render the model change before selecting so a failed save/load cannot
        // leave a tab that exists only in `notes` until the next switch.
        renderTabs()
        do {
            try selectNote(note.record.id)
        } catch {
            notes.removeAll { $0 === note }
            if let oldActiveID, notes.contains(where: { $0.record.id == oldActiveID }) {
                activeID = oldActiveID
                try? selectNote(oldActiveID, saveCurrent: false)
            }
            renderTabs()
            showMessage("无法新建文本", error.localizedDescription)
        }
    }
    @objc func nextNote() { cycle(1) }
    @objc func previousNote() { cycle(-1) }
    func cycle(_ delta: Int) {
        guard let i = notes.firstIndex(where: { $0.record.id == activeID }) else { return }
        do { try selectNote(notes[(i + delta + notes.count) % notes.count].record.id) }
        catch { showMessage("无法切换文本", error.localizedDescription) }
    }
    @objc func closeCurrent() { closeNote(activeID) }
    func closeNote(_ id: UUID, save: ((Note) -> Bool)? = nil) {
        guard let note = notes.first(where: { $0.record.id == id }) else { return }
        do {
            if note.isLog {
                let alert = NSAlert()
                alert.messageText = "关闭“\(note.record.name)”？"
                alert.informativeText = "这只会关闭日志标签，原文件不会被删除。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "关闭文本")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            } else {
                note.refreshFileState()
                let content = try text(for: note)
                if let file = note.record.file { note.record.fileModified = file.differs(from: content as NSString) }
                if note.needsFileSave && (note.record.file != nil || !content.isEmpty) {
                    let response = makeCloseAlert().runModal()
                    if response == .alertSecondButtonReturn {
                        guard save?(note) ?? saveNote(note) else { return }
                    } else if response != .alertThirdButtonReturn { return }
                }
            }
            try removeNote(id)
        } catch { showMessage("无法关闭文本", error.localizedDescription) }
    }

    func makeCloseAlert() -> CloseNoteAlert { CloseNoteAlert() }

    func removeNote(_ id: UUID) throws {
        guard let closingIndex = notes.firstIndex(where: { $0.record.id == id }) else { return }
        tabBar?.reordering?.cancel()
        guard saveSession() else { throw SessionError.invalid(lastSaveError ?? "会话保存失败") }
        let closingActive = activeID == id
        let oldNotes = notes
        let oldActive = activeID
        notes.removeAll { $0.record.id == id }
        if notes.isEmpty { notes = [Note(name: Note.nextName(in: notes), automaticTitle: true)] }
        do {
            if closingActive {
                let destinationIndex = max(0, min(closingIndex - 1, notes.count - 1))
                try selectNote(notes[destinationIndex].record.id, saveCurrent: false)
            }
            guard saveSession() else { throw SessionError.invalid(lastSaveError ?? "会话保存失败") }
            renderTabs()
        } catch {
            notes = oldNotes
            try selectNote(oldActive!, saveCurrent: false)
            throw error
        }
    }
    @objc func renameNote() {
        guard active.record.file == nil, !active.isLog else { return }
        let alert = NSAlert()
        alert.messageText = "重命名文本"
        let field = NSTextField(string: active.record.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { active.rename(to: name); highlighter.reset(active.language); renderTabs(); _ = saveSession() }
        }
    }
    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(openText) }
    }
    @objc func openLogPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = "以只读日志模式打开"
        if panel.runModal() == .OK { panel.urls.forEach { openText($0, asLog: true) } }
    }
    func openText(_ url: URL) { openText(url, asLog: false) }
    func openText(_ url: URL, asLog: Bool) {
        do {
            if try !openDocument(url, asLog: asLog) {
                showMessage("文件已打开，但编辑内容备份失败", lastSaveError ?? "请保存文件后重试备份。")
            }
        } catch { showMessage("无法打开文本", error.localizedDescription) }
    }

    // A thrown error means selection failed; false means the visible document is
    // open but its final session backup failed and must be retried.
    @discardableResult func openDocument(_ source: URL, asLog: Bool = false) throws -> Bool {
        let url = DocumentFile.canonical(source)
        let isLog = try asLog || (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 8 * 1_048_576
        if let existing = notes.first(where: { note in
            guard note.isLog == isLog, let path = isLog ? note.record.logPath : note.record.file?.path else { return false }
            return DocumentFile.canonical(URL(fileURLWithPath: path)).path == url.path
        }) {
            try selectNote(existing.record.id)
            return saveSession()
        }
        let note: Note
        if isLog {
            // Reject unsupported content before changing tabs or starting the index.
            let file = try LogFile(url: url)
            note = Note(record: NoteRecord(id: UUID(), name: url.lastPathComponent,
                draftFile: "", selection: 0, scrollY: 0, logPath: url.path, logOffset: 0))
            note.logFile = file
        } else { note = try DocumentFile.open(url) }
        tabBar?.reordering?.cancel()
        notes.append(note)
        do {
            try selectNote(note.record.id)
        } catch {
            notes.removeAll { $0 === note }
            renderTabs()
            throw error
        }
        return saveSession()
    }
    @objc func exportText() {
        _ = exportNote(active)
    }
    func text(for note: Note) throws -> String {
        if let storage = note.storage { return storage.string }
        return try store.text(for: note.record)
    }
    func writeText(_ note: Note, to url: URL) throws {
        try text(for: note).write(to: url, atomically: true, encoding: .utf8)
    }
    @discardableResult func exportNote(_ note: Note) -> Bool {
        guard !note.isLog else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.record.name.contains(".") ? note.record.name : note.record.name + ".txt"
        panel.title = "导出 UTF-8 文本"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return exportNote(note, to: url)
    }
    @discardableResult func exportNote(_ note: Note, to url: URL) -> Bool {
        do { try writeText(note, to: url); return true }
        catch { showMessage("导出失败", error.localizedDescription) }
        return false
    }
    @objc func largerFont() { setFontSize(min(28, (editor.font?.pointSize ?? 14) + 1)) }
    @objc func smallerFont() { setFontSize(max(10, (editor.font?.pointSize ?? 14) - 1)) }
    func setFontSize(_ size: CGFloat) { editor.font = .monospacedSystemFont(ofSize: size, weight: .regular); ruler.needsDisplay = true }
    @objc func formatJSON() {
        guard !active.isLog else { return }
        do { try applyJSONFormat() }
        catch { showMessage("JSON 格式化失败，原文未改动", error.localizedDescription) }
    }
    func applyJSONFormat() throws {
        let selected = editor.selectedRange()
        let range = selected.length > 0 ? selected : NSRange(location: 0, length: editor.textStorage!.length)
        let original = (editor.string as NSString).substring(with: range)
        let formatted = try JSONFormatter.format(original)
        guard formatted != original else { return }
        editor.breakUndoCoalescing()
        editor.insertText(formatted, replacementRange: range)
        editor.breakUndoCoalescing()
        active.undo.setActionName("格式化 JSON")
        editor.setSelectedRange(NSRange(location: range.location, length: (formatted as NSString).length))
    }
    @objc func showFind() {
        if active.isLog { logViewer.focusSearch() }
        else {
            let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performFindPanelAction(sender)
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
    @objc func showReplace() {
        guard !active.isLog else { return }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        editor.performFindPanelAction(sender)
        editor.scrollRangeToVisible(editor.selectedRange())
    }
    @objc func findNext() {
        if active.isLog { logViewer.findNext() }
        else {
            let sender = NSMenuItem(); sender.tag = NSTextFinder.Action.nextMatch.rawValue
            editor.performFindPanelAction(sender)
        }
    }
    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard activeID != nil, !active.isLog, let choice = sender.representedObject as? String,
              choice == "auto" || TextLanguage(rawValue: choice) != nil else { return }
        active.record.syntax = choice == "auto" ? nil : choice
        highlighter.reset(active.language)
        _ = saveSession()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeLanguage(_:)) {
            guard activeID != nil else { return false }
            menuItem.state = (menuItem.representedObject as? String) == (active.record.syntax ?? "auto") ? .on : .off
            return !active.isLog
        }
        if menuItem.action == #selector(renameNote) { return activeID != nil && !active.isLog && active.record.file == nil }
        if menuItem.action == #selector(formatJSON) || menuItem.action == #selector(exportText) || menuItem.action == #selector(saveText) || menuItem.action == #selector(saveTextAs) || menuItem.action == #selector(showReplace) {
            return activeID != nil && !active.isLog
        }
        return true
    }
    @objc func showFileAssociations() {
        if let controller = fileAssociationWindowController {
            controller.showWindow(nil)
            return
        }
        do {
            let controller = try FileAssociationWindowController(service: FileAssociationService())
            controller.onClose = { [weak self] in self?.fileAssociationWindowController = nil }
            fileAssociationWindowController = controller
            controller.showWindow(nil)
        } catch {
            showMessage("文件关联", error.localizedDescription)
        }
    }
    @objc func showDraftFolder() { NSWorkspace.shared.open(store.directory) }
    @objc func performance() {
        let sample = memorySample()
        let size = window.contentView!.bounds.size
        showMessage("\(AppEdition.name) · 性能信息", String(format:
            "当前内存：%.1f MiB\n本次运行峰值：%.1f MiB\n驻留内存 RSS：%.1f MiB\n打开标签：%d\n窗口：%.0f × %.0f · %.0f 倍像素\n\n使用 phys_footprint；不包含 WindowServer。大窗口、字体缓存和撤销历史也会占用内存。",
            sample["footprintMiB"] ?? 0, sample["peakFootprintMiB"] ?? 0, sample["residentMiB"] ?? 0,
            notes.count, size.width, size.height, window.backingScaleFactor))
    }
    @objc func about() {
        showMessage(AppEdition.name, "\(AppEdition.version) · \(AppEdition.description)\n\n随手记，轻一点。\n经典 Monokai · SQL / YAML / TOML 基础高亮\n支持纯文本、多标签、自动恢复、查找替换、JSON 格式化、行号与大日志分段查看。")
    }
    func showMessage(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
