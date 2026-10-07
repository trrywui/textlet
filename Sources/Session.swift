import AppKit

struct NoteRecord: Codable {
    var id: UUID
    var name: String
    var draftFile: String
    var selection: Int
    var scrollY: Double
    var logPath: String? = nil
    var logOffset: Int64? = nil
    var syntax: String? = nil // nil: infer from name; "plain": explicitly disable highlighting
    var automaticTitle: Bool? = nil // nil: older sessions keep their original titles
    var contentTitle: String? = nil
    var file: FileReference? = nil
    var fileModified: Bool? = nil

    var usesContentTitle: Bool { logPath == nil && file == nil && automaticTitle == true }
}

struct SessionRecord: Codable {
    var version = 2
    var activeID: UUID
    var notes: [NoteRecord]
    var windowFrame: NSRect? = nil
}

final class Note {
    // Only retain a short preview, including for an extremely long first line.
    static func titlePreview(in text: NSString) -> (title: String?, scannedThrough: Int) {
        let first = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return (nil, text.length) }
        let range = text.rangeOfComposedCharacterSequences(for:
            NSRange(location: first.location, length: min(160, text.length - first.location)))
        let sample = text.substring(with: range) as NSString
        let newline = sample.rangeOfCharacter(from: .newlines)
        if newline.location != NSNotFound {
            return (sample.substring(to: newline.location).trimmingCharacters(in: .whitespaces), first.location + newline.location)
        }
        let end = NSMaxRange(range)
        let hasMore = end < text.length && text.rangeOfCharacter(from: .newlines, range: NSRange(location: end, length: 1)).location == NSNotFound
        return ((sample as String).trimmingCharacters(in: .whitespaces) + (hasMore ? "…" : ""), end)
    }

    static func nextName(in notes: [Note]) -> String {
        let names = Set(notes.map { $0.record.name })
        let maximum = names.compactMap { name -> Int? in
            guard name.hasPrefix("文本"), let number = Int(name.dropFirst(2)),
                  number > 0, name == "文本\(number)" else { return nil }
            return number
        }.max() ?? 0
        // A manually entered Int.max must not overflow when creating a tab.
        var number = maximum < Int.max ? maximum + 1 : 1
        while names.contains("文本\(number)") { number += 1 }
        return "文本\(number)"
    }

    var isLog: Bool { record.logPath != nil }
    var encodingTitle: String { record.file.map { String.localizedName(of: String.Encoding(rawValue: $0.encoding)) } ?? "UTF-8" }
    var fileMissing = false
    var fileChangedExternally = false
    var fileWatch: FileWatch?
    var needsFileSave: Bool { !isLog && (record.file == nil || record.fileModified != false || fileMissing || fileChangedExternally) }
    func refreshFileModification() {
        guard let file = record.file, let storage else { return }
        record.fileModified = file.differs(from: storage.mutableString)
    }
    func refreshFileState() {
        guard let file = record.file else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            fileMissing = false
            fileChangedExternally = (attributes[.modificationDate] as? Date) != file.modifiedAt || (attributes[.size] as? Int) != file.size
        } catch {
            fileMissing = DocumentFile.isMissing(error)
            fileChangedExternally = !fileMissing
        }
    }
    var displayName: String { record.usesContentTitle ? record.contentTitle ?? record.name : record.name }
    private var titleScannedThrough: Int?

    @discardableResult func refreshContentTitle(editedFrom offset: Int = 0) -> Bool {
        guard record.usesContentTitle, let storage,
              titleScannedThrough == nil || offset <= titleScannedThrough! else { return false }
        let oldTitle = displayName
        let preview = Self.titlePreview(in: storage.mutableString)
        record.contentTitle = preview.title
        titleScannedThrough = preview.scannedThrough
        return displayName != oldTitle
    }

    func rename(to name: String) {
        record.name = name
        record.automaticTitle = false
        record.contentTitle = nil
        titleScannedThrough = nil
    }

    var language: TextLanguage {
        if isLog { return .plain }
        return record.syntax.flatMap(TextLanguage.init(rawValue:)) ?? TextLanguage.detect(record.name)
    }
    var record: NoteRecord
    var storage: NSTextStorage?
    var logFile: LogFile?
    var logIndex: LogIndex?
    let undo = UndoManager()
    var dirty: Bool
    init(record: NoteRecord, storage: NSTextStorage? = nil, dirty: Bool = false) {
        self.record = record
        self.storage = storage
        self.dirty = dirty
        undo.levelsOfUndo = 100
        refreshContentTitle()
        refreshFileModification()
        refreshFileState()
    }
    convenience init(name: String, text: String = "", automaticTitle: Bool = false) {
        self.init(record: NoteRecord(id: UUID(), name: name, draftFile: "", selection: 0, scrollY: 0, automaticTitle: automaticTitle),
                  storage: NSTextStorage(string: text), dirty: true)
    }
}

