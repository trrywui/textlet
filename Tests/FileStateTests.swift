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
    let cloudURL = root.appendingPathComponent("macos.lcf")
    let savedText = "[General]\r\n# 中文🙂\r\n"
    try Data(savedText.utf8).write(to: cloudURL)
    let cloudNote = try DocumentFile.open(cloudURL)
    // Model the delayed metadata updates performed by a cloud sync provider.
    let savedSignature = try DocumentFile.signature(at: cloudURL)
    let syncValue: [UInt8] = [1]
    let result = syncValue.withUnsafeBytes { setxattr(cloudURL.path, "com.textlet.tests.sync", $0.baseAddress, $0.count, 0, 0) }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let syncedSignature = try DocumentFile.signature(at: cloudURL)
    try expect(savedSignature != syncedSignature && savedSignature.identity == syncedSignature.identity
        && savedSignature.size == syncedSignature.size && savedSignature.modifiedSeconds == syncedSignature.modifiedSeconds
        && savedSignature.modifiedNanos == syncedSignature.modifiedNanos, "sync fixture changes only metadata, preserving inode, size and mtime")
    cloudNote.refreshFileState()
    try expect(!cloudNote.needsFileSave && !cloudNote.fileChangedExternally && cloudNote.record.file?.signature == syncedSignature,
        "cloud metadata update keeps the saved state and adopts the verified signature")
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: cloudURL.path)
    cloudNote.refreshFileState()
    try expect(!cloudNote.needsFileSave, "timestamp-only update keeps the saved state")
    let beforeReplacement = try DocumentFile.signature(at: cloudURL)
    try replacingContentsKeepingMtime(cloudURL, with: savedText)
    cloudNote.refreshFileState()
    try expect(cloudNote.record.file?.signature?.identity != beforeReplacement.identity && !cloudNote.needsFileSave,
        "same-content inode replacement keeps the saved state")
    let restoredCloud = Note(record: try JSONDecoder().decode(NoteRecord.self, from: JSONEncoder().encode(cloudNote.record)))
    try expect(!restoredCloud.needsFileSave, "verified cloud file stays saved after session restoration")
    cloudNote.storage!.mutableString.append("# local edit\r\n")
    cloudNote.refreshFileModification()
    try replacingContentsKeepingMtime(cloudURL, with: savedText)
    cloudNote.refreshFileState()
    try expect(cloudNote.needsFileSave && !cloudNote.fileChangedExternally && cloudNote.record.fileModified == true,
        "same-content cloud replacement preserves unsaved local edits")
    cloudNote.storage!.mutableString.setString(savedText)
    cloudNote.refreshFileModification()
    try replacingContentsKeepingMtime(cloudURL, with: "[General]\r\n# 外部🙂\r\n")
    cloudNote.refreshFileState()
    cloudNote.refreshFileState()
    try expect(cloudNote.needsFileSave && cloudNote.fileChangedExternally, "real cloud content changes remain external across repeated refreshes")
    // A save can change the baseline digest while the last inspected signature
    // is still cached. A later return to those bytes must be checked again.
    let externallySavedText = "[General]\r\n# 外部🙂\r\n"
    cloudNote.storage!.mutableString.setString(externallySavedText)
    try DocumentFile.write(cloudNote, text: externallySavedText, to: cloudURL, expected: try DocumentFile.version(at: cloudURL))
    cloudNote.refreshFileState()
    try expect(!cloudNote.needsFileSave && !cloudNote.fileChangedExternally, "explicit save replaces the baseline after a cached external change")
    try replacingContentsKeepingMtime(cloudURL, with: savedText)
    cloudNote.refreshFileState()
    try expect(cloudNote.needsFileSave && cloudNote.fileChangedExternally, "returning to the old content differs from the new saved baseline")
    try replacingContentsKeepingMtime(cloudURL, with: externallySavedText)
    cloudNote.refreshFileState()
    try expect(!cloudNote.needsFileSave && !cloudNote.fileChangedExternally, "restoring the saved bytes clears the external state without another save")
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
