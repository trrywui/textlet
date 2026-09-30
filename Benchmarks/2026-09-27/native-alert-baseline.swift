import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            let alert = NSAlert()
            alert.messageText = "原生 NSAlert 内存基线"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "关闭笔记")
            let timer = Timer(timeInterval: 1, repeats: false) { _ in
                alert.buttons[0].performClick(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: false) }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
