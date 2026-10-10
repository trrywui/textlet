import Foundation
import Darwin

enum LogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class Cancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct LogCheckpoint { let offset: Int64; let line: Int; let previousCR: Bool }
struct LogIndex {
    let points: [LogCheckpoint]
    let lines: Int
    func before(_ offset: Int64) -> LogCheckpoint {
        var low = 0, high = points.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if points[middle].offset <= offset { low = middle } else { high = middle }
        }
        return points[low]
    }
}
struct LogPage {
    let start: Int64
    let end: Int64
    let text: String
    let firstLine: Int
    let startsMidLine: Bool
    let repairedUTF8: Bool
}

// pread, not mmap or a whole-file String. File size does not determine resident buffers.
// Immutable file identity/size and index can be shared safely with worker queues.
final class LogFile {
    static let blockSize = 256 * 1024
    static let pageSize = 48 * 1024
    let url: URL
    let size: Int64
    private let fd: Int32
    private let modified: timespec
    init(url: URL) throws {
        self.url = url
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw LogError.message("无法读取日志：\(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor); throw LogError.message("大日志查看只支持普通文件")
        }
        do {
            var head = Data(count: Int(min(info.st_size, Int64(TextFileContent.sampleLimit))))
            try head.withUnsafeMutableBytes { bytes in
                var total = 0
                while total < bytes.count {
                    let got = pread(descriptor, bytes.baseAddress!.advanced(by: total), bytes.count - total, off_t(total))
                    if got < 0 && errno == EINTR { continue }
                    guard got > 0 else { throw LogError.message("读取失败，文件可能已截断；请重新载入。") }
                    total += got
                }
            }
            let utf32 = head.starts(with: [0, 0, 0xfe, 0xff]) || head.starts(with: [0xff, 0xfe, 0, 0])
            let utf16 = head.starts(with: [0xff, 0xfe]) || head.starts(with: [0xfe, 0xff])
            if utf32 || utf16 {
                throw LogError.message("大日志模式支持 UTF-8 / ASCII。这个文件带有 UTF-16/32 标记，请先转为 UTF-8。")
            }
            try TextFileContent.inspect(head).validate(encoding: .utf8)
        } catch {
            close(descriptor); throw error
        }
        fd = descriptor; size = info.st_size; modified = info.st_mtimespec
        // Avoid filling the filesystem cache during a complete background scan.
        _ = fcntl(fd, F_NOCACHE, 1)
    }
    deinit { close(fd) }
    func validate() throws {
        var info = stat(), pathInfo = stat()
        guard fstat(fd, &info) == 0, stat(url.path, &pathInfo) == 0,
              info.st_ino == pathInfo.st_ino, info.st_dev == pathInfo.st_dev,
              info.st_size == size, info.st_mtimespec.tv_sec == modified.tv_sec,
              info.st_mtimespec.tv_nsec == modified.tv_nsec else {
            throw LogError.message("文件已变化或被替换，请点击“重新载入”读取最新内容。")
        }
    }
    func read(_ offset: Int64, count: Int) throws -> [UInt8] {
        let wanted = min(count, Int(max(0, size - offset)))
        var buffer = [UInt8](repeating: 0, count: wanted)
        var total = 0
        while total < wanted {
            let got = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress!.advanced(by: total), wanted - total, offset + Int64(total))
            }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw LogError.message("读取失败，文件可能已截断；请重新载入。") }
            total += got
        }
        return buffer
    }
    private func countLines(_ bytes: ArraySlice<UInt8>, line: inout Int, cr: inout Bool) {
        for c in bytes { if c == 13 || (c == 10 && !cr) { line += 1 }; cr = c == 13 }
    }
    func makeIndex(cancel: Cancellation, progress: ((Double) -> Void)? = nil) throws -> LogIndex? {
        try validate()
        var points = [LogCheckpoint(offset: 0, line: 1, previousCR: false)]
        var offset: Int64 = 0, line = 1, cr = false
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while offset < size {
            if cancel.cancelled { return nil }
            let bytes = try read(offset, count: Self.blockSize)
            countLines(bytes[...], line: &line, cr: &cr)
            offset += Int64(bytes.count)
            points.append(LogCheckpoint(offset: offset, line: line, previousCR: cr))
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress > 0.25 { progress?(Double(offset) / Double(size)); lastProgress = now }
        }
        try validate()
        return LogIndex(points: points, lines: line)
    }
    // Move a boundary only when it splits a complete, valid UTF-8 scalar.
    // Stray continuation bytes must remain in the page for replacement decoding.
    private func alignedBoundary(_ boundary: Int, in bytes: [UInt8]) -> Int {
        guard boundary > 0, boundary < bytes.count, bytes[boundary] & 0xc0 == 0x80 else { return boundary }
        for start in max(0, boundary - 3)..<boundary {
            let lead = bytes[start]
            let length: Int
            switch lead {
            case 0xc2...0xdf: length = 2
            case 0xe0...0xef: length = 3
            case 0xf0...0xf4: length = 4
            default: continue
            }
            let end = start + length
            if end > boundary, end <= bytes.count, String(bytes: bytes[start..<end], encoding: .utf8) != nil {
                return start
            }
        }
        return boundary
    }

    func page(at target: Int64, index: LogIndex?) throws -> LogPage {
        try validate()
        let target = min(max(0, target), max(0, size - 1))
        guard target == 0 || index != nil else { throw LogError.message("行号索引尚未就绪") }
        let lower = max(0, target - 4096)
        let bytes = try read(lower, count: Self.pageSize + Int(target - lower) + 4)
        var start = Int(target - lower)
        // Find a nearby logical-line start; very long lines stay bounded and show ↳.
        while start > 0 && bytes[start - 1] != 10 && bytes[start - 1] != 13 { start -= 1 }
        if start == 0 && lower > 0 { start = Int(target - lower) }
        if start < bytes.count, bytes[start] == 10, start > 0, bytes[start - 1] == 13 { start += 1 }
        start = alignedBoundary(start, in: bytes)
        var end = min(bytes.count, start + Self.pageSize)
        if lower + Int64(end) < size {
            var boundary = end
            while boundary > start + Self.pageSize / 2 && bytes[boundary - 1] != 10 && bytes[boundary - 1] != 13 { boundary -= 1 }
            if boundary > start + Self.pageSize / 2 { end = boundary }
            if end > start, bytes[end - 1] == 13, end < bytes.count, bytes[end] == 10 { end += 1 }
            end = alignedBoundary(end, in: bytes)
        }
        let absoluteStart = lower + Int64(start)
        let checkpoint = index?.before(absoluteStart) ?? LogCheckpoint(offset: 0, line: 1, previousCR: false)
        var line = checkpoint.line, cr = checkpoint.previousCR
        if absoluteStart > checkpoint.offset {
            let prefix = try read(checkpoint.offset, count: Int(absoluteStart - checkpoint.offset))
            countLines(prefix[...], line: &line, cr: &cr)
        }
        let previous = absoluteStart > 0 ? try read(absoluteStart - 1, count: 1).first : nil
        let continuation = previous != nil && previous != 10 && previous != 13
        let slice = bytes[start..<end]
        let valid = String(bytes: slice, encoding: .utf8)
        return LogPage(start: absoluteStart, end: lower + Int64(end), text: valid ?? String(decoding: slice, as: UTF8.self),
                       firstLine: line, startsMidLine: continuation, repairedUTF8: valid == nil)
    }
    // Streaming KMP handles a match across read boundaries without retaining all matches.
    // Search is literal, case-sensitive UTF-8. Cancellation is checked at least once per block.
    func search(_ query: String, from start: Int64, to limit: Int64? = nil, cancel: Cancellation,
                progress: ((Double) -> Void)? = nil) throws -> Int64? {
        let pattern = Array(query.utf8)
        guard !pattern.isEmpty, pattern.count <= 4096 else { throw LogError.message("请输入 1–4096 字节的查找内容") }
        try validate()
        var failure = [Int](repeating: 0, count: pattern.count), j = 0
        if pattern.count > 1 {
            for i in 1..<pattern.count {
                while j > 0 && pattern[i] != pattern[j] { j = failure[j - 1] }
                if pattern[i] == pattern[j] { j += 1 }; failure[i] = j
            }
        }
        let end = min(size, limit ?? size)
        var offset = min(max(0, start), end), matched = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while offset < end {
            if cancel.cancelled { return nil }
            let bytes = try read(offset, count: min(Self.blockSize, Int(end - offset)))
            for (i, c) in bytes.enumerated() {
                while matched > 0 && c != pattern[matched] { matched = failure[matched - 1] }
                if c == pattern[matched] { matched += 1 }
                if matched == pattern.count { try validate(); return offset + Int64(i + 1 - matched) }
            }
            offset += Int64(bytes.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress > 0.25 { progress?(Double(offset) / Double(max(1, size))); lastProgress = now }
        }
        try validate()
        return nil
    }
}
