import Foundation

// PS2 memory-card 3D save icon (`*.ico` / `*.icn`), decoded into renderer-independent data
// (PS2SaveBrowserView turns it into SceneKit geometry).
//
// Format references (all little-endian):
// - Martin Akesson, "PS2 Icon Format v0.5" (2003, BSD), https://ps2savetools.com/ps2icon-0.5.pdf
// - mymc+ `mymcplus/ps2icon.py` + `gui/icon_renderer.py` (GPL, not copied), https://github.com/thestr4ng3r/mymcplus
// - ticky/ps2iconsys `src/ps2_ps2icon.cpp` (MIT), https://github.com/ticky/ps2iconsys
// - caol64/ps2mc-browser `ps2mc/icon.py` (MIT), https://github.com/caol64/ps2mc-browser
//
// Layout:
//   header    u32 magic 0x00010000, u32 shapeCount, u32 textureType, u32 (always 1.0f), u32 vertexCount
//   vertices  per vertex: shapeCount × (s16 x, y, z, pad), s16 normal x, y, z, pad, s16 u, v, u8 r, g, b, a
//             (s16 fixed point: value / 4096; every 3 consecutive vertices form one triangle)
//   animation u32 tag 0x01, u32 frameLength, f32 speed, u32 playOffset, u32 frameCount, then per frame:
//             u32 shapeId, u32 keyCount, keyCount × (f32 time, f32 value). mymc+ reads this as a 16-byte
//             record with two "unknown" words plus keyCount-1 keys; ticky as 8 bytes plus keyCount keys.
//             Both are the same bytes: the "unknown" words are the first key. With keyCount 0 we consume
//             the 16-byte record like mymc+.
//   texture   128×128 16-bit texels (R bits 0–4, G 5–9, B 10–14, bit 15 = GS alpha/STQ flag, ignored by
//             every viewer). textureType bit 2 = textured, bit 3 = RLE-compressed (ps2mc-browser; known
//             values 0x06/0x07 raw, 0x0E/0x0F RLE). Raw = 32768 bytes. RLE = u32 byteSize, then u16 codes:
//             code with bit 15 set → copy the next (0x10000 - code) texels; otherwise repeat the next
//             texel `code` times (mymc+/ticky use 0xFF00 as the literal threshold; codes in between would
//             overflow the texture under their rule, so the sign-bit rule is a strict superset).

/// Errors thrown by `PS2IconSys` and `PS2Icon` parsing.
enum PS2IconFormatError: Error, Equatable {
    case badMagic
    case truncated
    case corrupt(String)
}

struct PS2Icon: Equatable, Sendable {
    struct Key: Equatable, Sendable {
        /// In animation frames (same unit as `Animation.frameLength`).
        var time: Float
        var weight: Float
    }

    /// Weight curve for one animation shape.
    struct Frame: Equatable, Sendable {
        var shapeIndex: Int
        var keys: [Key]
    }

    struct Animation: Equatable, Sendable {
        /// Loop length in animation frames.
        var frameLength: UInt32
        /// Stored but unused by known viewers (usually 1.0).
        var speed: Float
        var playOffset: UInt32
        var frames: [Frame]
    }

    struct Texture: Equatable, Sendable {
        static let side = 128
        var width: Int { Self.side }
        var height: Int { Self.side }
        /// Row-major, first row first, 4 bytes per pixel (RGBA, alpha always 255).
        var rgba8: Data

        func pixel(x: Int, y: Int) -> SIMD4<UInt8>? {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            let i = (y * width + x) * 4
            return rgba8.withUnsafeBytes { SIMD4($0[i], $0[i + 1], $0[i + 2], $0[i + 3]) }
        }

        /// A1B5G5R5 → RGBA8; 5-bit channels are expanded to the full 0...255 range, alpha forced opaque
        /// (Akesson §6.1; the alpha bit is 0 in many retail icons).
        static func rgba8(fromTexels texels: [UInt16]) -> Data {
            var out = Data(count: texels.count * 4)
            out.withUnsafeMutableBytes { p in
                for (i, c) in texels.enumerated() {
                    p[i * 4] = expand5(c)
                    p[i * 4 + 1] = expand5(c >> 5)
                    p[i * 4 + 2] = expand5(c >> 10)
                    p[i * 4 + 3] = 255
                }
            }
            return out
        }

        private static func expand5(_ v: UInt16) -> UInt8 {
            let c = UInt8(v & 0x1F)
            return c << 3 | c >> 2
        }
    }

