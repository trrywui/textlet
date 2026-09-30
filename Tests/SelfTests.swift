import AppKit

func runSelfTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("textlet-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(directory: root)
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    try expect(Note.nextName(in: []) == "文本1", "empty session starts at 文本1")
    let numbered = ["文本1", "文本2", "文本3"].map { Note(name: $0) }
    try expect(Note.nextName(in: numbered) == "文本4", "new text tabs increment the maximum number")
    try expect(Note.nextName(in: [numbered[0], numbered[2]]) == "文本4", "closing a middle tab does not reuse its number")
    try expect(Note.nextName(in: [numbered[0], numbered[1]]) == "文本3", "numbering uses the current maximum after closing the highest tab")
    let mixed = ["临时笔记", "笔记 2", "自定义名称", "query.sql", "文本9", "文本10", "文本01", "文本 20", "文本20.txt"].map { Note(name: $0) }
    try expect(Note.nextName(in: mixed) == "文本11", "only exact numbered text names contribute to the numeric maximum")
    try expect(Note.nextName(in: [Note(name: "文本\(Int.max)"), numbered[0]]) == "文本2", "an extreme custom number cannot overflow or duplicate an existing name")
    let namingStore = try SessionStore(directory: root.appendingPathComponent("naming"))
    try namingStore.save(notes: mixed, activeID: mixed[0].record.id)
    let restoredNames = try namingStore.load()!.notes.map { Note(record: $0) }
    try expect(restoredNames.map { $0.record.name } == mixed.map { $0.record.name }, "old and custom tab names restore unchanged")
    try expect(Note.nextName(in: restoredNames) == "文本11", "numbering resumes from restored tab names")
    let literal = "会议纪要\n\"quote\" --dash  two spaces\tTAB\r\n中文🙂\u{00a0}\n"
    let a = Note(name: "A", text: literal)
    let b = Note(name: "B", text: "第二个标签")
    try store.save(notes: [a, b], activeID: a.record.id)
    let first = try store.load()!
    let firstText = try store.text(for: first.notes[0])
    try expect(firstText == literal, "literal characters and line endings survive persistence")
    try expect(first.notes.count == 2 && first.activeID == a.record.id, "tabs and active selection restore")
    a.storage!.mutableString.append("new revision")
    a.dirty = true
    a.record.selection = 8
    try store.save(notes: [a, b], activeID: b.record.id)
    let second = try store.load()!
    let secondText = try store.text(for: second.notes[0])
    try expect(secondText == literal + "new revision", "new revision commits")
    try expect(second.notes[0].selection == 8, "caret location persists")
    // Simulate a missing content revision after an interrupted/external operation.
    try FileManager.default.removeItem(at: store.drafts.appendingPathComponent(second.notes[0].draftFile))
    let recovered = try store.load()!
    let recoveredText = try store.text(for: recovered.notes[0])
    try expect(recoveredText == literal, "missing revision falls back to consistent previous snapshot")
    try expect(store.recoveryNotice != nil, "fallback is reported, not silent")
    let manifest = root.appendingPathComponent("session.json")
    try Data("broken json".utf8).write(to: manifest)
    try FileManager.default.removeItem(at: root.appendingPathComponent("session.previous.json"))
    var rejected = false
    do { _ = try store.load() } catch { rejected = true }
    try expect(rejected, "unrecoverable session is rejected instead of overwritten")
    let untouched = try String(contentsOf: manifest, encoding: .utf8)
    try expect(untouched == "broken json", "failed load leaves source untouched")
    var locked = false
    do { _ = try SessionStore(directory: root) } catch { locked = true }
    try expect(locked, "second writer cannot open same session")
    let windowStore = try SessionStore(directory: root.appendingPathComponent("window"))
    let windowNote = Note(name: "window")
    let frame = NSRect(x: 120, y: 90, width: 1000, height: 700)
    try windowStore.save(notes: [windowNote], activeID: windowNote.record.id, windowFrame: frame)
    let restoredFrame = try windowStore.load()?.windowFrame
    try expect(restoredFrame == frame, "window size and position survive persistence")
    let screen = NSRect(x: 0, y: 25, width: 1680, height: 1000)
    let minimum = NSSize(width: 480, height: 320)
    try expect(Textlet.visibleWindowFrame(frame, screens: [screen], minimum: minimum) == frame, "normal window frame stays unchanged")
    try expect(Textlet.visibleWindowFrame(screen, screens: [screen], minimum: minimum) == screen, "zoomed window frame stays unchanged")
    let offscreen = NSRect(x: 3000, y: -2000, width: 2000, height: 1500)
    try expect(Textlet.visibleWindowFrame(offscreen, screens: [screen], minimum: minimum) == screen, "removed display and smaller resolution keep window reachable")
    let secondScreen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let secondFrame = NSRect(x: -1700, y: 100, width: 860, height: 612)
    try expect(Textlet.visibleWindowFrame(secondFrame, screens: [screen, secondScreen], minimum: minimum) == secondFrame, "secondary display negative coordinates survive")
    try expect(Textlet.visibleWindowFrame(NSRect(x: 0, y: 0, width: -1, height: 600), screens: [screen], minimum: minimum) == nil,
               "invalid window dimensions use default")
    print("All persistence tests passed.")
    try runTitleTests(root: root.appendingPathComponent("titles"))
    try runFeatureTests(root: root.appendingPathComponent("features"))
}
