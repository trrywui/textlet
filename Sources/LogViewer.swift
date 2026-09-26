import AppKit

final class LogViewer: NSObject, NSSearchFieldDelegate {
    unowned let app: Textlet
    let bar = NSView()
    var height: NSLayoutConstraint!
    let searchField = NSSearchField()
    let message = NSTextField(labelWithString: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    var navigation: [NSButton] = []
    var searchButton: NSButton!
    var file: LogFile?
    var index: LogIndex?
    var page: LogPage?
    var indexCancellation = Cancellation()
    var searchCancellation = Cancellation()
    var generation = UUID()
    var lastQuery = ""
    var lastMatch: Int64?
    var loading = false
    var onReady: (() -> Void)?
    var onSearchFinished: ((Int64?) -> Void)?
    init(app: Textlet) { self.app = app; super.init() }
    deinit { indexCancellation.cancel(); searchCancellation.cancel() }
    func build() {
        bar.translatesAutoresizingMaskIntoConstraints = false
        height = bar.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        bar.isHidden = true
        func button(_ title: String, _ selector: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: selector)
            b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11)
            return b
        }
        navigation = [button("开头", #selector(first)), button("上一段", #selector(previous)),
                      button("下一段", #selector(next)), button("末尾", #selector(last))]
        slider.target = self; slider.action = #selector(jump); slider.isContinuous = false
        slider.toolTip = "按文件位置跳转（松开后读取）"
        slider.setAccessibilityLabel("日志文件位置")
        let reload = button("重新载入", #selector(reloadFile))
        let top = NSStackView(views: navigation + [slider, reload])
        top.spacing = 5
        searchField.placeholderString = "全文件查找（区分大小写）"
        searchField.target = self; searchField.action = #selector(findNext)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.font = .systemFont(ofSize: 12)
        searchButton = button("下一个 ⌘G", #selector(findNext))
        let cancel = button("停止", #selector(cancelSearch))
        message.font = .systemFont(ofSize: 11); message.textColor = Theme.muted
        message.lineBreakMode = .byTruncatingMiddle
        let bottom = NSStackView(views: [searchField, searchButton, cancel, message])
        bottom.spacing = 6
        for row in [top, bottom] {
            row.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(row)
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10).isActive = true
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10).isActive = true
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4), top.heightAnchor.constraint(equalToConstant: 27),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 3), bottom.heightAnchor.constraint(equalToConstant: 27),
            searchField.widthAnchor.constraint(equalToConstant: 220), slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 50)
        ])
    }
    func leave() {
        indexCancellation.cancel(); searchCancellation.cancel(); generation = UUID()
        file = nil; index = nil; page = nil; lastMatch = nil; lastQuery = ""
        loading = false
        bar.isHidden = true; height.constant = 0
    }
    func select(_ note: Note) {
        leave()
        bar.isHidden = false; height.constant = 66
        navigation.forEach { $0.isEnabled = false }; slider.isEnabled = false; searchButton.isEnabled = false
        app.scroller.isFindBarVisible = false
        app.editor.isEditable = false; app.editor.allowsUndo = false
        app.editor.layoutManager!.replaceTextStorage(NSTextStorage())
        app.ruler.reset()
        let savedOffset = note.record.logOffset ?? 0
        let savedScroll = note.record.scrollY
        do {
            if let cached = note.logFile, let cachedIndex = note.logIndex, (try? cached.validate()) != nil {
                file = cached; index = cachedIndex
                navigation.forEach { $0.isEnabled = true }; slider.isEnabled = true; searchButton.isEnabled = true
                app.window.makeFirstResponder(app.editor)
                try display(at: savedOffset, scrollY: savedScroll)
                message.stringValue = "共 \(cachedIndex.lines) 行 · 按段查看"
                app.window.makeFirstResponder(app.editor)
                return
            }
            let file = try LogFile(url: URL(fileURLWithPath: note.record.logPath!))
            self.file = file
            try display(at: 0)
            // Keep the saved position while the index is being built.
            loading = true
            note.record.logOffset = savedOffset; note.record.scrollY = savedScroll
            message.stringValue = "正在建立行号索引…"
            let token = Cancellation(); indexCancellation = token
            let id = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    let result = try file.makeIndex(cancel: token) { fraction in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == id else { return }
                            self.message.stringValue = "索引 \(Int(fraction * 100))% · 可查看开头"
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id, let result else { return }
                        self.index = result; self.loading = false
                        note.logFile = file; note.logIndex = result
                        self.navigation.forEach { $0.isEnabled = true }; self.slider.isEnabled = true; self.searchButton.isEnabled = true
                        do {
                            try self.display(at: savedOffset, scrollY: savedScroll)
                            self.message.stringValue = "共 \(result.lines) 行 · 按段查看"
                            self.onReady?()
                        } catch { self.fail(error) }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }; self.loading = false; self.fail(error)
                    }
                }
            }
        } catch { fail(error) }
        app.window.makeFirstResponder(app.editor)
    }
    func fail(_ error: Error) {
        message.stringValue = error.localizedDescription; message.toolTip = error.localizedDescription
    }
    func display(at offset: Int64, scrollY: Double = 0, match: Int64? = nil, query: String = "") throws {
        guard let file else { return }
        let next = try file.page(at: offset, index: index)
        let storage = NSTextStorage(string: next.text, attributes: [
            .font: app.editor.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: Theme.text
        ])
        app.switching = true
        defer { app.switching = false }
        app.editor.layoutManager!.replaceTextStorage(storage)
        page = next
        app.active.record.logOffset = next.start
        app.ruler.reset(firstLine: next.firstLine, continuation: next.startsMidLine, log: true)
        app.editor.setSelectedRange(NSRange(location: 0, length: 0))
        app.editor.didChangeText()
        app.window.contentView?.layoutSubtreeIfNeeded()
        app.editor.setFrameSize(NSSize(width: app.scroller.contentSize.width, height: app.editor.frame.height))
        app.editor.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: scrollY,
            width: app.scroller.contentSize.width, height: app.scroller.contentSize.height), in: app.editor.textContainer!)
        let y = min(scrollY, max(0, app.editor.bounds.height - app.scroller.contentSize.height))
        app.scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
        app.scroller.reflectScrolledClipView(app.scroller.contentView)
        if let match, match >= next.start, match < next.end {
            let prefix = try file.read(next.start, count: Int(match - next.start))
            let location = String(decoding: prefix, as: UTF8.self).utf16.count
            let length = min(query.utf16.count, max(0, storage.length - location))
            app.editor.setSelectedRange(NSRange(location: location, length: length))
            app.editor.scrollRangeToVisible(app.editor.selectedRange())
        }
        app.active.record.scrollY = Double(app.scroller.contentView.bounds.origin.y)
        slider.doubleValue = file.size > 0 ? Double(next.start) / Double(file.size) : 0
        app.editor.needsDisplay = true
        updateStatus()
    }
    func updateStatus() {
        guard let file, let page else {
            app.status.stringValue = "只读日志 · 文件无法读取，可重新载入或关闭标签"
            app.position.stringValue = "只读"; return
        }
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        app.status.stringValue = "只读 · \(size) · 字节 \(page.start + (file.size == 0 ? 0 : 1))–\(page.end)"
        app.position.stringValue = page.repairedUTF8 ? "UTF-8 · 无效字节显示为 �" : "UTF-8 · 第 \(page.firstLine) 行起"
    }
    func move(to offset: Int64) {
        guard index != nil else { return }
        cancelSearch()
        do { try display(at: offset); app.scheduleSave() }
        catch { fail(error) }
    }
    @objc func first() { move(to: 0) }
    @objc func last() { move(to: max(0, (file?.size ?? 0) - Int64(LogFile.pageSize / 2))) }
    @objc func previous() { move(to: max(0, (page?.start ?? 0) - Int64(LogFile.pageSize * 3 / 4))) }
    @objc func next() { if let page, page.end < (file?.size ?? 0) { move(to: page.end) } }
    @objc func jump() { move(to: Int64(slider.doubleValue * Double(file?.size ?? 0))) }
    @objc func reloadFile() {
        app.capturePosition(); app.active.logFile = nil; app.active.logIndex = nil; select(app.active)
    }
    @objc func cancelSearch() {
        searchCancellation.cancel()
        if index != nil { message.stringValue = "共 \(index!.lines) 行 · 按段查看" }
    }
    func focusSearch() { app.window.makeFirstResponder(searchField) }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = searchField.currentEditor() as? NSTextView else { return }
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.smartInsertDeleteEnabled = false
        field.enabledTextCheckingTypes = 0
    }
    @objc func findNext() {
        guard let file, index != nil else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else { focusSearch(); return }
        searchCancellation.cancel()
        let token = Cancellation(); searchCancellation = token
        let start = query == lastQuery ? (lastMatch.map { $0 + 1 } ?? page?.start ?? 0) : page?.start ?? 0
        let id = generation
        lastQuery = query; message.stringValue = "正在搜索整个文件…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var result = try file.search(query, from: start, cancel: token) { fraction in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id, !token.cancelled else { return }
                        self.message.stringValue = "搜索至 \(Int(fraction * 100))%"
                    }
                }
                var wrapped = false
                if result == nil && start > 0 && !token.cancelled {
                    wrapped = true
                    result = try file.search(query, from: 0, to: min(file.size, start + Int64(query.utf8.count - 1)), cancel: token)
                }
                let found = result, didWrap = wrapped
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, !token.cancelled else { return }
                    self.lastMatch = found
                    if let found {
                        do {
                            try self.display(at: found, match: found, query: query)
                            self.message.stringValue = didWrap ? "已从开头继续查找" : "已找到 · 再按 ⌘G 查找下一个"
                            self.app.scheduleSave()
                        } catch { self.fail(error) }
                    } else { self.message.stringValue = "整个文件中未找到" }
                    self.onSearchFinished?(found)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id, !token.cancelled else { return }; self.fail(error)
                }
            }
        }
    }
}
