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
        var hash = SHA256()
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buffer.deallocate() }
        var remaining = NSRange(location: 0, length: text.length)
        while remaining.length > 0 {
            var used = 0, next = NSRange()
            let converted = text.getBytes(buffer, maxLength: capacity, usedLength: &used,
                encoding: String.Encoding.utf8.rawValue, options: [], range: remaining, remaining: &next)
            guard converted, used > 0, next.location > remaining.location else {
                // Preserve Swift's replacement behavior for a malformed UTF-16 NSString.
                return digest(Data((text as String).utf8))
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: used))
            remaining = next
        }
        return hex(hash.finalize())
    }
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
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t
    }
    private struct Signature: Equatable {
        let identity: Identity
        let size: off_t
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
    }
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
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Signature(identity: Identity(device: info.st_dev, inode: info.st_ino), size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
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
