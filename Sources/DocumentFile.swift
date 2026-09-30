import AppKit
import CryptoKit

struct FileReference: Codable {
    var path: String
    var encoding: UInt
    var byteOrderMark: [UInt8]
    var diskDigest: String
    var textDigest: String
    var textLength: Int
    var modifiedAt: Date?
    var size: Int?

    func differs(from text: NSString) -> Bool {
        text.length != textLength || DocumentFile.digest(Data((text as String).utf8)) != textDigest
    }
}

enum DocumentFileError: LocalizedError {
    case changed, encoding
    var errorDescription: String? {
        switch self {
        case .changed: return "文件在保存过程中发生了变化，请重新保存以选择处理方式。"
        case .encoding: return "当前文件编码无法无损保存这些字符。原文件未改动，可使用“另存为”保存为 UTF-8。"
        }
    }
}

enum DocumentFile {
    enum Version: Equatable { case absent, present(String) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
    static func version(at url: URL) throws -> Version {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let block = try handle.read(upToCount: 256 * 1024), !block.isEmpty { hash.update(data: block) }
            return .present(hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            if isMissing(error) { return .absent }
            throw error
        }
    }
    static func reference(url: URL, text: String, data: Data, encoding: String.Encoding, bom: [UInt8]) -> FileReference {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileReference(path: url.path, encoding: encoding.rawValue, byteOrderMark: bom,
            diskDigest: digest(data), textDigest: digest(Data(text.utf8)), textLength: (text as NSString).length,
            modifiedAt: attributes?[.modificationDate] as? Date, size: attributes?[.size] as? Int)
    }
    static func open(_ source: URL) throws -> Note {
        let url = canonical(source)
        let data = try Data(contentsOf: url)
        let markers: [([UInt8], String.Encoding)] = [([0xff, 0xfe, 0, 0], .utf32LittleEndian),
            ([0, 0, 0xfe, 0xff], .utf32BigEndian), ([0xef, 0xbb, 0xbf], .utf8),
            ([0xff, 0xfe], .utf16LittleEndian), ([0xfe, 0xff], .utf16BigEndian)]
        let marker = markers.first { data.starts(with: $0.0) }
        var encoding = marker?.1 ?? .utf8
        let bom = marker?.0 ?? []
        var text = String(data: data.dropFirst(bom.count), encoding: encoding)
        if text == nil && marker == nil {
            var decoded: NSString?
            var lossy: ObjCBool = false
            let raw = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &decoded, usedLossyConversion: &lossy)
            if raw != 0 && !lossy.boolValue { encoding = String.Encoding(rawValue: raw); text = decoded as String? }
        }
        guard let text else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let note = Note(name: url.lastPathComponent, text: text)
        note.record.file = reference(url: url, text: text, data: data, encoding: encoding, bom: bom)
        note.record.fileModified = false
        return note
    }

    // Only explicit saves call this. Session backups never write a linked file.
    static func write(_ note: Note, text: String, to destination: URL, expected: Version, asUTF8: Bool = false) throws {
        let url = canonical(destination)
        let encoding = asUTF8 ? String.Encoding.utf8 : note.record.file.map { String.Encoding(rawValue: $0.encoding) } ?? .utf8
        let bom = asUTF8 ? [] : note.record.file?.byteOrderMark ?? []
        guard let encoded = text.data(using: encoding, allowLossyConversion: false) else { throw DocumentFileError.encoding }
        var data = Data(bom); data.append(encoded)
        guard try version(at: url) == expected else { throw DocumentFileError.changed }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        note.record.file = reference(url: url, text: text, data: data, encoding: encoding, bom: bom)
        note.record.fileModified = false
        note.record.name = url.lastPathComponent
        note.record.automaticTitle = false
        note.record.contentTitle = nil
        note.fileMissing = false
        note.fileChangedExternally = false
    }
}

// Observe the file and its directory, including replacement, removal and return.
// No polling timer; a missing directory is watched through its nearest ancestor.
final class FileWatch {
    let url: URL
    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: () -> Void
    init(url: URL, onChange: @escaping () -> Void) { self.url = url; self.onChange = onChange; rebuild() }
    deinit { sources.forEach { $0.cancel() } }
    private func rebuild() {
        sources.forEach { $0.cancel() }; sources.removeAll()
        var parent = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path) && parent.path != "/" { parent.deleteLastPathComponent() }
        for path in [url.path, parent.path] {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.delete, .rename, .write, .attrib, .revoke], queue: .main)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.rebuild(); self.onChange()
            }
            sources.append(source); source.resume()
        }
    }
}
