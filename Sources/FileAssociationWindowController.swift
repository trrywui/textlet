import AppKit

private final class FileAssociationListView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class FileAssociationRowView: NSView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    var onToggle: ((Bool) -> Void)?

    init(item: FileAssociationItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        checkbox.setAccessibilityLabel("选择\(item.title)")
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = item.extensions.count > 1
            ? "这些扩展名将同时生效。" : ""
        detailLabel.isHidden = item.extensions.count <= 1
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = Theme.muted
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.maximumNumberOfLines = 0
        resultLabel.lineBreakMode = .byWordWrapping
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.isHidden = true

        let labels = NSStackView(views: [titleLabel, detailLabel, resultLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(labels)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            resultLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(checked: Bool, enabled: Bool, result: FileAssociationWindowController.RowResult?,
                resolutionError: String?) {
        checkbox.state = checked ? NSControl.StateValue.on : NSControl.StateValue.off
        checkbox.isEnabled = enabled
        if let result {
            switch result {
            case .success(let message):
                resultLabel.stringValue = message
                resultLabel.textColor = .systemGreen
            case .failure(let message):
                resultLabel.stringValue = message
                resultLabel.textColor = .systemRed
            }
        } else if let resolutionError {
            resultLabel.stringValue = "无法设置：\(resolutionError)"
            resultLabel.textColor = .systemRed
        } else {
            resultLabel.stringValue = ""
        }
        resultLabel.isHidden = result == nil && resolutionError == nil
    }

    @objc private func toggle(_ sender: NSButton) {
        onToggle?(sender.state == .on)
    }
}

final class FileAssociationWindowController: NSWindowController, NSWindowDelegate {
    enum RowResult {
        case success(String)
        case failure(String)
    }

    private struct RowState {
        let item: FileAssociationItem
        var actualDefault: Bool
        var checked: Bool
        var result: RowResult?
    }

    private let service: FileAssociationServicing
    private var rows: [RowState]
    private var rowViews: [FileAssociationRowView] = []
    private var failedItemIDs = Set<String>()
    private var applying = false
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "重试失败项", target: nil, action: nil)
    private let applyButton = NSButton(title: "设为默认", target: nil, action: nil)
    private let allButton = NSButton(title: "全选", target: nil, action: nil)
    private let noneButton = NSButton(title: "取消全选", target: nil, action: nil)

    init(service: FileAssociationServicing) {
        self.service = service
        let states = service.currentStates()
        self.rows = service.items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { item in
            let actual = states[item.identifier] ?? false
            return RowState(item: item, actualDefault: actual, checked: actual, result: nil)
        }
        super.init(window: nil)

        let listHeight = rows.reduce(CGFloat(12)) { $0 + ($1.item.extensions.count > 1 ? 50 : 34) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: min(560, max(400, listHeight + 168))),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "文件关联"
        window.backgroundColor = Theme.chrome
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        buildInterface()
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshFromApplicationActivation() {
        reloadFromSystem(resetSelection: false)
    }

    func reloadFromSystem(resetSelection: Bool) {
        guard !applying else { return }
        let states = service.currentStates()
        let hasManualSelection = rows.contains { $0.checked != $0.actualDefault }
        for index in rows.indices {
            let actual = states[rows[index].item.identifier] ?? false
            rows[index].actualDefault = actual
            if resetSelection || !hasManualSelection {
                rows[index].checked = actual
            }
            if resetSelection { rows[index].result = nil }
        }
        if resetSelection { failedItemIDs.removeAll() }
        render()
    }

    override func showWindow(_ sender: Any?) {
        reloadFromSystem(resetSelection: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reloadFromSystem(resetSelection: false)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    var onClose: (() -> Void)?

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.chrome.cgColor

        let intro = NSTextField(labelWithString: "选择需要由 Textlet 默认打开的文件类型。")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = Theme.text
        intro.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "取消勾选不会更改现有默认应用。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.muted
        hint.translatesAutoresizingMaskIntoConstraints = false

        let listTitle = NSTextField(labelWithString: "文件类型")
        listTitle.font = .systemFont(ofSize: 12, weight: .medium)
        listTitle.textColor = Theme.text
        listTitle.translatesAutoresizingMaskIntoConstraints = false

        for button in [allButton, noneButton, retryButton, applyButton] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        allButton.target = self; allButton.action = #selector(selectAllRows)
        noneButton.target = self; noneButton.action = #selector(selectNoRows)
        retryButton.target = self; retryButton.action = #selector(retryFailed)
        applyButton.target = self; applyButton.action = #selector(applySelection)
        applyButton.keyEquivalent = "\r"
        for button in [allButton, noneButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }

        let selectionButtons = NSStackView(views: [allButton, noneButton])
        selectionButtons.orientation = .horizontal
        selectionButtons.spacing = 8
        selectionButtons.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = FileAssociationListView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        rowStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            let view = FileAssociationRowView(item: row.item)
            view.onToggle = { [weak self] checked in self?.setChecked(checked, at: index) }
            rowViews.append(view)
            rowStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.canvas
        scroll.borderType = .lineBorder
        scroll.documentView = rowStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.muted
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [retryButton, applyButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.setHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)
        applyButton.setContentHuggingPriority(.required, for: .horizontal)

        for view in [intro, hint, listTitle, selectionButtons, scroll, statusLabel, actions] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            hint.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 6),
            selectionButtons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            selectionButtons.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            listTitle.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            listTitle.centerYAnchor.constraint(equalTo: selectionButtons.centerYAnchor),
            listTitle.trailingAnchor.constraint(lessThanOrEqualTo: selectionButtons.leadingAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: selectionButtons.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -68),
            actions.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func setChecked(_ checked: Bool, at index: Int) {
        guard !applying, rows.indices.contains(index) else { return }
        rows[index].checked = checked
        if !checked { failedItemIDs.remove(rows[index].item.identifier) }
        render()
    }

    @objc private func selectAllRows() {
        guard !applying else { return }
        for index in rows.indices where rows[index].item.isAvailable { rows[index].checked = true }
        render()
    }

    @objc private func selectNoRows() {
        guard !applying else { return }
        for index in rows.indices { rows[index].checked = false }
        failedItemIDs.removeAll()
        render()
    }

    @objc private func applySelection() {
        guard !applying else { return }
        let states = service.currentStates()
        for index in rows.indices {
            rows[index].actualDefault = states[rows[index].item.identifier] ?? false
        }
        let pending = rows.indices.filter { index in
            rows[index].item.isAvailable && rows[index].checked && !rows[index].actualDefault
        }
        guard !pending.isEmpty else {
            statusLabel.stringValue = "没有需要修改的类型。"
            render()
            return
        }

        failedItemIDs.removeAll()
        for index in rows.indices { rows[index].result = nil }
        applying = true
        statusLabel.stringValue = "准备设置…"
        render()
        process(pending, at: 0)
    }

    @objc private func retryFailed() {
        guard !applying, !failedItemIDs.isEmpty else { return }
        let states = service.currentStates()
        var pending: [Int] = []
        for index in rows.indices where failedItemIDs.contains(rows[index].item.identifier) {
            let actual = states[rows[index].item.identifier] ?? false
            rows[index].actualDefault = actual
            if actual {
                rows[index].checked = true
                rows[index].result = .success("设置已生效。")
                failedItemIDs.remove(rows[index].item.identifier)
            } else if rows[index].checked {
                pending.append(index)
            } else {
                failedItemIDs.remove(rows[index].item.identifier)
            }
        }
        guard !pending.isEmpty else {
            statusLabel.stringValue = failedItemIDs.isEmpty ? "没有仍需重试的失败项。" : "失败项已跳过。"
            render()
            return
        }

        applying = true
        statusLabel.stringValue = "准备重试…"
        render()
        process(pending, at: 0)
    }

    private func process(_ indexes: [Int], at position: Int) {
        guard position < indexes.count else {
            refreshAllActualStatesAfterProcessing()
            applying = false
            statusLabel.stringValue = failedItemIDs.isEmpty ? "处理完成。" : "部分类型设置失败，可重试失败项。"
            render()
            return
        }

        let index = indexes[position]
        let item = rows[index].item
        statusLabel.stringValue = "正在处理 \(position + 1)/\(indexes.count)：\(item.title)"
        render()
        service.setDefault(for: item) { [weak self] result in
            guard let self else { return }
            let actual = self.service.isTextletDefault(for: item)
            self.rows[index].actualDefault = actual
            if actual {
                self.rows[index].checked = true
                self.rows[index].result = .success("设置成功，已核验生效。")
                self.failedItemIDs.remove(item.identifier)
            } else {
                // Keep the user's selection so a failed item remains retryable.
                let message: String
                switch result {
                case .success:
                    message = FileAssociationFailure.notEffective.localizedDescription
                case .failure(let error):
                    message = error.localizedDescription
                }
                self.rows[index].result = .failure("设置失败：\(message)")
                self.failedItemIDs.insert(item.identifier)
            }
            self.render()
            self.process(indexes, at: position + 1)
        }
    }

    private func refreshAllActualStatesAfterProcessing() {
        // Actual defaults and the user's pending selections are independent.
        let states = service.currentStates()
        for index in rows.indices {
            let actual = states[rows[index].item.identifier] ?? false
            rows[index].actualDefault = actual
            if actual { failedItemIDs.remove(rows[index].item.identifier) }
        }
    }

    private func render() {
        for index in rows.indices {
            let row = rows[index]
            rowViews[index].update(checked: row.checked, enabled: !applying && row.item.isAvailable,
                                   result: row.result, resolutionError: row.item.resolutionError)
        }
        let hasPending = rows.contains { $0.item.isAvailable && $0.checked && !$0.actualDefault }
        applyButton.isEnabled = !applying && hasPending
        allButton.isEnabled = !applying && rows.contains { $0.item.isAvailable && !$0.checked }
        noneButton.isEnabled = !applying && rows.contains { $0.checked }
        retryButton.isHidden = failedItemIDs.isEmpty
        retryButton.isEnabled = !applying && !failedItemIDs.isEmpty
        if !applying {
            let selected = rows.filter { $0.checked }
            let count = "已选择 \(selected.count) 项"
            if !failedItemIDs.isEmpty {
                statusLabel.stringValue = "\(count) · \(failedItemIDs.count) 项设置失败，可重试。"
            } else if selected.isEmpty {
                statusLabel.stringValue = "请选择需要设置的文件类型。"
            } else if selected.allSatisfy({ $0.actualDefault }) {
                statusLabel.stringValue = "\(count)\n所选类型均已由 Textlet 默认打开。"
            } else if !hasPending {
                statusLabel.stringValue = "\(count)\n所选类型暂时无法设置，请查看列表提示。"
            } else {
                statusLabel.stringValue = count
            }
        }
        statusLabel.toolTip = statusLabel.stringValue
    }
}
