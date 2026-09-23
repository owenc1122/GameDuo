import Foundation
import XCTest
@testable import PS2Core

// MARK: - Synthetic file builders

private extension Data {
    mutating func u16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func fixed(_ bytes: [UInt8], _ length: Int) {
        append(contentsOf: bytes.prefix(length))
        if bytes.count < length { append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count)) }
    }
}

private func sjis(_ s: String) -> [UInt8] { [UInt8](s.data(using: .shiftJIS)!) }

private func makeIconSys(titleBytes: [UInt8], lineBreak: UInt16, alpha: UInt32 = 0x40,
                         bg: [[UInt32]] = [[1, 2, 3, 0], [4, 5, 6, 0], [7, 8, 9, 0], [0x80, 0x40, 0x20, 0]],
                         lightDirs: [[Float]] = [[0, 0, 1, 0], [-1, 0.5, 0.25, 0], [0.5, -0.5, 0, 0]],
                         lightColors: [[Float]] = [[1, 0.9, 0.8, 0], [0.5, 0.5, 0.5, 0], [0.1, 0.2, 0.3, 0]],
                         ambient: [Float] = [0.25, 0.25, 0.25, 0],
                         files: [String] = ["list.icn", "copy.icn", "del.icn"],
                         magic: String = "PS2D") -> Data {
    var d = Data()
    d.fixed(Array(magic.utf8), 4)
    d.u16(0)
    d.u16(lineBreak)
    d.u32(0)
    d.u32(alpha)
    for c in bg { c.forEach { d.u32($0) } }
    for v in lightDirs { v.forEach { d.f32($0) } }
    for v in lightColors { v.forEach { d.f32($0) } }
    ambient.forEach { d.f32($0) }
    d.fixed(titleBytes, 68)
    for f in files { d.fixed(Array(f.utf8), 64) }
    d.fixed([], 512)
    return d
}

private struct IcoSpec {
    var texType: UInt32 = 0x07
    /// positions[shape][vertex] = (x, y, z) raw int16
    var positions: [[(Int16, Int16, Int16)]]
    var normals: [(Int16, Int16, Int16)]
    var uvs: [(Int16, Int16)]
    var colors: [[UInt8]]
    var frameLength: UInt32 = 1
    var speed: Float = 1
    var playOffset: UInt32 = 0
    var frames: [(shape: UInt32, keys: [(Float, Float)])] = [(0, [(0, 1)])]
    /// Everything after the animation segment (raw texture, or u32 size + RLE words).
    var textureSegment: Data = Data(count: 32768)

    func build() -> Data {
        var d = Data()
        d.u32(0x0001_0000)
        d.u32(UInt32(positions.count))
        d.u32(texType)
        d.f32(1)
        d.u32(UInt32(normals.count))
        for v in 0..<normals.count {
            for s in 0..<positions.count {
                let p = positions[s][v]
                d.i16(p.0); d.i16(p.1); d.i16(p.2); d.i16(0)
            }
            let n = normals[v]
            d.i16(n.0); d.i16(n.1); d.i16(n.2); d.i16(0)
            d.i16(uvs[v].0); d.i16(uvs[v].1)
            d.append(contentsOf: colors[v])
        }
        d.u32(1)
        d.u32(frameLength)
        d.f32(speed)
        d.u32(playOffset)
        d.u32(UInt32(frames.count))
        for f in frames {
            d.u32(f.shape)
            d.u32(UInt32(f.keys.count))
            for k in f.keys { d.f32(k.0); d.f32(k.1) }
        }
        d.append(textureSegment)
        return d
    }
}

private func rawTexture(_ pixels: [UInt16]) -> Data {
    var d = Data()
    for i in 0..<(128 * 128) { d.u16(i < pixels.count ? pixels[i] : 0) }
    return d
}

private func rleTexture(_ words: [UInt16]) -> Data {
    var d = Data()
    d.u32(UInt32(words.count * 2))
    words.forEach { d.u16($0) }
    return d
}

