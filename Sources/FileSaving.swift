import AppKit

enum FileConflictChoice { case cancel, overwrite, saveAs }

extension Textlet {
    @objc func saveText() { _ = saveNote(active) }
    @objc func saveTextAs() { _ = saveNote(active, saveAs: true) }

    func watchFile(_ note: Note) {
        guard let file = note.record.file else { note.fileWatch = nil; return }
        guard note.fileWatch?.url.path != file.path else { return }
        note.refreshFileState()
        note.fileWatch = FileWatch(url: URL(fileURLWithPath: file.path)) { [weak self, weak note] in
            guard let self, let note else { return }
            note.refreshFileState()
            self.updateTabState(note)
            if self.activeID == note.record.id { self.updateStatus() }
        }
    }
    func updateTabState(_ note: Note) {
        (tabStack?.arrangedSubviews.first { ($0 as? NoteTab)?.id == note.record.id } as? NoteTab)?.updateState(for: note)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        for note in notes { note.refreshFileState(); updateTabState(note) }
        if editor != nil { updateStatus() }
    }

    func makeSavePanel(for note: Note) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "保存文本"
        if let file = note.record.file {
            let url = URL(fileURLWithPath: file.path)
            panel.nameFieldStringValue = url.lastPathComponent
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) { panel.directoryURL = parent }
        } else {
            panel.nameFieldStringValue = note.record.name.contains(".") ? note.record.name : note.record.name + ".txt"
        }
        return panel
    }
    func chooseSaveDestination(for note: Note) -> URL? {
        let panel = makeSavePanel(for: note)
        return panel.runModal() == .OK ? panel.url : nil
    }
    func resolveFileConflict(_ note: Note) -> FileConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(note.record.name)”已被其他程序修改"
        alert.informativeText = "覆盖会用当前标签内容替换磁盘中的文件。也可以另存为其他文件，或取消以保留当前编辑内容。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "覆盖原文件")
        alert.addButton(withTitle: "另存为…")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .overwrite
        case .alertThirdButtonReturn: return .saveAs
        default: return .cancel
        }
    }

    @discardableResult func saveNote(_ note: Note, saveAs: Bool = false,
        chooseDestination: ((Note) -> URL?)? = nil,
        resolveConflict: ((Note) -> FileConflictChoice)? = nil) -> Bool {
        guard !note.isLog else { return false }
        do {
            let text = try text(for: note)
            var needsPanel = saveAs || note.record.file == nil
            var target: URL?
            var expected: DocumentFile.Version = .absent
            if let file = note.record.file, !saveAs {
                let url = URL(fileURLWithPath: file.path)
                expected = try DocumentFile.version(at: url)
                switch expected {
                case .absent:
                    note.fileMissing = true; updateTabState(note)
                    needsPanel = true
                case .present(let digest):
                    if digest != file.diskDigest {
                        note.fileChangedExternally = true; updateTabState(note)
                        let choice = resolveConflict?(note) ?? resolveFileConflict(note)
                        switch choice {
                        case .cancel: return false
                        case .saveAs: needsPanel = true
                        case .overwrite: target = url
                        }
                    } else {
                        target = url
                        if !file.differs(from: text as NSString) {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            note.record.file?.modifiedAt = attributes[.modificationDate] as? Date
                            note.record.file?.size = attributes[.size] as? Int
                            note.record.fileModified = false
                            note.fileMissing = false; note.fileChangedExternally = false
                            updateTabState(note)
                            return saveSession()
                        }
                    }
                }
            }
            if needsPanel {
                // A cancelled injected panel is a cancellation, not a request to show a second panel.
                let chosen: URL?
                if let chooseDestination { chosen = chooseDestination(note) }
                else { chosen = chooseSaveDestination(for: note) }
                guard let chosen else { return false }
                target = DocumentFile.canonical(chosen)
                expected = try DocumentFile.version(at: target!)
            }
            guard let target else { return false }
            guard !notes.contains(where: { $0 !== note && $0.record.file?.path == target.path }) else {
                showMessage("无法保存到这个文件", "此文件已在另一个标签中打开，请切换到该标签，或另存为其他文件。")
                return false
            }
            try DocumentFile.write(note, text: text, to: target, expected: expected, asUTF8: needsPanel)
            watchFile(note)
            if activeID == note.record.id { highlighter.reset(note.language) }
            updateTabState(note)
            return saveSession()
        } catch {
            note.refreshFileState(); updateTabState(note)
            showMessage("保存失败", error.localizedDescription)
            return false
        }
    }
}