    static let magic: UInt32 = 0x0001_0000
    static let fixedPointScale: Float = 4096
    /// Animation clock used when the caller has none: Akesson v0.5 §5.4 suggests 8 frames/s; mymc+ uses the same.
    static let defaultFramesPerSecond: Double = 8

    var textureType: UInt32
    /// Positions per animation shape: `shapes[shape][vertex]`, in icon units (PS2 icons are y-down;
    /// a typical icon spans roughly -4...4 — the renderer flips/scales as it likes).
    var shapes: [[SIMD3<Float>]]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    /// Raw vertex colors. PS2 GS convention is 0x80 = full intensity, but many icons use 0xFF. Some retail
    /// icons have alpha 0 on every vertex; mymc+ then ignores vertex alpha — see `usesVertexAlpha`.
    var colors: [SIMD4<UInt8>]
    var animation: Animation
    /// nil when the texture flag (bit 2) is clear and no texture data follows.
    var texture: Texture?

    var shapeCount: Int { shapes.count }
    var vertexCount: Int { normals.count }
    /// Every 3 consecutive vertices form a triangle; a trailing partial triangle is dropped.
    var triangleIndices: [UInt32] { (0..<UInt32(vertexCount / 3 * 3)).map { $0 } }
    var usesVertexAlpha: Bool { colors.contains { $0.w > 0 } }
    var isTextureCompressed: Bool { textureType & 0x08 != 0 }

    init(data: Data) throws {
        var r = PS2IconByteReader(data)
        guard try r.u32() == Self.magic else { throw PS2IconFormatError.badMagic }
        let shapeCount = Int(try r.u32())
        let textureType = try r.u32()
        self.textureType = textureType
        _ = try r.u32()
        let vertexCount = Int(try r.u32())
        guard shapeCount > 0 else { throw PS2IconFormatError.corrupt("no animation shapes") }
        guard vertexCount > 0 else { throw PS2IconFormatError.corrupt("no vertices") }

        // Size check before allocating anything proportional to header counts.
        let stride = shapeCount.multipliedReportingOverflow(by: 8)
        let vertexStride = stride.partialValue.addingReportingOverflow(20)
        let segment = vertexStride.partialValue.multipliedReportingOverflow(by: vertexCount)
        guard !stride.overflow, !vertexStride.overflow, !segment.overflow, segment.partialValue <= r.remaining
        else { throw PS2IconFormatError.truncated }

        let scale = Self.fixedPointScale
        var shapes = [[SIMD3<Float>]](repeating: [], count: shapeCount)
        for s in 0..<shapeCount { shapes[s].reserveCapacity(vertexCount) }
        var normals = [SIMD3<Float>](), uvs = [SIMD2<Float>](), colors = [SIMD4<UInt8>]()
        normals.reserveCapacity(vertexCount); uvs.reserveCapacity(vertexCount); colors.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            for s in 0..<shapeCount {
                shapes[s].append(try r.fixedVector() / scale)
            }
            normals.append(try r.fixedVector() / scale)
            uvs.append(SIMD2(Float(try r.i16()), Float(try r.i16())) / scale)
            colors.append(SIMD4(try r.u8(), try r.u8(), try r.u8(), try r.u8()))
        }
        self.shapes = shapes
        self.normals = normals
        self.uvs = uvs
        self.colors = colors