enum SessionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): return "草稿读取失败：\(detail)。原有文件未被覆盖。" }
    }
}

class SessionStore {
    let directory: URL
    let drafts: URL
    var recoveryNotice: String?
    private let fm = FileManager.default
    private var lockFD: Int32 = -1
    private var manifest: URL { directory.appendingPathComponent("session.json") }
    private var previous: URL { directory.appendingPathComponent("session.previous.json") }

    init(directory: URL) throws {
        self.directory = directory
        drafts = directory.appendingPathComponent("drafts", isDirectory: true)
        try fm.createDirectory(at: drafts, withIntermediateDirectories: true)
        lockFD = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw SessionError.invalid("此草稿目录已由另一个 Textlet 进程使用，或无法加锁")
        }
    }
    deinit { if lockFD >= 0 { close(lockFD) } }

    func text(for record: NoteRecord) throws -> String {
        if record.logPath != nil { return "" }
        guard !record.draftFile.isEmpty,
              record.draftFile == (record.draftFile as NSString).lastPathComponent else {
            throw SessionError.invalid("无效草稿路径")
        }
        return try String(contentsOf: drafts.appendingPathComponent(record.draftFile), encoding: .utf8)
    }

    private func read(_ url: URL) throws -> SessionRecord {
        var session = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: url))
        guard (1...2).contains(session.version), !session.notes.isEmpty,
              Set(session.notes.map(\.id)).count == session.notes.count,
              session.notes.contains(where: { $0.id == session.activeID }) else {
            throw SessionError.invalid("会话格式无效")
        }
        // Validate all referenced files before accepting a generation; retain only the active buffer later.
        for index in session.notes.indices {
            try autoreleasepool {
                let text = try text(for: session.notes[index])
                if session.notes[index].usesContentTitle {
                    session.notes[index].contentTitle = Note.titlePreview(in: text as NSString).title
                }
                if let file = session.notes[index].file { session.notes[index].fileModified = file.differs(from: text as NSString) }
            }
        }
        return session
    }

    func load() throws -> SessionRecord? {
        guard fm.fileExists(atPath: manifest.path) else {
            if fm.fileExists(atPath: previous.path) { return try read(previous) }
            return nil
        }
        do { return try read(manifest) }
        catch {
            guard let recovered = try? read(previous) else {
                throw SessionError.invalid("当前会话和备份都无法读取；数据位于 \(directory.path)")
            }
            let archive = directory.appendingPathComponent("session.damaged-\(UUID().uuidString).json")
            try fm.copyItem(at: manifest, to: archive)
            try Data(contentsOf: previous).write(to: manifest, options: .atomic)
            recoveryNotice = "已从上一份完整快照恢复草稿；损坏的会话文件已保留。"
            return recovered
        }
    }

    func save(notes: [Note], activeID: UUID, windowFrame: NSRect? = nil) throws {
        guard !notes.isEmpty else { throw SessionError.invalid("不能保存空会话") }
        var records = notes.map(\.record)
        for (index, note) in notes.enumerated() where !note.isLog && (note.dirty || note.record.draftFile.isEmpty) {
            try autoreleasepool {
                guard let storage = note.storage else { throw SessionError.invalid("草稿缓冲区缺失") }
                let name = "\(note.record.id.uuidString)-\(UUID().uuidString).txt"
                let data = Data(storage.string.utf8)
                try data.write(to: drafts.appendingPathComponent(name), options: .atomic)
                records[index].draftFile = name
                if let file = records[index].file {
                    records[index].fileModified = storage.length != file.textLength || DocumentFile.digest(data) != file.textDigest
                }
                if records[index].usesContentTitle {
                    records[index].contentTitle = Note.titlePreview(in: storage.mutableString).title
                }
            }
        }
        let snapshot = SessionRecord(activeID: activeID, notes: records, windowFrame: windowFrame)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(snapshot)
        // Content revisions precede the atomic manifest commit, so a failed save cannot corrupt an old snapshot.
        if fm.fileExists(atPath: manifest.path) {
            try Data(contentsOf: manifest).write(to: previous, options: .atomic)
        }
        try encoded.write(to: manifest, options: .atomic)
        for (index, note) in notes.enumerated() {
            note.record = records[index]
            note.dirty = false
        }
        // Keep files referenced by BOTH committed generations.
        var retained = Set(records.map(\.draftFile))
        if let data = try? Data(contentsOf: previous),
           let old = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            retained.formUnion(old.notes.map(\.draftFile))
        }
        if let files = try? fm.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "txt" && !retained.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
