import AppKit

private final class ArchiveFailureStore: SessionStore {
    override func archiveRecovery() throws -> URL { throw CocoaError(.fileWriteNoPermission) }
}

func runRecoveryTests(root: URL) throws {
    let fm = FileManager.default
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    for missingManifest in [false, true] {
        let directory = root.appendingPathComponent(missingManifest ? "missing" : "damaged")
        var store: SessionStore? = try SessionStore(directory: directory)
        let note = Note(name: "recovery", text: "older body")
        try store!.save(notes: [note], activeID: note.record.id)
        let oldName = note.record.draftFile
        note.storage!.mutableString.setString("NEWER RECOVERABLE BODY 中文🙂\r\n")
        note.dirty = true
        try store!.save(notes: [note], activeID: note.record.id)
        let newName = note.record.draftFile, newBody = note.storage!.string
        let manifest = directory.appendingPathComponent("session.json")
        let previous = try Data(contentsOf: directory.appendingPathComponent("session.previous.json"))
        let damaged = Data("damaged manifest".utf8)
        if missingManifest { try fm.removeItem(at: manifest) } else { try damaged.write(to: manifest) }
        let orphan = store!.drafts.appendingPathComponent("interrupted-save.txt")
        try Data("uncommitted recoverable text".utf8).write(to: orphan)
        let recovered = try store!.load()!
        let recoveredBody = try store!.text(for: recovered.notes[0])
        try expect(recoveredBody == "older body" && store!.recoveryNotice != nil, "\(directory.lastPathComponent) manifest falls back with a recovery notice")
        let archives = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("recovery-") }
        try expect(archives.count == 1, "fallback creates one recovery archive")
        let archive = archives[0]
        let archivedPrevious = try Data(contentsOf: archive.appendingPathComponent("session.previous.json"))
        try expect(archivedPrevious == previous, "recovery preserves the original previous manifest")
        if !missingManifest {
            let archivedManifest = try Data(contentsOf: archive.appendingPathComponent("session.json"))
            try expect(archivedManifest == damaged, "recovery preserves the damaged current manifest")
        }
        let restored = Note(record: recovered.notes[0], storage: NSTextStorage(string: recoveredBody))
        for revision in 0..<3 {
            restored.storage!.mutableString.append("\nrestored revision \(revision)"); restored.dirty = true
            try store!.save(notes: [restored], activeID: restored.record.id)
        }
        store = nil
        store = try SessionStore(directory: directory)
        let reopened = try store!.load()!
        let reopenedBody = try store!.text(for: reopened.notes[0])
        try expect(reopenedBody == restored.storage!.string, "recovered session remains writable and reopens after multiple saves")
        for (name, body) in [(oldName, "older body"), (newName, newBody), (orphan.lastPathComponent, "uncommitted recoverable text")] {
            let archivedBody = try String(contentsOf: archive.appendingPathComponent("drafts").appendingPathComponent(name), encoding: .utf8)
            try expect(archivedBody == body, "recovery retains \(name == newName ? "newer" : name == oldName ? "older" : "uncommitted") body after cleanup and restart")
        }
    }
    for missingManifest in [false, true] {
        let directory = root.appendingPathComponent(missingManifest ? "failure-missing" : "failure-damaged")
        let store = try ArchiveFailureStore(directory: directory)
        let note = Note(name: "failure", text: "older")
        try store.save(notes: [note], activeID: note.record.id)
        note.storage!.mutableString.setString("newer"); note.dirty = true
        try store.save(notes: [note], activeID: note.record.id)
        let manifest = directory.appendingPathComponent("session.json")
        if missingManifest { try fm.removeItem(at: manifest) } else { try Data("broken".utf8).write(to: manifest) }
        let oldPrevious = try Data(contentsOf: directory.appendingPathComponent("session.previous.json"))
        var failed = false
        do { _ = try store.load() } catch { failed = true }
        let unchanged = missingManifest ? !fm.fileExists(atPath: manifest.path) : (try Data(contentsOf: manifest)) == Data("broken".utf8)
        let previous = try Data(contentsOf: directory.appendingPathComponent("session.previous.json"))
        let latest = try store.text(for: note.record)
        try expect(failed && unchanged && previous == oldPrevious && latest == "newer", "archive failure leaves all original data untouched (\(missingManifest))")
    }
}
