import Foundation

// Inspect the existing buffer without copying the document or decoding it again.
enum TextFileContent {
    static let sampleLimit = 16 * 1024
    enum Failure: LocalizedError {
        case binary
        var errorDescription: String? { "此文件不是受支持的文本文件" }
    }

    enum Requirement {
        case unrestricted, wideUnicode
        func validate(encoding: String.Encoding) throws {
            if case .wideUnicode = self {
                switch encoding {
                case .utf16, .utf16LittleEndian, .utf16BigEndian,
                     .utf32, .utf32LittleEndian, .utf32BigEndian: break
                default: throw Failure.binary
                }
            }
        }
    }

    private static let signatures: [[UInt8]] = [
        Array("%PDF-".utf8),
        [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10], [0xff, 0xd8, 0xff],
        Array("GIF87a".utf8), Array("GIF89a".utf8),
        [0x50, 0x4b, 3, 4], [0x50, 0x4b, 5, 6], [0x50, 0x4b, 7, 8],
        [0x1f, 0x8b], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c],
        [0x52, 0x61, 0x72, 0x21, 0x1a, 7], [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0],
        Array("SQLite format 3\0".utf8), [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1],
        [0x7f, 0x45, 0x4c, 0x46],
        [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
        [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
        [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
        [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]
    ]

    static func inspect(_ data: Data) throws -> Requirement {
        try data.withUnsafeBytes { bytes in
            let sample = bytes.prefix(sampleLimit)
            // Wide Unicode must be decoded before interpreting its zero bytes.
            if sample.starts(with: [0xff, 0xfe]) || sample.starts(with: [0xfe, 0xff])
                || sample.starts(with: [0, 0, 0xfe, 0xff]) { return .unrestricted }
            let body = sample.dropFirst(sample.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0)
            if signatures.contains(where: { body.starts(with: $0) }) {
                throw Failure.binary
            }
            var controls = 0
            for byte in body {
                switch byte {
                // Defer to the reader's existing decoder for unmarked wide Unicode.
                case 0: return .wideUnicode
                case 1...8, 14...26, 28...31: controls += 1
                default: break // Keep tabs, newlines, form feeds and ANSI escapes.
                }
            }
            return controls > max(4, body.count / 10) ? .wideUnicode : .unrestricted
        }
    }
}