private let triangle = IcoSpec(
    positions: [[(4096, -2048, 0), (0, 8192, -4096), (1024, 0, 2048)]],
    normals: [(0, 0, 4096), (0, -4096, 0), (4096, 0, 0)],
    uvs: [(0, 0), (4096, 0), (2048, 4096)],
    colors: [[0x80, 0x40, 0x20, 0x10], [255, 255, 255, 255], [0, 0, 0, 0]])

private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-5,
                         file: StaticString = #filePath, line: UInt = #line) {
    for i in 0..<3 { XCTAssertEqual(a[i], b[i], accuracy: accuracy, "component \(i)", file: file, line: line) }
}

// MARK: - icon.sys

final class PS2IconSysTests: XCTestCase {
    func testFullWidthAsciiTitleIsHalfWidthAndSplitAtLineBreak() throws {
        let line1 = sjis("ＳＡＶＥ　ＤＡＴＡ")
        XCTAssertEqual(Array(line1.prefix(2)), [0x82, 0x72])  // "Ｓ" in Shift-JIS
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: line1 + sjis("Ｓｌｏｔ　１"),
                                                   lineBreak: UInt16(line1.count)))
        XCTAssertEqual(icon.titleLines, ["SAVE DATA", "Slot 1"])
        XCTAssertEqual(icon.titleLineBreak, line1.count)
        XCTAssertEqual(icon.title, "SAVE DATA Slot 1")
    }

    func testJapaneseTitle() throws {
        let line1 = sjis("ドラゴン")
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: line1 + sjis("クエスト　セーブ"),
                                                   lineBreak: UInt16(line1.count)))
        XCTAssertEqual(icon.titleLines, ["ドラゴン", "クエスト セーブ"])
    }

    func testHandWrittenShiftJISBytes() throws {
        // "あＡ" / "b": 0x82A0 = あ, 0x8260 = Ａ
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: [0x82, 0xA0, 0x82, 0x60, 0x62], lineBreak: 4))
        XCTAssertEqual(icon.titleLines, ["あA", "b"])
    }

    func testLineBreakPastTitleGivesSingleLine() throws {
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: Array("Hello".utf8), lineBreak: 200))
        XCTAssertEqual(icon.titleLines, ["Hello", ""])
        XCTAssertEqual(icon.title, "Hello")
    }

    func testLineBreakZeroPutsEverythingOnSecondLine() throws {
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: Array("Hello".utf8), lineBreak: 0))
        XCTAssertEqual(icon.titleLines, ["", "Hello"])
    }

    func testInvalidShiftJISDoesNotCrash() throws {
        // 0x82 followed by an invalid trail byte, and a line break inside a double-byte character.
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: [0x41, 0x82, 0xFF, 0x82, 0xA0, 0x42], lineBreak: 4))
        XCTAssertEqual(icon.titleLines.count, 2)
        XCTAssertTrue(icon.titleLines[0].hasPrefix("A"))
        XCTAssertTrue(icon.titleLines[1].hasSuffix("B"))
    }

    func testColorsLightsAndFiles() throws {
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: Array("X".utf8), lineBreak: 1))
        XCTAssertEqual(icon.backgroundAlpha, 0x40)
        XCTAssertEqual(icon.backgroundColors, [SIMD4(1, 2, 3, 0), SIMD4(4, 5, 6, 0), SIMD4(7, 8, 9, 0), SIMD4(0x80, 0x40, 0x20, 0)])
        XCTAssertEqual(icon.lightDirections, [SIMD4(0, 0, 1, 0), SIMD4(-1, 0.5, 0.25, 0), SIMD4(0.5, -0.5, 0, 0)])
        XCTAssertEqual(icon.lightColors, [SIMD4(1, 0.9, 0.8, 0), SIMD4(0.5, 0.5, 0.5, 0), SIMD4(0.1, 0.2, 0.3, 0)])
        XCTAssertEqual(icon.ambient, SIMD4(0.25, 0.25, 0.25, 0))
        XCTAssertEqual(icon.iconFiles, PS2IconSys.IconFiles(normal: "list.icn", copy: "copy.icn", delete: "del.icn"))
        let unit = icon.backgroundColorsNormalized
        XCTAssertEqual(unit[3], SIMD4<Float>(1, 0.5, 0.25, 0.5))
        XCTAssertEqual(icon.backgroundOpacity, 0.5)
    }

    func testNormalizedColorsClampOutOfRangeValues() throws {
        let icon = try PS2IconSys(data: makeIconSys(titleBytes: [], lineBreak: 0, alpha: 0xFFFF_FFFF,
                                                   bg: [[255, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]]))
        XCTAssertEqual(icon.backgroundColorsNormalized[0], SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(icon.titleLines, ["", ""])
    }

    func testRejectsBadMagicAndTruncation() {
        let good = makeIconSys(titleBytes: Array("X".utf8), lineBreak: 1)
        XCTAssertEqual(good.count, 964)
        XCTAssertThrowsError(try PS2IconSys(data: makeIconSys(titleBytes: [], lineBreak: 0, magic: "PS2X"))) {
            XCTAssertEqual($0 as? PS2IconFormatError, .badMagic)
        }
        for n in [0, 3, 4, 100, 963] {
            XCTAssertThrowsError(try PS2IconSys(data: good.prefix(n)), "length \(n)")
        }
        // Works on a Data slice with a non-zero start index.
        var padded = Data([1, 2, 3])
        padded.append(good)
        XCTAssertNoThrow(try PS2IconSys(data: padded.dropFirst(3)))
    }
}

