import AppKit

private final class CloseNotePanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
    }
}

// NSAlert stacks three buttons vertically on macOS 14. Use native buttons in
// a fixed horizontal row, keeping Cancel's default tint and Return behavior.
final class CloseNoteAlert: NSObject {
    let messageText = "您想保存对文件所做的更改吗？"
    let window: NSPanel = CloseNotePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private(set) var buttons: [NSButton] = []

    override init() {
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(x: 186, y: 130, width: 48, height: 48)
        content.addSubview(icon)
        let label = NSTextField(labelWithString: messageText)
        label.font = .boldSystemFont(ofSize: 13)
        label.alignment = .center
        label.frame = NSRect(x: 24, y: 86, width: 372, height: 24)
        content.addSubview(label)
        for (index, title) in ["取消", "保存", "不保存"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(respond(_:)))
            button.bezelStyle = .rounded
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
            button.frame = NSRect(x: 284 - index * 126, y: 20, width: 104, height: 32)
            content.addSubview(button)
            buttons.append(button)
        }
        buttons[0].keyEquivalent = "\r"
        window.defaultButtonCell = buttons[0].cell as? NSButtonCell
        window.initialFirstResponder = buttons[0]
        buttons[2].nextKeyView = buttons[1]
        buttons[1].nextKeyView = buttons[0]
        buttons[0].nextKeyView = buttons[2]
    }

    func layout() { window.contentView?.layoutSubtreeIfNeeded() }

    func runModal() -> NSApplication.ModalResponse {
        window.center()
        defer { window.orderOut(nil) }
        return NSApp.runModal(for: window)
    }

    @objc private func respond(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }
}
