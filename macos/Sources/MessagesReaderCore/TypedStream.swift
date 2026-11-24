import Foundation

/// Pulls the plain text out of the packed form Messages stores a message in.
///
/// Recent versions of macOS keep a message's words inside an archived
/// attributed string instead of a plain column. Apple's own unarchiver would
/// read it, but it runs whatever classes the data names, and this data is
/// written by other people. So the text is found by position instead, with
/// every step checked against the length of the data. Nothing is executed.
public enum TypedStream {
    private static let marker = Array("NSString".utf8)

    public static func text(from data: Data) -> String? {
        guard data.count > 16, data.count <= 4_000_000 else { return nil }
        let bytes = [UInt8](data)
        guard let start = find(marker, in: bytes, from: 0) else { return nil }
        // After the class name come a few bytes of bookkeeping, then "+",
        // which marks a run of text, then how long it is.
        var index = start + marker.count
        let limit = min(bytes.count, index + 24)
        while index < limit, bytes[index] != 0x2B { index += 1 }
        guard index < limit else { return nil }
        index += 1
        guard index < bytes.count else { return nil }
        var length = 0
        switch bytes[index] {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
            index += 3
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]) << 16 | Int(bytes[index + 4]) << 24
            index += 5
        case let short where short < 0x80:
            length = Int(short)
            index += 1
        default:
            return nil
        }
        guard length >= 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index..<index + length], encoding: .utf8)
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        var index = from
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0], bytes[index..<index + pattern.count].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }
}
