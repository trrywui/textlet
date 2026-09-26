import AppKit

func runSelfTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("textlet-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(directory: root)
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SessionError.invalid("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
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
    print("All persistence tests passed.")
    try runFeatureTests(root: root.appendingPathComponent("features"))
}
