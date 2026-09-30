import AppKit

// Exercise real close dialogs and file writes without global input events.
// The system file picker is replaced with a deterministic destination/cancel result.
func runLifecycleCheck(app: Textlet, output: URL) {
    Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
        var checks: [String: Bool] = [:]
        var capturedDialog = false
        func contains(_ note: Note) -> Bool { app.notes.contains { $0 === note } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func close(_ note: Note, buttons: [String], saveAs: String? = nil) {
            print("Closing test: \(note.record.name), \(buttons), saveAs=\(saveAs ?? "cancel")"); fflush(stdout)
            var remaining = buttons
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            let captureAfter = ProcessInfo.processInfo.systemUptime + 0.8
            func wakeModalLoop() {
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                if ProcessInfo.processInfo.systemUptime > deadline {
                    checks["modalCompletedBeforeTimeout"] = false
                    NSApp.stopModal(withCode: .abort); wakeModalLoop(); return
                }
                guard let modal = NSApp.modalWindow, let title = remaining.first else { return }
                if !capturedDialog, !CommandLine.arguments.contains("--no-screenshot"), let content = modal.contentView,
                   descendants(content).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "您想保存对文件所做的更改吗？" }) {
                    // Wait for the native window's opening animation to settle.
                    guard ProcessInfo.processInfo.systemUptime >= captureAfter else { return }
                    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(modal.windowNumber), .boundsIgnoreFraming) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathExtension("dialog.png"))
                    }
                    capturedDialog = true
                }
                if title == "__escape__" || title == "__return__" {
                    remaining.removeFirst()
                    let escape = title == "__escape__"
                    let key = escape ? "\u{1b}" : "\r"
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: modal.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                        isARepeat: false, keyCode: escape ? 53 : 36)!
                    modal.sendEvent(event)
                    wakeModalLoop()
                } else if let button = modal.contentView.map(descendants)?.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) {
                    remaining.removeFirst()
                    button.performClick(nil)
                    wakeModalLoop()
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            app.closeNote(note.record.id, save: { target in
                guard let saveAs else { return false }
                return app.exportNote(target, to: output.deletingLastPathComponent().appendingPathComponent(saveAs))
            })
            timer.invalidate()
            checks["allRequestedButtonsClicked"] = (checks["allRequestedButtonsClicked"] ?? true) && remaining.isEmpty
        }
        do {
            checks["tabScrollerUsesOverlayAfterLaunch"] = app.tabScroller.scrollerStyle == .overlay
            app.tabScroller.scrollerStyle = .legacy
            checks["systemStyleCannotMakeTabScrollerPermanent"] = app.tabScroller.scrollerStyle == .overlay
            let empty = app.active
            checks["firstLaunchStartsAtText1"] = empty.record.name == "文本1"
            app.newNote()
            let second = app.active
            app.newNote()
            let third = app.active
            checks["newTabsUseConsecutiveTextNames"] = second.record.name == "文本2" && third.record.name == "文本3"
            close(second, buttons: [])
            app.newNote()
            let fourth = app.active
            checks["newTabAfterClosingMiddleUsesMaximum"] = fourth.record.name == "文本4"
            close(fourth, buttons: [])
            close(third, buttons: [])
            close(empty, buttons: [])
            checks["lastEmptyTabClosesWithoutDialog"] = !contains(empty) && app.notes.count == 1 && app.editor.string.isEmpty

            checks["lastTabReplacementStartsAtText1"] = app.active.record.name == "文本1"

            let primary = app.active
            app.editor.insertText("当前标签 中文🙂", replacementRange: NSRange(location: 0, length: 0))
            app.editor.breakUndoCoalescing()
            close(primary, buttons: ["取消"])
            checks["cancelPreservesTextAndUndo"] = contains(primary) && app.editor.string == "当前标签 中文🙂" && primary.undo.canUndo
            close(primary, buttons: ["__escape__"])
            checks["escapeCancelsClose"] = contains(primary) && app.editor.string == "当前标签 中文🙂"
            close(primary, buttons: ["__return__"])
            checks["returnKeepsCancelDefault"] = contains(primary) && app.editor.string == "当前标签 中文🙂"

            app.newNote()
            let cleared = app.active
            app.editor.insertText("删除这些字", replacementRange: NSRange(location: 0, length: 0))
            app.editor.insertText("", replacementRange: NSRange(location: 0, length: app.editor.string.utf16.count))
            close(cleared, buttons: [])
            checks["clearedTabClosesWithoutDialog"] = !contains(cleared) && app.active === primary

            let whitespace = Note(name: "空白字符", text: " \t\n")
            app.notes.append(whitespace); app.renderTabs()
            close(whitespace, buttons: ["取消"])
            checks["whitespaceCountsAsContent"] = contains(whitespace)
            close(whitespace, buttons: ["不保存"])
            checks["discardInactiveKeepsActiveText"] = !contains(whitespace) && app.active === primary && app.editor.string == "当前标签 中文🙂"

            let background = Note(name: "后台笔记", text: "后台正文\r\n中文🙂\t --literal")
            app.notes.append(background); app.renderTabs()
            guard app.saveSession() else { throw SessionError.invalid("fixture save failed") }
            background.storage = nil
            close(background, buttons: ["保存"])
            checks["cancelDestinationKeepsInactiveTab"] = contains(background) && app.active === primary
            close(background, buttons: ["保存"], saveAs: "saved-background.txt")
            let exported = try String(contentsOf: output.deletingLastPathComponent().appendingPathComponent("saved-background.txt"), encoding: .utf8)
            checks["saveInactiveExportsCorrectTextThenCloses"] = exported == "后台正文\r\n中文🙂\t --literal" && !contains(background) && app.active === primary

            let unloadedEmpty = Note(name: "未加载的空草稿")
            app.notes.append(unloadedEmpty); _ = app.saveSession(); unloadedEmpty.storage = nil
            close(unloadedEmpty, buttons: [])
            checks["unloadedEmptyClosesWithoutDialog"] = !contains(unloadedEmpty)

            let missing = Note(name: "读取失败", text: "不可丢失")
            app.notes.append(missing); _ = app.saveSession(); missing.storage = nil
            let revision = app.store.drafts.appendingPathComponent(missing.record.draftFile)
            let bytes = try Data(contentsOf: revision)
            try FileManager.default.removeItem(at: revision)
            close(missing, buttons: ["好"])
            checks["readFailureKeepsTab"] = contains(missing) && app.active === primary
            try bytes.write(to: revision)
            // A missing replacement buffer previously left activeID referring to
            // a removed note. Verify the transaction restores the original tabs.
            try app.selectNote(missing.record.id)
            let primaryRevision = app.store.drafts.appendingPathComponent(primary.record.draftFile)
            let primaryBytes = try Data(contentsOf: primaryRevision)
            primary.storage = nil
            try FileManager.default.removeItem(at: primaryRevision)
            var failed = false
            do { try app.removeNote(missing.record.id) } catch { failed = true }
            checks["failedCloseRollsBackTabsAndActiveID"] = failed && contains(missing) && contains(primary) && app.active === missing
            try primaryBytes.write(to: primaryRevision)
            try app.selectNote(primary.record.id)
            close(missing, buttons: ["不保存"])

            let badDestination = output.deletingLastPathComponent().appendingPathComponent("missing-parent/file.txt")
            var writeFailed = false
            do { try app.writeText(primary, to: badDestination) } catch { writeFailed = true }
            checks["failedWritePreservesText"] = writeFailed && contains(primary) && app.editor.string == "当前标签 中文🙂"
            close(primary, buttons: ["保存", "好"], saveAs: "missing-parent/file.txt")
            checks["saveFailureKeepsTabAndText"] = contains(primary) && app.editor.string == "当前标签 中文🙂"

            let alert = app.makeCloseAlert()
            alert.layout()
            let buttons = alert.buttons
            let frames = buttons.map { $0.convert($0.bounds, to: nil) }
            checks["closePromptExact"] = alert.messageText == "您想保存对文件所做的更改吗？"
            checks["buttonsLeftToRight"] = frames[2].minX < frames[1].minX && frames[1].minX < frames[0].minX
                && abs(frames[0].minY - frames[2].minY) < 1
            checks["cancelRemainsDefault"] = buttons[0].keyEquivalent == "\r" && buttons[1].keyEquivalent.isEmpty && buttons[2].keyEquivalent.isEmpty
            close(primary, buttons: ["保存"], saveAs: "saved-active.txt")
            let savedActive = try String(contentsOf: output.deletingLastPathComponent().appendingPathComponent("saved-active.txt"), encoding: .utf8)
            checks["saveLastActiveThenCreateEmptyTab"] = !contains(primary) && app.notes.count == 1 && app.editor.string.isEmpty && savedActive == "当前标签 中文🙂"
            checks["savedSessionContainsOnlyRemainingTab"] = try app.store.load()?.notes.map(\.id) == app.notes.map { $0.record.id }
        } catch { checks["completed"] = false; print("Lifecycle failure: \(error)") }
        do {
            try JSONSerialization.data(withJSONObject: ["checks": checks, "memory": memorySample(), "systemFilePickerStubbed": true], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        } catch { fputs("Lifecycle report failed: \(error)\n", stderr) }
        print("Lifecycle checks: \(checks)")
        NSApp.terminate(nil)
    }
}

func runWindowCheck(app: Textlet, output: URL) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        var checks: [String: Bool] = [:]
        if let previous = app.restoredWindowFrame {
            checks["restoredFrameMatchesPreviousExit"] = app.window.frame == Textlet.visibleWindowFrame(previous,
                screens: NSScreen.screens.map(\.visibleFrame), minimum: app.window.minSize)
        } else { checks["firstLaunchUsesDefaultSize"] = app.window.contentView?.bounds.size == NSSize(width: 860, height: 590) }
        switch Textlet.argument("--window-size") {
        case "zoom": app.window.zoom(nil)
        case "small": app.window.setContentSize(NSSize(width: 860, height: 590)); app.window.center()
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if Textlet.argument("--window-size") == "zoom" { checks["nativeZoomFillsScreen"] = app.window.isZoomed }
            let frame = app.window.frame
            checks["quitSavesSession"] = app.applicationShouldTerminate(NSApp) == .terminateNow
            checks["exitFramePersisted"] = (try? app.store.load()?.windowFrame) == frame
            let report: [String: Any] = ["checks": checks, "frame": NSStringFromRect(frame), "zoomed": app.window.isZoomed]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("Window checks: \(report)")
            NSApp.terminate(nil)
        }
    }
}
