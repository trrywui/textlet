import AppKit
import CryptoKit

struct FileSignature: Codable, Equatable {
    struct Identity: Codable, Equatable { let device: dev_t, inode: ino_t }
    let identity: Identity
    let size: off_t
    let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
}

struct FileReference: Codable {
    var path: String
    var encoding: UInt
    var byteOrderMark: [UInt8]
    var diskDigest: String
    var textDigest: String
    var textLength: Int
    var modifiedAt: Date?
    var size: Int?
    var signature: FileSignature? = nil

    func differs(from text: NSString) -> Bool {
        text.length != textLength || DocumentFile.textDigest(text) != textDigest
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
    private static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: digest.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    // Read the existing NSString in bounded chunks; never bridge/copy the entire editor buffer.
    static func textDigest(_ text: NSString) -> String {
        var hash = SHA256(), offset = 0
        // UTF-8 uses at most three bytes per UTF-16 unit (a pair uses four).
        let capacity = 32768
        let units = UnsafeMutablePointer<unichar>.allocate(capacity: capacity)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * 3)
        defer { units.deallocate(); bytes.deallocate() }
        while offset < text.length {
            var count = min(capacity, text.length - offset)
            text.getCharacters(units, range: NSRange(location: offset, length: count))
            // Leave a split surrogate pair together in the next chunk.
            if offset + count < text.length && (0xd800...0xdbff).contains(units[count - 1]) && (0xdc00...0xdfff).contains(text.character(at: offset + count)) { count -= 1 }
            var input = 0, output = 0
            while input < count {
                let c = UInt32(units[input]); input += 1
                if c < 0x80 { bytes[output] = UInt8(c); output += 1 }
                else if c < 0x800 {
                    bytes[output] = UInt8(0xc0 | (c >> 6)); bytes[output + 1] = UInt8(0x80 | (c & 0x3f)); output += 2
                } else if c < 0xd800 || c > 0xdfff {
                    bytes[output] = UInt8(0xe0 | (c >> 12)); bytes[output + 1] = UInt8(0x80 | ((c >> 6) & 0x3f)); bytes[output + 2] = UInt8(0x80 | (c & 0x3f)); output += 3
                } else if c < 0xdc00 && input < count && (0xdc00...0xdfff).contains(units[input]) {
                    let scalar = 0x10000 + ((c - 0xd800) << 10) + UInt32(units[input] - 0xdc00); input += 1
                    bytes[output] = UInt8(0xf0 | (scalar >> 18)); bytes[output + 1] = UInt8(0x80 | ((scalar >> 12) & 0x3f)); bytes[output + 2] = UInt8(0x80 | ((scalar >> 6) & 0x3f)); bytes[output + 3] = UInt8(0x80 | (scalar & 0x3f)); output += 4
                // Match Swift UTF-8 replacement of an unpaired surrogate.
                } else { bytes[output] = 0xef; bytes[output + 1] = 0xbf; bytes[output + 2] = 0xbd; output += 3 }
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: output)); offset += count
        }
        return hex(hash.finalize())
    }
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func signature(at url: URL) throws -> FileSignature {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileSignature(identity: .init(device: info.st_dev, inode: info.st_ino), size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
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
            return .present(hex(hash.finalize()))
        } catch {
            if isMissing(error) { return .absent }
            throw error
        }
    }
    static func reference(url: URL, text: String, data: Data, encoding: String.Encoding, bom: [UInt8]) -> FileReference {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let diskDigest = digest(data)
        return FileReference(path: url.path, encoding: encoding.rawValue, byteOrderMark: bom,
            diskDigest: diskDigest, textDigest: encoding == .utf8 && bom.isEmpty ? diskDigest : textDigest(text as NSString), textLength: (text as NSString).length,
            modifiedAt: attributes?[.modificationDate] as? Date, size: attributes?[.size] as? Int, signature: try? signature(at: url))
    }
    static func open(_ source: URL) throws -> Note {
        let url = canonical(source)
        let data = try Data(contentsOf: url)
        let content = try TextFileContent.inspect(data)
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
        guard let text else {
            try content.validate(encoding: .utf8)
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        try content.validate(encoding: encoding)
        // Foundation can report generic UTF-32 for unmarked input. Preserve the
        // source byte order explicitly so saving does not add an implicit BOM.
        if marker == nil && encoding == .utf32 {
            encoding = .utf32LittleEndian
            for (index, scalar) in text.unicodeScalars.prefix(min(data.count, TextFileContent.sampleLimit) / 4).enumerated() {
                let i = index * 4
                let little = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
                let big = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
                if little != big {
                    encoding = little == scalar.value ? .utf32LittleEndian : .utf32BigEndian
                    break
                }
            }
        }
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
        var data = encoded
        if !bom.isEmpty { data = Data(bom); data.append(encoded) }
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

// One directory source is shared by all tabs in that directory. File sources stay
// attached until their inode changes; unrelated directory writes do not rebuild them.
final class FileWatch {
    private typealias Signature = FileSignature
    private final class DirectorySource {
        let source: DispatchSourceFileSystemObject
        var invalidated = false
        var callbacks: [UUID: () -> Void] = [:]
        init?(path: String) {
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.delete, .rename, .write, .attrib, .revoke], queue: .main)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if !self.source.data.intersection([.delete, .rename, .revoke]).isEmpty { self.invalidated = true }
                // Reconciliation may move subscribers to another directory.
                for callback in Array(self.callbacks.values) { callback() }
            }
            source.resume()
        }
        deinit { source.cancel() }
    }
    private static var directories: [String: DirectorySource] = [:]
    static var watchedDirectoryCount: Int { directories.count }
    let url: URL
    private let subscriber = UUID()
    private var parentPath: String?
    private var directorySource: DirectorySource?
    private var fileSource: DispatchSourceFileSystemObject?
    private var signature: Signature?
    private let onChange: () -> Void
    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url; self.onChange = onChange
        reconcile(notify: false)
    }
    deinit { fileSource?.cancel(); unsubscribe() }
    private func unsubscribe() {
        guard let parentPath, let directory = directorySource else { return }
        directory.callbacks.removeValue(forKey: subscriber)
        if directory.callbacks.isEmpty, Self.directories[parentPath] === directory { Self.directories.removeValue(forKey: parentPath) }
        self.parentPath = nil
        directorySource = nil
    }
    private func readSignature() -> Signature? {
        try? DocumentFile.signature(at: url)
    }
    private func reconcile(notify: Bool = true) {
        let next = readSignature()
        if next?.identity != signature?.identity || (next != nil && fileSource == nil) {
            fileSource?.cancel(); fileSource = nil
            if next != nil {
                let fd = Darwin.open(url.path, O_EVTONLY)
                if fd >= 0 {
                    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                        eventMask: [.delete, .rename, .write, .attrib, .revoke], queue: .main)
                    source.setCancelHandler { Darwin.close(fd) }
                    source.setEventHandler { [weak self, weak source] in
                        if source?.data.contains(.revoke) == true { self?.fileSource?.cancel(); self?.fileSource = nil }
                        self?.reconcile()
                    }
                    fileSource = source; source.resume()
                }
            }
        }
        var parent = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path) && parent.path != "/" { parent.deleteLastPathComponent() }
        if parentPath != parent.path || directorySource?.invalidated == true || directorySource !== Self.directories[parent.path] {
            unsubscribe()
            let existing = Self.directories[parent.path]
            let directory = existing?.invalidated == false ? existing : DirectorySource(path: parent.path)
            if let directory {
                Self.directories[parent.path] = directory
                directory.callbacks[subscriber] = { [weak self] in self?.reconcile() }
                parentPath = parent.path
                directorySource = directory
            }
        }
        let changed = signature != next
        signature = next
        if notify && changed { onChange() }
    }
}
