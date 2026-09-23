import Foundation

// `icon.sys`: a PS2 save's title, browser background and icon lighting (964 bytes, little-endian).
//
// References: ps2savetools.com "icon.sys format" (https://www.ps2savetools.com/documents/iconsys-format/),
// mymc+ `mymcplus/ps2iconsys.py` and `gui/icon_renderer.py` (https://github.com/thestr4ng3r/mymcplus),
// ticky/ps2iconsys `include/ps2_iconsys.hpp` (https://github.com/ticky/ps2iconsys).
//
//   0x000  4  "PS2D"
//   0x004  2  0
//   0x006  2  byte offset of the title's second line
//   0x008  4  0
//   0x00C  4  background opacity, 0x00 (transparent) ... 0x80 (opaque)
//   0x010 64  background colours, 4 × u32 RGB(-): upper left, upper right, lower left, lower right; 0x00...0x80
//   0x050 48  light directions, 3 × f32×4
//   0x080 48  light colours, 3 × f32×4 (RGB-)
//   0x0B0 16  ambient light, f32×4 (RGB-)
//   0x0C0 68  title, Shift-JIS, NUL-terminated
//   0x104 64  icon file shown normally       (NUL-terminated)
//   0x144 64  icon file shown while copying
//   0x184 64  icon file shown while deleting
//   0x1C4 512 0

struct PS2IconSys: Equatable, Sendable {
    struct IconFiles: Equatable, Sendable {
        var normal: String
        var copy: String
        var delete: String
    }

    static let size = 964
    /// PS2 GS colour convention: 0x80 = full intensity.
    static let fullIntensity: Float = 128

    /// Always two entries (second may be empty), decoded from Shift-JIS with full-width ASCII turned into
    /// half-width and surrounding whitespace trimmed.
    var titleLines: [String]
    /// Byte offset of the second line inside the raw title, as stored.
    var titleLineBreak: Int
    /// Raw Shift-JIS title up to the first NUL.
    var rawTitle: Data
    /// 0x00...0x80, raw.
    var backgroundAlpha: UInt32
    /// Upper left, upper right, lower left, lower right; raw (x, y, z = R, G, B in 0x00...0x80, w unused).
    var backgroundColors: [SIMD4<UInt32>]
    var lightDirections: [SIMD4<Float>]
    var lightColors: [SIMD4<Float>]
    var ambient: SIMD4<Float>
    var iconFiles: IconFiles

    /// Both lines joined by a space, for single-line UI.
    var title: String { titleLines.filter { !$0.isEmpty }.joined(separator: " ") }

    var backgroundOpacity: Float { min(Float(backgroundAlpha), Self.fullIntensity) / Self.fullIntensity }

    /// Corner colours as 0...1 RGB with `backgroundOpacity` as alpha (same mapping as mymc+).
    var backgroundColorsNormalized: [SIMD4<Float>] {
        backgroundColors.map { c in
            let rgb = SIMD3(Float(min(c.x, 128)), Float(min(c.y, 128)), Float(min(c.z, 128))) / Self.fullIntensity
            return SIMD4(rgb, backgroundOpacity)
        }
    }

    init(data: Data) throws {
        var r = PS2IconByteReader(data)
        guard r.remaining >= Self.size else {
            throw r.remaining >= 4 && Array(data.prefix(4)) != Array("PS2D".utf8)
                ? PS2IconFormatError.badMagic : PS2IconFormatError.truncated
        }
        guard Array(try r.bytes(4)) == Array("PS2D".utf8) else { throw PS2IconFormatError.badMagic }
        try r.skip(2)
        titleLineBreak = Int(try r.u16())
        try r.skip(4)
        backgroundAlpha = try r.u32()
        backgroundColors = try (0..<4).map { _ in SIMD4(try r.u32(), try r.u32(), try r.u32(), try r.u32()) }
        let vectors = try (0..<7).map { _ in SIMD4(try r.f32(), try r.f32(), try r.f32(), try r.f32()) }
        lightDirections = Array(vectors[0..<3])
        lightColors = Array(vectors[3..<6])
        ambient = vectors[6]

        let title = Self.zeroTerminated(try r.bytes(68))
        rawTitle = Data(title)
        let split = min(titleLineBreak, title.count)
        titleLines = [Self.displayString(title.prefix(split)), Self.displayString(title.dropFirst(split))]

        let files = try (0..<3).map { _ in Self.fileName(Self.zeroTerminated(try r.bytes(64))) }
        iconFiles = IconFiles(normal: files[0], copy: files[1], delete: files[2])
    }

    // MARK: Text

    private static func zeroTerminated(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array(bytes.prefix { $0 != 0 })
    }

    private static func fileName(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    /// Shift-JIS → display text: full-width ASCII/space to half-width, trimmed.
    static func displayString<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let decoded = decodeShiftJIS(Array(bytes))
        var scalars = String.UnicodeScalarView()
        for s in decoded.unicodeScalars {
            switch s.value {
            case 0xFF01...0xFF5E: scalars.append(Unicode.Scalar(s.value - 0xFEE0)!)
            case 0x3000: scalars.append(" ")
            default: scalars.append(s)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lossy Shift-JIS decode: invalid sequences (or a line break that splits a double-byte character)
    /// become U+FFFD instead of failing the whole string.
    static func decodeShiftJIS(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .shiftJIS) { return s }
        var out = ""
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            let isLead = (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)
            if isLead, i + 1 < bytes.count, let s = String(bytes: bytes[i...(i + 1)], encoding: .shiftJIS) {
                out += s
                i += 2
            } else if !isLead, let s = String(bytes: [b], encoding: .shiftJIS) {
                out += s
                i += 1
            } else {
                out += "\u{FFFD}"
                i += 1
            }
        }
        return out
    }
}
