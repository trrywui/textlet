import AppKit

func runFeatureTests(root: URL) throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw LogError.message("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    let source = #"{"id":123456789012345678901234567890,"x":-0.10E+09,"s":"中\u6587\n\"\\","x":[],"ok":true}"#
    let formatted = try JSONFormatter.format(source)
    try expect(formatted.contains("123456789012345678901234567890") && formatted.contains("-0.10E+09"), "JSON preserves numeric tokens exactly")
    try expect(formatted.contains(#""中\u6587\n\"\\""#), "JSON preserves escapes and Unicode")
    let again = try JSONFormatter.format(formatted)
    try expect(again == formatted, "JSON formatting is idempotent")
    try expect(formatted.components(separatedBy: "\"x\"").count == 3, "JSON retains duplicate keys")
    for valid in ["null", "true", "false", "[0,-1,2.5,3e-1]", "{}", "[]", "\"🙂\"", "\r\n 123 \t"] {
        _ = try JSONFormatter.format(valid)
    }
    for invalid in ["", "{", "[1,]", "{\"a\":1,}", "01", "1.", "1e", "[true false]", "{a:1}", "\"x\n\"", #""\z""#, #""\u123z""#, "falseX", "[] []", String(repeating: "[", count: 130)] {
        var rejected = false
        do { _ = try JSONFormatter.format(invalid) } catch { rejected = true }
        try expect(rejected, "JSON rejects invalid input \(String(invalid.prefix(20)).debugDescription)")
    }
    var bounded = false
    do { _ = try JSONFormatter.format(String(repeating: " ", count: 2 * 1_048_576 + 1)) } catch { bounded = true }
    try expect(bounded, "JSON input memory limit")
    let counter = LineCounter()
    let lines = "a\r\nb\rc\n🙂\u{2028}d\u{2029}" as NSString
    try expect(counter.line(at: lines.length, in: lines) == 6, "line count handles CRLF, CR, LF, Unicode and trailing newline")
    try expect(!counter.isLineStart(2, in: lines) && counter.isLineStart(3, in: lines), "CRLF is a single logical boundary")
    counter.invalidate()
    let long = NSMutableString(string: String(repeating: "a\n", count: 10000))
    try expect(counter.line(at: long.length, in: long) == 10001, "sparse line checkpoints")
    long.replaceCharacters(in: NSRange(location: 8500, length: 2), with: "b")
    counter.invalidate(from: 8500)
    try expect(counter.line(at: long.length, in: long) == 10000, "line checkpoints invalidate after edit")
    counter.invalidate()
    try expect(counter.line(at: 0, in: "" as NSString) == 1, "empty note has line 1")

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("mixed.log")
    let row = "2026 INFO 中文🙂 curl --header 'x'\r\n"
    let data = Data(String(repeating: row, count: 16000).utf8)
    try data.write(to: url)
    let file = try LogFile(url: url)
    let index = try file.makeIndex(cancel: Cancellation())!
    try expect(index.lines == 16001, "log index counts CRLF across blocks")
    var offset: Int64 = 0, joined = Data(), pages = 0
    while offset < file.size {
        let page = try file.page(at: offset, index: index)
        try expect(page.start == offset && page.end > offset && !page.repairedUTF8, "log page advances without gaps or broken UTF-8")
        try expect(page.firstLine == Int(offset) / row.utf8.count + 1, "absolute log line number")
        joined.append(contentsOf: page.text.utf8); offset = page.end; pages += 1
    }
    try expect(joined == data && pages > 5, "all log pages reconstruct original bytes")
    let match = try file.search("中文🙂", from: 0, cancel: Cancellation())
    try expect(match == 10, "UTF-8 literal full-file search")
    let missing = try file.search("NOT-PRESENT", from: 0, cancel: Cancellation())
    try expect(missing == nil, "no-match search reaches EOF")
    let cancelled = Cancellation(); cancelled.cancel()
    let cancelledIndex = try file.makeIndex(cancel: cancelled)
    try expect(cancelledIndex == nil, "index cancellation")

    let crossURL = root.appendingPathComponent("cross.log")
    let prefix = String(repeating: "a", count: LogFile.blockSize - 2)
    let cross = prefix + "中文🙂MATCH\r\nend"
    try Data(cross.utf8).write(to: crossURL)
    let crossFile = try LogFile(url: crossURL)
    let crossIndex = try crossFile.makeIndex(cancel: Cancellation())!
    let crossMatch = try crossFile.search("中文🙂MATCH", from: 0, cancel: Cancellation())
    try expect(crossMatch == Int64(prefix.utf8.count), "search matches across block/UTF-8 boundary")
    offset = 0; joined = Data()
    while offset < crossFile.size {
        let page = try crossFile.page(at: offset, index: crossIndex)
        try expect(page.start == offset && page.end > offset && page.text.utf8.count <= LogFile.pageSize + 1, "huge single line remains bounded")
        joined.append(contentsOf: page.text.utf8); offset = page.end
    }
    try expect(joined == Data(cross.utf8), "huge line and emoji survive paging")
    let jumped = try crossFile.page(at: Int64(prefix.utf8.count + 1), index: crossIndex)
    try expect(!jumped.repairedUTF8 && jumped.startsMidLine, "jump within multibyte character is aligned")
    let changed = try FileHandle(forWritingTo: crossURL)
    try changed.truncate(atOffset: 20); try changed.close()
    var changeRejected = false
    do { _ = try crossFile.page(at: 0, index: crossIndex) } catch { changeRejected = true }
    try expect(changeRejected, "changed or truncated logs require explicit reload")

    let emptyURL = root.appendingPathComponent("empty.log")
    try Data().write(to: emptyURL)
    let emptyFile = try LogFile(url: emptyURL)
    let emptyPage = try emptyFile.page(at: 0, index: nil)
    try expect(emptyPage.text.isEmpty && emptyPage.firstLine == 1, "empty log opens")
    let session = try SessionStore(directory: root.appendingPathComponent("session"))
    let draft = Note(name: "draft", text: "preserve me")
    try session.save(notes: [draft], activeID: draft.record.id)
    var legacy = SessionRecord(activeID: draft.record.id, notes: [draft.record]); legacy.version = 1
    try JSONEncoder().encode(legacy).write(to: session.directory.appendingPathComponent("session.json"))
    let oldSession = try session.load()!
    try expect(oldSession.version == 1 && oldSession.notes[0].logPath == nil, "0.1 session remains readable")
    let log = Note(record: NoteRecord(id: UUID(), name: "missing.log", draftFile: "", selection: 0, scrollY: 123,
                                    logPath: root.appendingPathComponent("missing.log").path, logOffset: 500000))
    try session.save(notes: [draft, log], activeID: log.record.id)
    let restored = try session.load()!
    try expect(restored.notes[1].logOffset == 500000 && restored.notes[1].scrollY == 123, "log path and viewport persist without copying file")
    let restoredDraft = try session.text(for: restored.notes[0])
    try expect(restoredDraft == "preserve me", "missing external log does not prevent draft recovery")
    let draftFiles = try FileManager.default.contentsOfDirectory(atPath: session.drafts.path)
    try expect(draftFiles.count == 1, "log tabs never create full-file drafts")
    print("All feature tests passed.")
}
