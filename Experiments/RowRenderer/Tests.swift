import AppKit
extension Experiment {
    func selfTests() throws {
        guard let e = rows else { fatalError("Self tests require row renderer") }
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) { checks[name] = value }
        e.setText("a👨‍👩‍👧‍👦中"); e.selection = NSRange(location: e.text.length - 1, length: 0)
        e.doCommand(by: NSSelectorFromString("deleteBackward:"))
        check("deleteWholeGrapheme", e.text as String == "a中")
        e.history.undo(); check("undoGrapheme", e.text as String == "a👨‍👩‍👧‍👦中")
        e.history.redo(); check("redoGrapheme", e.text as String == "a中")
        e.setText("before after"); e.selection = NSRange(location: 7, length: 0)
        e.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check("markedRange", e.markedRange() == NSRange(location: 7, length: 5))
        e.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        e.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("compositionCommit", e.text as String == "before 中文after" && !e.hasMarkedText())
        e.history.undo(); check("compositionSingleUndo", e.text as String == "before after")
        e.history.redo(); check("compositionRedo", e.text as String == "before 中文after")
        e.setText("abc\n中文🙂\n"); check("trailingEmptyLine", e.rows.count == 3)
        e.selection = NSRange(location: 0, length: 3)
        e.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("replaceSelection", (e.text as String).hasPrefix("hello\n"))
        var range = NSRange()
        check("IMEContextSubstring", e.attributedSubstring(forProposedRange: NSRange(location: 0, length: 5), actualRange: &range)?.string == "hello" && range.length == 5)
        for i in [0, 1, 2, 6, 7] {
            let rect = e.firstRect(forCharacterRange: NSRange(location: i, length: 0), actualRange: nil)
            check("coordinateRoundTrip\(i)", e.characterIndex(for: NSPoint(x: rect.minX + 0.1, y: rect.midY)) == i)
        }
        e.setText(denseText); window.contentView?.layoutSubtreeIfNeeded()
        check("wraps", e.rows.count > 180)
        check("boundedVisibleTiles", e.rowLayers.count <= Int(e.bounds.height / e.rowHeight) + 2 && e.rowLayers.count < e.rows.count)
        let first = e.rowLayers.keys.min() ?? -1
        e.scrollY = e.maxScroll; e.render()
        check("scrollEvictsTiles", (e.rowLayers.keys.min() ?? -1) > first)
        check("bitmapBudget", e.bitmapBytes < Int(e.bounds.width * e.bounds.height * 16 * 1.1))
        e.setText("a🙂b")
        e.selection = NSRange(location: 1, length: 0)
        e.doCommand(by: NSSelectorFromString("moveRightAndModifySelection:"))
        check("shiftArrowSelectsGrapheme", e.selection == NSRange(location: 1, length: 2))
        e.doCommand(by: NSSelectorFromString("moveLeftAndModifySelection:"))
        check("shiftArrowShrinksSelection", e.selection == NSRange(location: 1, length: 0))
        e.setText(""); e.insertText("🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("emptyInput", e.text as String == "🙂")
        e.history.undo(); check("emptyUndo", e.text.length == 0)
        let report: [String: Any] = ["checks": checks, "allPassed": checks.values.allSatisfy { $0 }, "realInputMethodTested": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!); fflush(stdout)
        if let path = argument("--test-output") { try data.write(to: URL(fileURLWithPath: path)) }
        if !checks.values.allSatisfy({ $0 }) { throw NSError(domain: "RowRendererTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed checks: \(checks.filter { !$0.value }.keys.sorted())"]) }
    }
}
