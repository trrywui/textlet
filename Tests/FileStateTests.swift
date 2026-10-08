import AppKit

// Preserve nanoseconds exactly; Date/setAttributes can round the timestamp and
// accidentally make a same-metadata regression test pass.
func replacingContentsKeepingMtime(_ url: URL, with text: String, atomic: Bool = true) throws {
    var original = stat()
    guard stat(url.path, &original) == 0 else { throw POSIXError(.EIO) }
    try Data(text.utf8).write(to: url, options: atomic ? .atomic : [])
    let times = [original.st_atimespec, original.st_mtimespec]
    guard times.withUnsafeBufferPointer({ utimensat(AT_FDCWD, url.path, $0.baseAddress, 0) }) == 0 else { throw POSIXError(.EIO) }
}

func runFileStateTests(root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    for atomic in [false, true] {
        let url = root.appendingPathComponent("\(atomic).txt")
        try Data("AAAA".utf8).write(to: url)
        let note = try DocumentFile.open(url)
        let original = try DocumentFile.signature(at: url)
        try replacingContentsKeepingMtime(url, with: "BBBB", atomic: atomic)
        let changed = try DocumentFile.signature(at: url)
        try expect(original.size == changed.size && original.modifiedSeconds == changed.modifiedSeconds && original.modifiedNanos == changed.modifiedNanos,
            "replacement fixture preserves exact size and mtime (\(atomic))")
        try expect((original.identity == changed.identity) == !atomic, "fixture covers \(atomic ? "replacement" : "original") inode")
        note.refreshFileState()
        try expect(note.fileChangedExternally && note.needsFileSave && !note.fileMissing, "same-size same-mtime edit is marked external (\(atomic))")
        let restored = Note(record: try JSONDecoder().decode(NoteRecord.self, from: JSONEncoder().encode(note.record)))
        try expect(restored.fileChangedExternally && restored.needsFileSave, "external change remains detected after session restoration")
        try DocumentFile.write(note, text: "AAAA", to: url, expected: try DocumentFile.version(at: url))
        note.refreshFileState()
        try expect(!note.needsFileSave, "explicit save refreshes signature and clears external state")
    }
    let url = root.appendingPathComponent("legacy.txt")
    try Data("AAAA".utf8).write(to: url)
    let original = try DocumentFile.open(url)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.record)) as! [String: Any]
    var file = json["file"] as! [String: Any]; file.removeValue(forKey: "signature"); json["file"] = file
    let legacyRecord = try JSONDecoder().decode(NoteRecord.self, from: JSONSerialization.data(withJSONObject: json))
    let clean = Note(record: legacyRecord)
    try expect(!clean.needsFileSave && clean.record.file?.signature != nil, "legacy session verifies unchanged disk content and adopts a signature")
    try replacingContentsKeepingMtime(url, with: "BBBB")
    let changed = Note(record: legacyRecord)
    try expect(changed.needsFileSave && changed.fileChangedExternally && changed.record.file?.signature == nil,
        "legacy session detects changed contents before adopting metadata")
    changed.refreshFileState()
    try expect(changed.fileChangedExternally, "repeated legacy refresh preserves the external state")
    try fm.removeItem(at: url); changed.refreshFileState()
    try expect(changed.fileMissing, "legacy refresh detects a missing source")
    try Data("AAAA".utf8).write(to: url); changed.refreshFileState()
    try expect(!changed.needsFileSave && changed.record.file?.signature != nil, "legacy refresh verifies a recreated source")
}
