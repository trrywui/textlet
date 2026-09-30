import AppKit
import Darwin

// Run each mode in a separate process for comparable allocator peaks.
func runFileEfficiencyBenchmark(output: URL) throws {
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    let mode = Textlet.argument("--efficiency-mode") ?? "hash"
    let note: Note = autoreleasepool {
        Note(name: "fixture.txt", text: mode == "hash"
            ? String(repeating: "select name from items; -- 中文🙂\n", count: 150_000) : "unchanged")
    }
    autoreleasepool {
        let text = note.storage!.string
        note.record.file = DocumentFile.reference(url: URL(fileURLWithPath: "/synthetic-fixture.txt"),
            text: text, data: Data(text.utf8), encoding: .utf8, bom: [])
        note.record.fileModified = false
    }
    let tab = mode == "tabs" ? NoteTab(note: note) : nil
    let iterations = mode == "tabs" ? 10_000 : 80
    let before = memorySample(), began = cpu(), wall = ProcessInfo.processInfo.systemUptime
    var correct = true
    for index in 0..<iterations {
        autoreleasepool {
            if let tab { tab.updateState(for: note) }
            else {
                note.storage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: index % 2 == 0 ? "S" : "s")
                note.refreshFileModification()
                correct = correct && note.needsFileSave == (index % 2 == 0)
            }
        }
    }
    let report: [String: Any] = ["mode": mode, "iterations": iterations, "correct": correct,
        "textUTF16Length": note.storage!.length, "cpuSeconds": cpu() - began,
        "wallSeconds": ProcessInfo.processInfo.systemUptime - wall,
        "before": before, "after": memorySample()]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    guard correct else { throw SessionError.invalid("efficiency benchmark changed dirty-state behavior") }
}
