import Foundation

/// A single HTTP `Range: bytes=a-b` request clamped to a file of `size` bytes.
struct PS2ByteRange: Equatable, Sendable {
    let offset: UInt64
    let length: UInt64

    /// nil for a missing, malformed, multi-range or unsatisfiable header.
    static func parse(_ header: String?, size: UInt64) -> PS2ByteRange? {
        guard let header, header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash], last = spec[spec.index(after: dash)...]
        if first.isEmpty {
            guard let suffix = UInt64(last), suffix > 0 else { return nil }
            let length = min(suffix, size)
            return PS2ByteRange(offset: size - length, length: length)
        }
        guard let start = UInt64(first), start < size else { return nil }
        let end = last.isEmpty ? size - 1 : min(UInt64(last) ?? .max, size - 1)
        guard end >= start else { return nil }
        return PS2ByteRange(offset: start, length: end - start + 1)
    }

    func contentRange(size: UInt64) -> String { "bytes \(offset)-\(offset + length - 1)/\(size)" }
}
