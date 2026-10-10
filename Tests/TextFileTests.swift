import AppKit

func runTextFileTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("textlet-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("document.txt")
    let bytes = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".utf8)
    try bytes.write(to: pdf)
    var rejected = false
    do { _ = try DocumentFile.open(pdf) }
    catch { rejected = error.localizedDescription == "此文件不是受支持的文本文件" }
    guard rejected else { throw SessionError.invalid("TEST FAILED: PDF content renamed to .txt is rejected") }
    print("PASS PDF content renamed to .txt is rejected")

    rejected = false
    do { _ = try LogFile(url: pdf) }
    catch { rejected = error.localizedDescription == "此文件不是受支持的文本文件" }
    guard rejected else { throw SessionError.invalid("TEST FAILED: read-only log reader rejects PDF before indexing") }
    print("PASS read-only log reader rejects PDF before indexing")

    let binaries: [(String, [UInt8])] = [
        ("PNG", [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]),
        ("JPEG", [0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46]),
        ("GIF", Array("GIF89a".utf8) + [1, 0, 1, 0]),
        ("ZIP", [0x50, 0x4b, 3, 4, 20, 0, 0, 0]),
        ("empty ZIP", [0x50, 0x4b, 5, 6] + Array(repeating: 0, count: 18)),
        ("gzip", [0x1f, 0x8b, 8, 0, 0, 0, 0, 0]),
        ("7z", [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]),
        ("RAR", [0x52, 0x61, 0x72, 0x21, 0x1a, 7, 1, 0]),
        ("XZ", [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]),
        ("SQLite", Array("SQLite format 3\0".utf8)),
        ("OLE document", [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
        ("ELF", [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0]),
        ("Mach-O", [0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]),
        ("binary controls", [1, 2, 3, 4, 5, 6, 7, 8]),
        ("embedded NUL", Array("text\0binary".utf8))
    ]
    for (name, header) in binaries {
        let url = root.appendingPathComponent("\(name).txt")
        let original = Data(header)
        try original.write(to: url)
        for log in [false, true] {
            rejected = false
            do { if log { _ = try LogFile(url: url) } else { _ = try DocumentFile.open(url) } }
            catch { rejected = error.localizedDescription == "此文件不是受支持的文本文件" }
            guard rejected else { throw SessionError.invalid("TEST FAILED: \(name) rejected in log=\(log)") }
        }
        guard try Data(contentsOf: url) == original else { throw SessionError.invalid("TEST FAILED: rejected source was modified") }
        print("PASS \(name) rejected in both modes without modifying its source")
    }

    let literal = "配置内容 café 中文🙂\r\n\tvalue=1\n\u{1b}[31m日志\u{1b}[0m\u{0c}"
    for name in ["source.xml", "source.csv", "notes.custom", "Dockerfile", ".env", "empty"] {
        let url = root.appendingPathComponent(name)
        let expected = name == "empty" ? "" : literal
        try Data(expected.utf8).write(to: url)
        let note = try DocumentFile.open(url)
        guard note.storage?.string == expected, note.record.file?.path == url.path, !note.needsFileSave else {
            throw SessionError.invalid("TEST FAILED: text opens cleanly regardless of filename \(name)")
        }
        _ = try LogFile(url: url)
        print("PASS text opens cleanly regardless of filename \(name)")
    }
    for (encoding, bom): (String.Encoding, [UInt8]) in [
        (.utf8, [0xef, 0xbb, 0xbf]), (.utf16LittleEndian, [0xff, 0xfe]),
        (.utf16BigEndian, [0xfe, 0xff]), (.utf32LittleEndian, [0xff, 0xfe, 0, 0]),
        (.utf32BigEndian, [0, 0, 0xfe, 0xff])
    ] {
        let url = root.appendingPathComponent("unicode.custom")
        var data = Data(bom); data.append(literal.data(using: encoding)!)
        try data.write(to: url)
        let note = try DocumentFile.open(url)
        guard note.storage?.string == literal, note.record.file?.byteOrderMark == bom else {
            throw SessionError.invalid("TEST FAILED: Unicode BOM and text survive content detection")
        }
        print("PASS Unicode BOM \(bom) is not mistaken for binary")
    }
    let legacy = root.appendingPathComponent("legacy.custom")
    try "café\n".data(using: .isoLatin1)!.write(to: legacy)
    guard try DocumentFile.open(legacy).storage?.string == "café\n" else {
        throw SessionError.invalid("TEST FAILED: existing legacy encoding detection is preserved")
    }
    print("PASS existing legacy encoding detection is preserved")
    let unmarked = "hello café 中文🙂\r\n"
    for encoding in [String.Encoding.utf32LittleEndian, .utf32BigEndian] {
        let url = root.appendingPathComponent("unmarked.custom")
        let original = unmarked.data(using: encoding)!
        try original.write(to: url)
        let note = try DocumentFile.open(url)
        guard note.storage?.string == unmarked else { throw SessionError.invalid("TEST FAILED: existing unmarked UTF-32 decoding is preserved") }
        try DocumentFile.write(note, text: unmarked, to: url, expected: DocumentFile.version(at: url))
        guard try Data(contentsOf: url) == original else { throw SessionError.invalid("TEST FAILED: saving unmarked UTF-32 preserves byte order and absence of BOM") }
        print("PASS unmarked UTF-32 \(encoding.rawValue) opens and saves without adding a BOM")
    }

    let boundary = root.appendingPathComponent("boundary.custom")
    let splitScalar = String(repeating: "a", count: 16_383) + "中🙂\n"
    try Data(splitScalar.utf8).write(to: boundary)
    guard try DocumentFile.open(boundary).storage?.string == splitScalar else {
        throw SessionError.invalid("TEST FAILED: a Unicode scalar crossing the probe boundary stays valid")
    }
    print("PASS a Unicode scalar crossing the probe boundary stays valid")
    try Data(repeating: 0x61, count: 16_384).write(to: boundary)
    let handle = try FileHandle(forWritingTo: boundary)
    try handle.seekToEnd(); try handle.write(contentsOf: Data([0]))
    try handle.truncate(atOffset: 1_073_741_824); try handle.close()
    _ = try LogFile(url: boundary)
    print("PASS log content probe stops before binary bytes beyond the first 16KiB, including a 1GiB sparse file")
    print("All text file tests passed.")
}
