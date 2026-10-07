import Foundation

func runLogBoundaryTests(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LogError.message("TEST FAILED: \(message)") }
        print("PASS \(message)")
    }
    for bom: [UInt8] in [[0, 0, 0xfe, 0xff], [0xff, 0xfe, 0, 0], [0xff, 0xfe], [0xfe, 0xff]] {
        let url = root.appendingPathComponent("bom.log")
        try Data(bom + [0, 0, 0, 0x41]).write(to: url)
        var rejected = false
        do { _ = try LogFile(url: url) } catch { rejected = true }
        try expect(rejected, "log rejects UTF-16/32 BOM \(bom)")
    }

    // The entire byte range must be visited, including malformed input. Keep
    // the loop bounded so a zero-length page reports a failure instead of hanging.
    let cases: [[UInt8]] = [
        [0x80, 0x81, 0x41, 10], [0x80, 0x81],
        [0x41] + Array(repeating: 0x80, count: 60_000),
        Array(repeating: 0x80, count: 60_000),
        [0xc0, 0xaf, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80, 0xe4, 0xb8],
        Array(repeating: 0x61, count: LogFile.pageSize - 1) + [0xc0, 0xaf, 0x62],
        Array(repeating: 0x61, count: LogFile.pageSize - 1) + [0xe4, 0xb8]
    ]
    for (i, bytes) in cases.enumerated() {
        let url = root.appendingPathComponent("invalid-\(i).log")
        try Data(bytes).write(to: url)
        let file = try LogFile(url: url), index = try file.makeIndex(cancel: Cancellation())!
        var offset: Int64 = 0, text = "", pages = 0
        while offset < file.size && pages < 20 {
            let page = try file.page(at: offset, index: index)
            try expect(page.start == offset && page.end > offset, "invalid UTF-8 case \(i) page \(pages) advances without dropping bytes")
            let expected = String(decoding: bytes[Int(page.start)..<Int(page.end)], as: UTF8.self)
            try expect(page.text == expected, "invalid UTF-8 case \(i) page \(pages) uses replacement decoding")
            text += page.text; offset = page.end; pages += 1
        }
        try expect(offset == file.size && text.contains("�"),
                   "invalid UTF-8 case \(i) displays replacement characters through EOF")
    }

    for scalar in ["é", "中", "🙂"] {
        for split in 1..<scalar.utf8.count {
            let prefix = String(repeating: "a", count: LogFile.pageSize - split)
            let original = prefix + scalar + "tail\r\nnext\n"
            let url = root.appendingPathComponent("valid.log")
            try Data(original.utf8).write(to: url)
            let file = try LogFile(url: url), index = try file.makeIndex(cancel: Cancellation())!
            let first = try file.page(at: 0, index: index)
            let second = try file.page(at: first.end, index: index)
            try expect(first.end == Int64(prefix.utf8.count) && second.start == first.end
                && !first.repairedUTF8 && !second.repairedUTF8 && first.text + second.text == original,
                "UTF-8 \(scalar) boundary \(split) reconstructs the original file")
            let jumped = try file.page(at: Int64(prefix.utf8.count + split), index: index)
            try expect(jumped.start == Int64(prefix.utf8.count) && !jumped.repairedUTF8 && jumped.text.hasPrefix(scalar),
                       "jump inside \(scalar) boundary \(split) retains the complete scalar")
        }
    }
}