// MARK: - .ico

final class PS2IconTests: XCTestCase {
    func testSingleShapeVertexDecode() throws {
        var spec = triangle
        spec.textureSegment = rawTexture([])
        let icon = try PS2Icon(data: spec.build())
        XCTAssertEqual(icon.shapeCount, 1)
        XCTAssertEqual(icon.vertexCount, 3)
        XCTAssertEqual(icon.textureType, 0x07)
        assertClose(icon.shapes[0][0], SIMD3(1, -0.5, 0))
        assertClose(icon.shapes[0][1], SIMD3(0, 2, -1))
        assertClose(icon.shapes[0][2], SIMD3(0.25, 0, 0.5))
        assertClose(icon.normals[1], SIMD3(0, -1, 0))
        XCTAssertEqual(icon.uvs, [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.5, 1)])
        XCTAssertEqual(icon.colors[0], SIMD4<UInt8>(0x80, 0x40, 0x20, 0x10))
        XCTAssertEqual(icon.triangleIndices, [0, 1, 2])
        XCTAssertEqual(icon.animation.frames.count, 1)
        XCTAssertEqual(icon.animation.frames[0].keys, [PS2Icon.Key(time: 0, weight: 1)])
        XCTAssertEqual(icon.positions(atTime: 3.7), icon.shapes[0])
    }

    func testRawTexturePixelDecode() throws {
        var spec = triangle
        // red, green, blue, alpha-bit only, mid grey (4,4,4), white
        spec.textureSegment = rawTexture([0x001F, 0x03E0, 0x7C00, 0x8000, 0x1084, 0x7FFF])
        let tex = try XCTUnwrap(try PS2Icon(data: spec.build()).texture)
        XCTAssertEqual(tex.width, 128)
        XCTAssertEqual(tex.height, 128)
        XCTAssertEqual(tex.rgba8.count, 128 * 128 * 4)
        XCTAssertEqual(tex.pixel(x: 0, y: 0), SIMD4(255, 0, 0, 255))
        XCTAssertEqual(tex.pixel(x: 1, y: 0), SIMD4(0, 255, 0, 255))
        XCTAssertEqual(tex.pixel(x: 2, y: 0), SIMD4(0, 0, 255, 255))
        XCTAssertEqual(tex.pixel(x: 3, y: 0), SIMD4(0, 0, 0, 255))
        XCTAssertEqual(tex.pixel(x: 4, y: 0), SIMD4(33, 33, 33, 255))
        XCTAssertEqual(tex.pixel(x: 5, y: 0), SIMD4(255, 255, 255, 255))
        XCTAssertEqual(tex.pixel(x: 0, y: 1), SIMD4(0, 0, 0, 255))
        XCTAssertNil(tex.pixel(x: 128, y: 0))
    }

    func testRLETextureDecode() throws {
        var spec = triangle
        spec.texType = 0x0F
        // 16380 × red, then 4 literals: green, blue, white, grey.
        spec.textureSegment = rleTexture([16380, 0x001F, 0xFFFC, 0x03E0, 0x7C00, 0x7FFF, 0x1084])
        let tex = try XCTUnwrap(try PS2Icon(data: spec.build()).texture)
        XCTAssertEqual(tex.pixel(x: 0, y: 0), SIMD4(255, 0, 0, 255))
        XCTAssertEqual(tex.pixel(x: 123, y: 127), SIMD4(255, 0, 0, 255))
        XCTAssertEqual(tex.pixel(x: 124, y: 127), SIMD4(0, 255, 0, 255))
        XCTAssertEqual(tex.pixel(x: 125, y: 127), SIMD4(0, 0, 255, 255))
        XCTAssertEqual(tex.pixel(x: 126, y: 127), SIMD4(255, 255, 255, 255))
        XCTAssertEqual(tex.pixel(x: 127, y: 127), SIMD4(33, 33, 33, 255))
    }

    func testRLELongLiteralRunAndShortStreamPadsWithZero() throws {
        var spec = triangle
        spec.texType = 0x0E
        // 0xFF00 = 256 literal words (mymc/ticky rule), 0x8000–0xFEFF are literal runs too (sign bit, ps2mc-browser).
        spec.textureSegment = rleTexture([0xFF00] + [UInt16](repeating: 0x001F, count: 256)
                                         + [0xFFF0] + [UInt16](repeating: 0x03E0, count: 16))
        let tex = try XCTUnwrap(try PS2Icon(data: spec.build()).texture)
        XCTAssertEqual(tex.pixel(x: 127, y: 1), SIMD4(255, 0, 0, 255))
        XCTAssertEqual(tex.pixel(x: 0, y: 2), SIMD4(0, 255, 0, 255))
        XCTAssertEqual(tex.pixel(x: 16, y: 2), SIMD4(0, 0, 0, 255))
    }

    func testRLEOverflowAndTruncationThrow() {
        var spec = triangle
        spec.texType = 0x0F
        spec.textureSegment = rleTexture([0x7FFF, 0x001F])  // 32767 pixels > 16384
        XCTAssertThrowsError(try PS2Icon(data: spec.build()))
        spec.textureSegment = rleTexture([0xFFFC, 0x001F])  // literal run of 4, only 1 word present
        XCTAssertThrowsError(try PS2Icon(data: spec.build()))
        var bad = Data(); bad.u32(1000); bad.append(Data(count: 10))  // size larger than file
        spec.textureSegment = bad
        XCTAssertThrowsError(try PS2Icon(data: spec.build()))
    }

    func testNoTextureFlag() throws {
        var spec = triangle
        spec.texType = 0x03
        spec.textureSegment = Data()
        XCTAssertNil(try PS2Icon(data: spec.build()).texture)
    }

    func testTwoShapesInterpolation() throws {
        var spec = IcoSpec(
            positions: [[(0, 0, 0), (4096, 0, 0), (0, 4096, 0)],
                        [(0, 0, 8192), (8192, 0, 0), (0, -4096, 0)]],
            normals: [(0, 0, 4096), (0, 0, 4096), (0, 0, 4096)],
            uvs: [(0, 0), (0, 0), (0, 0)],
            colors: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        spec.frameLength = 20
        spec.frames = [(0, [(0, 1), (10, 0), (20, 1)]), (1, [(0, 0), (10, 1), (20, 0)])]
        spec.textureSegment = rawTexture([])
        let icon = try PS2Icon(data: spec.build())
        XCTAssertEqual(icon.shapeCount, 2)
        assertClose(icon.shapes[1][0], SIMD3(0, 0, 2))
        XCTAssertEqual(icon.animation.frameLength, 20)
        XCTAssertEqual(icon.animation.frames.map(\.shapeIndex), [0, 1])

        XCTAssertEqual(icon.shapeWeights(atFrame: 0), [1, 0])
        XCTAssertEqual(icon.shapeWeights(atFrame: 10), [0, 1])
        let w = icon.shapeWeights(atFrame: 5)
        XCTAssertEqual(w[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(w[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(icon.shapeWeights(atFrame: 25), icon.shapeWeights(atFrame: 5))  // loops

        // Default clock: 8 animation frames per second (Akesson v0.5 §5.4, mymc+ icon_renderer).
        assertClose(icon.positions(atTime: 0)[0], SIMD3(0, 0, 0))
        assertClose(icon.positions(atTime: 10.0 / 8)[1], SIMD3(2, 0, 0))
        assertClose(icon.positions(atTime: 5.0 / 8)[1], SIMD3(1.5, 0, 0))
        assertClose(icon.positions(atTime: 5.0 / 8)[2], SIMD3(0, 0, 0))
        assertClose(icon.positions(atTime: 2.5, framesPerSecond: 4)[1], SIMD3(2, 0, 0))
    }

    func testInterpolationWrapsBetweenLastAndFirstKey() throws {
        var spec = IcoSpec(
            positions: [[(0, 0, 0), (0, 0, 0), (0, 0, 0)], [(4096, 0, 0), (4096, 0, 0), (4096, 0, 0)]],
            normals: [(0, 0, 0), (0, 0, 0), (0, 0, 0)], uvs: [(0, 0), (0, 0), (0, 0)],
            colors: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        spec.frameLength = 20
        // Keys at 5 and 15 only: frame 0 lies halfway between 15 (wrapped to -5) and 5.
        spec.frames = [(0, [(5, 1), (15, 0)]), (1, [(5, 0), (15, 1)])]
        spec.textureSegment = rawTexture([])
        let icon = try PS2Icon(data: spec.build())
        let w = icon.shapeWeights(atFrame: 0)
        XCTAssertEqual(w[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(w[1], 0.5, accuracy: 1e-6)
    }

    func testMissingOrZeroWeightsFallBackToFirstShape() throws {
        var spec = IcoSpec(
            positions: [[(0, 0, 0), (0, 0, 0), (0, 0, 0)], [(4096, 0, 0), (4096, 0, 0), (4096, 0, 0)]],
            normals: [(0, 0, 0), (0, 0, 0), (0, 0, 0)], uvs: [(0, 0), (0, 0), (0, 0)],
            colors: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        spec.frames = [(7, [(0, 1)]), (1, [(0, 0)])]  // out-of-range shape id, zero weight
        spec.textureSegment = rawTexture([])
        let icon = try PS2Icon(data: spec.build())
        XCTAssertEqual(icon.shapeWeights(atFrame: 0), [1, 0])
        XCTAssertEqual(icon.positions(atTime: 1), icon.shapes[0])
    }

    func testFrameWithZeroKeysConsumesMymcLayout() throws {
        // mymc+ always reads 16 bytes of frame data even when the key count is 0.
        var spec = triangle
        spec.frames = []
        var body = spec.build().dropLast(32768)
        body.replaceSubrange((body.count - 4)..<body.count, with: [1, 0, 0, 0])  // frame count = 1
        var tail = Data(); tail.u32(0); tail.u32(0); tail.u32(0); tail.u32(0)
        let icon = try PS2Icon(data: body + tail + rawTexture([0x001F]))
        XCTAssertEqual(icon.animation.frames, [PS2Icon.Frame(shapeIndex: 0, keys: [])])
        XCTAssertEqual(icon.texture?.pixel(x: 0, y: 0), SIMD4(255, 0, 0, 255))
    }

    func testVertexCountNotMultipleOfThree() throws {
        var spec = triangle
        spec.positions[0].append((0, 0, 0))
        spec.normals.append((0, 0, 0)); spec.uvs.append((0, 0)); spec.colors.append([0, 0, 0, 0])
        spec.textureSegment = rawTexture([])
        let icon = try PS2Icon(data: spec.build())
        XCTAssertEqual(icon.vertexCount, 4)
        XCTAssertEqual(icon.triangleIndices, [0, 1, 2])
    }

    func testRejectsBadHeaders() {
        var spec = triangle
        spec.textureSegment = rawTexture([])
        var data = spec.build()
        data[0] = 0x02
        XCTAssertThrowsError(try PS2Icon(data: data)) { XCTAssertEqual($0 as? PS2IconFormatError, .badMagic) }

        // Absurd vertex count must fail on the size check, not by allocating.
        data = spec.build()
        data.replaceSubrange(16..<20, with: [0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try PS2Icon(data: data))
        data = spec.build()
        data.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])  // shape count
        XCTAssertThrowsError(try PS2Icon(data: data))
        data = spec.build()
        data.replaceSubrange(4..<8, with: [0, 0, 0, 0])  // zero shapes
        XCTAssertThrowsError(try PS2Icon(data: data))
        data = spec.build()
        data.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])  // huge shape count with zero vertices
        data.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try PS2Icon(data: data))
    }

    func testEveryTruncationThrows() throws {
        var spec = triangle
        spec.texType = 0x0F
        spec.frames = [(0, [(0, 1), (5, 0.5)])]
        spec.textureSegment = rleTexture([16384, 0x1234])
        let data = spec.build()
        XCTAssertNoThrow(try PS2Icon(data: data))
        for n in 0..<data.count {
            XCTAssertThrowsError(try PS2Icon(data: data.prefix(n)), "prefix \(n)")
        }
    }

    func testRandomCorruptionNeverCrashes() {
        var spec = IcoSpec(
            positions: [[(1, 2, 3), (4, 5, 6), (7, 8, 9)], [(9, 8, 7), (6, 5, 4), (3, 2, 1)]],
            normals: [(0, 0, 0), (0, 0, 0), (0, 0, 0)], uvs: [(0, 0), (0, 0), (0, 0)],
            colors: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        spec.texType = 0x0F
        spec.frames = [(0, [(0, 1), (5, 0)]), (1, [(0, 0), (5, 1)])]
        spec.textureSegment = rleTexture([0xFFFE, 1, 2, 100, 3])
        let base = [UInt8](spec.build())
        var rng = SplitMix64(seed: 42)
        for _ in 0..<800 {
            var bytes = base
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            if let icon = try? PS2Icon(data: Data(bytes)) {
                for t in [0.0, 0.3, 1.7, 1e9] { XCTAssertEqual(icon.positions(atTime: t).count, icon.vertexCount) }
            }
        }
    }

    func testPublicSampleIconParses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "list", withExtension: "icn",
                                                  subdirectory: "Fixtures/icons"))
        let icon = try PS2Icon(data: Data(contentsOf: url))
        XCTAssertEqual(icon.shapeCount, 1)
        XCTAssertEqual(icon.vertexCount, 744)
        XCTAssertEqual(icon.textureType, 0x07)
        XCTAssertEqual(icon.triangleIndices.count, 744)
        XCTAssertEqual(icon.animation.frameLength, 31)
        XCTAssertEqual(icon.animation.frames, [PS2Icon.Frame(shapeIndex: 0, keys: [PS2Icon.Key(time: 0, weight: 1)])])
        assertClose(icon.shapes[0][0], SIMD3(4130, -5210, -2055) / 4096)
        XCTAssertTrue(icon.shapes[0].allSatisfy { abs($0.x) < 8 && abs($0.y) < 8 && abs($0.z) < 8 })
        XCTAssertEqual(icon.colors[0], SIMD4(255, 255, 255, 255))
        let tex = try XCTUnwrap(icon.texture)
        // 0x0C64: r = 4, g = 3, b = 3 → (33, 24, 24)
        XCTAssertEqual(tex.pixel(x: 0, y: 0), SIMD4(33, 24, 24, 255))
        XCTAssertEqual(icon.positions(atTime: 2), icon.shapes[0])
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