        guard try r.u32() == 0x01 else { throw PS2IconFormatError.corrupt("animation tag") }
        let frameLength = try r.u32()
        let speed = try r.f32()
        let playOffset = try r.u32()
        let frameCount = Int(try r.u32())
        guard frameCount <= r.remaining / 16 else { throw PS2IconFormatError.truncated }
        var frames = [Frame]()
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let shape = try r.u32()
            let keyCount = Int(try r.u32())
            let stored = max(keyCount, 1)
            guard stored <= r.remaining / 8 else { throw PS2IconFormatError.truncated }
            var keys = [Key]()
            keys.reserveCapacity(keyCount)
            for _ in 0..<stored {
                let key = Key(time: try r.f32(), weight: try r.f32())
                if keyCount > 0 { keys.append(key) }
            }
            frames.append(Frame(shapeIndex: Int(clamping: shape), keys: keys))
        }
        animation = Animation(frameLength: frameLength, speed: speed, playOffset: playOffset, frames: frames)

        if textureType & 0x04 != 0 || r.remaining > 0 {
            do {
                let texels = textureType & 0x08 != 0 ? try Self.decodeRLE(&r) : try Self.decodeRaw(&r)
                texture = Texture(rgba8: Texture.rgba8(fromTexels: texels))
            } catch where textureType & 0x04 == 0 {
                texture = nil  // Untextured icon with trailing bytes we don't understand.
            }
        } else {
            texture = nil
        }
    }

    private static let texelCount = Texture.side * Texture.side

    private static func decodeRaw(_ r: inout PS2IconByteReader) throws -> [UInt16] {
        guard r.remaining >= texelCount * 2 else { throw PS2IconFormatError.truncated }
        return try (0..<texelCount).map { _ in try r.u16() }
    }

    private static func decodeRLE(_ r: inout PS2IconByteReader) throws -> [UInt16] {
        let size = Int(try r.u32())
        guard size <= r.remaining else { throw PS2IconFormatError.truncated }
        var words = PS2IconByteReader(try r.bytes(size))
        var texels = [UInt16]()
        texels.reserveCapacity(texelCount)
        while words.remaining >= 2 {
            let code = try words.u16()
            if code & 0x8000 != 0 {
                let count = 0x10000 - Int(code)
                guard texels.count + count <= texelCount else { throw PS2IconFormatError.corrupt("RLE overflow") }
                for _ in 0..<count { texels.append(try words.u16()) }
            } else {
                let count = Int(code)
                guard texels.count + count <= texelCount else { throw PS2IconFormatError.corrupt("RLE overflow") }
                let texel = try words.u16()
                texels.append(contentsOf: repeatElement(texel, count: count))
            }
        }
        // A short stream leaves the rest black, as in mymc+ (zero-initialised buffer).
        texels.append(contentsOf: repeatElement(0, count: texelCount - texels.count))
        return texels
    }

    // MARK: Animation

    /// Normalised blend weight of each shape at `frame` (animation-frame units, wrapped by `frameLength`).
    /// Per shape: linear interpolation between the nearest keys before/after `frame`, looping across the
    /// end (mymc+ icon_renderer). Falls back to the first shape when no weight is positive.
    func shapeWeights(atFrame frame: Double) -> [Float] {
        let duration = Double(animation.frameLength)
        let t = duration > 0 && frame.isFinite ? frame.truncatingRemainder(dividingBy: duration) : 0
        let now = t < 0 ? t + duration : t
        var weights = [Float](repeating: 0, count: shapeCount)
        for f in animation.frames where f.shapeIndex < shapeCount {
            var last: (time: Double, value: Float)?
            var next: (time: Double, value: Float)?
            for key in f.keys where key.time.isFinite && key.weight.isFinite {
                let kt = Double(key.time)
                let before = kt <= now ? kt : kt - duration
                if last == nil || before > last!.time { last = (before, key.weight) }
                let after = kt >= now ? kt : kt + duration
                if next == nil || after < next!.time { next = (after, key.weight) }
            }
            guard let last, let next else { continue }
            let progress = next.time > last.time ? Float((now - last.time) / (next.time - last.time)) : 0
            weights[f.shapeIndex] += (1 - progress) * last.value + progress * next.value
        }
        let sum = weights.reduce(0) { $0 + max($1, 0) }
        guard sum > 0, sum.isFinite else {
            weights = weights.map { _ in 0 }
            weights[0] = 1
            return weights
        }
        return weights.map { max($0, 0) / sum }
    }

    /// Blended vertex positions at `time` seconds.
    func positions(atTime time: Double, framesPerSecond: Double = PS2Icon.defaultFramesPerSecond) -> [SIMD3<Float>] {
        guard shapeCount > 1 else { return shapes[0] }
        let weights = shapeWeights(atFrame: time * framesPerSecond)
        var out = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for (s, w) in weights.enumerated() where w > 0 {
            let shape = shapes[s]
            for i in 0..<vertexCount { out[i] += shape[i] * w }
        }
        return out
    }
}

/// Bounds-checked little-endian reader shared by the icon parsers.
struct PS2IconByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init<Bytes: Sequence>(_ data: Bytes) where Bytes.Element == UInt8 { bytes = Array(data) }

    var remaining: Int { bytes.count - offset }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw PS2IconFormatError.truncated }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }

    mutating func u8() throws -> UInt8 { try bytes(1).first! }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        var v: UInt32 = 0
        for (i, byte) in b.enumerated() { v |= UInt32(byte) << (8 * UInt32(i)) }
        return v
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    /// s16 x, y, z plus an unused s16.
    mutating func fixedVector() throws -> SIMD3<Float> {
        let v = SIMD3(Float(try i16()), Float(try i16()), Float(try i16()))
        _ = try u16()
        return v
    }
}
