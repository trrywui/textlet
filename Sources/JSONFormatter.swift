import Foundation

struct JSONFormatError: LocalizedError {
    let message: String
    let offset: Int
    var errorDescription: String? { "\(message)（UTF-8 字节位置 \(offset + 1)）" }
}

// Parse the grammar, but copy tokens verbatim: large integers, key order, duplicate
// keys and string escapes must not change just because whitespace is formatted.
struct JSONFormatter {
    private var bytes: [UInt8]
    private var output: [UInt8] = []
    private var cursor = 0
    static func format(_ text: String) throws -> String {
        guard text.utf8.count <= 2 * 1_048_576 else {
            throw JSONFormatError(message: "为控制内存，单次 JSON 格式化限 2MiB，可选中较小片段格式化", offset: 0)
        }
        var parser = JSONFormatter(bytes: Array(text.utf8))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.cursor == parser.bytes.count else { throw parser.error("JSON 后有多余内容") }
        if text.hasSuffix("\n") { parser.output.append(10) }
        return String(decoding: parser.output, as: UTF8.self)
    }
    private func error(_ message: String) -> JSONFormatError { JSONFormatError(message: message, offset: cursor) }
    private var current: UInt8? { cursor < bytes.count ? bytes[cursor] : nil }
    private mutating func whitespace() {
        while let c = current, c == 32 || c == 9 || c == 10 || c == 13 { cursor += 1 }
    }
    private mutating func newline(_ depth: Int) throws {
        output.append(10)
        output.append(contentsOf: repeatElement(UInt8(32), count: depth * 2))
        try budget()
    }
    private func budget() throws {
        if output.count > 8 * 1_048_576 { throw error("格式化结果超过 8MiB，请分段处理") }
    }
    private mutating func take(_ c: UInt8) throws {
        guard current == c else { throw error("JSON 语法错误") }
        output.append(c); cursor += 1
    }
    private mutating func value(depth: Int) throws {
        guard depth <= 128 else { throw error("JSON 嵌套超过 128 层") }
        whitespace()
        switch current ?? 0 {
        case 123, 91:
            let object = current == 123
            let closing: UInt8 = object ? 125 : 93
            try take(object ? 123 : 91)
            whitespace()
            if current == closing { try take(closing); return }
            while true {
                try newline(depth + 1)
                if object {
                    whitespace(); try string(); whitespace(); try take(58); output.append(32)
                }
                try value(depth: depth + 1)
                whitespace()
                if current == closing { break }
                try take(44)
            }
            try newline(depth); try take(closing)
        case 34: try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw error("这里需要一个 JSON 值")
        }
        try budget()
    }
    private mutating func string() throws {
        let start = cursor
        guard current == 34 else { throw error("对象的键必须用双引号包围") }
        cursor += 1
        while let c = current {
            cursor += 1
            if c == 34 { output.append(contentsOf: bytes[start..<cursor]); return }
            if c < 32 { throw error("字符串中有未转义的控制字符") }
            if c == 92 {
                guard let escape = current else { throw error("字符串转义不完整") }
                cursor += 1
                if escape == 117 {
                    for _ in 0..<4 {
                        guard let h = current, (48...57).contains(h) || (65...70).contains(h) || (97...102).contains(h) else {
                            throw error("Unicode 转义需要四位十六进制数字")
                        }
                        cursor += 1
                    }
                } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) {
                    throw error("无效的字符串转义")
                }
            }
        }
        throw error("字符串缺少结束引号")
    }
    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 { try take(byte) }
    }
    private mutating func number() throws {
        let start = cursor
        if current == 45 { cursor += 1 }
        if current == 48 { cursor += 1 }
        else {
            guard let c = current, (49...57).contains(c) else { throw error("无效的数字") }
            digits()
        }
        if current == 46 { cursor += 1; try requiredDigits() }
        if current == 101 || current == 69 {
            cursor += 1
            if current == 43 || current == 45 { cursor += 1 }
            try requiredDigits()
        }
        output.append(contentsOf: bytes[start..<cursor])
    }
    private mutating func digits() { while let c = current, (48...57).contains(c) { cursor += 1 } }
    private mutating func requiredDigits() throws {
        let start = cursor; digits()
        if start == cursor { throw error("数字不完整") }
    }
}
