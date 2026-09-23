import XCTest
@testable import PS2Core

/// Fixtures in Fixtures/saves were written by `make_fixtures.py`, a Python 3 port of mymc's
/// `save_ems`, `save_max_drive` and `lzari.encode` — an implementation independent of ours.
final class PS2SaveArchiveTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/saves").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// 2004-03-15 12:34:56 UTC, the timestamp baked into the mymc .psu fixture.
    static let fixtureDate = Date(timeIntervalSince1970: 1_079_354_096)

    // MARK: Timestamps / directory entries

    func testTimestampIsJST() {
        let bytes = PS2Timestamp.encode(Self.fixtureDate)
        // 12:34:56 UTC == 21:34:56 JST, 2004 = 0x07D4.
        XCTAssertEqual(bytes, [0, 56, 34, 21, 15, 3, 0xD4, 0x07])
        XCTAssertEqual(PS2Timestamp.decode(bytes), Self.fixtureDate)
        XCTAssertNil(PS2Timestamp.decode([UInt8](repeating: 0, count: 8)))
        // Day rolls over across the JST offset.
        let lateUTC = Date(timeIntervalSince1970: 1_079_386_200)  // 2004-03-15 21:30 UTC
        XCTAssertEqual(PS2Timestamp.encode(lateUTC)[3...5], [6, 16, 3])
    }

    func testDirEntryLayout() throws {
        let entry = PS2MCDirEntry(mode: PS2MCDirEntry.fileMode, length: 0x1234, created: Self.fixtureDate,
                                  modified: Self.fixtureDate, name: "icon.sys")
        let data = try entry.encoded()
        XCTAssertEqual(data.count, 512)
        XCTAssertEqual([UInt8](data[0..<8]), [0x17, 0x84, 0, 0, 0x34, 0x12, 0, 0])
        XCTAssertEqual([UInt8](data[0x40..<0x48]), Array("icon.sys".utf8))
        XCTAssertEqual(data[0x48], 0)
        let back = try PS2MCDirEntry(data, at: 0)
        XCTAssertTrue(back.isFile)
        XCTAssertEqual(back.name, "icon.sys")
        XCTAssertEqual(back.modified, Self.fixtureDate)
        XCTAssertThrowsError(try PS2MCDirEntry(mode: 0, length: 0, created: nil, modified: nil,
                                               name: String(repeating: "x", count: 33)).encoded())
    }

    // MARK: .psu

    func testReadsMymcPSU() throws {
        let data = try Self.fixture("mymc-BASLUS-20312GAME.psu")
        XCTAssertEqual(PS2SaveArchive.detectFormat(data), .psu)
        let save = try PS2SaveArchive.read(data)
        XCTAssertEqual(save.directoryName, "BASLUS-20312GAME")
        XCTAssertEqual(save.files.map(\.name), ["icon.sys", "view.ico", "BASLUS-20312GAME", "empty.bin"])
        XCTAssertEqual(save.files.map(\.data.count), [964, 604, 7624, 0])
        XCTAssertEqual(save.files[0].data.prefix(4), Data("PS2D".utf8))
        XCTAssertTrue(save.files[2].data.starts(with: Data("GAME DUO PS2 SAVE GAME".utf8)))
        XCTAssertEqual(save.modified, Self.fixtureDate)
        XCTAssertEqual(save.files[1].modified, Self.fixtureDate)
    }

    func testPSUWriterMatchesMymcByteForByte() throws {
        let data = try Self.fixture("mymc-BASLUS-20312GAME.psu")
        XCTAssertEqual(try PS2SaveArchive.readPSU(data).psuData(), data)
    }

    func testPSURoundTrip() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let save = PS2SaveArchive(directoryName: "BESLES-12345SAVE", files: [
            .init(name: "icon.sys", data: Data(repeating: 7, count: 964), created: t, modified: t),
            .init(name: "data", data: Data((0..<3000).map { UInt8($0 & 0xFF) }), created: t, modified: t + 60),
            .init(name: "exact1k", data: Data(repeating: 1, count: 1024), created: t, modified: t),
        ], created: t, modified: t + 60)
        let psu = try save.psuData()
        XCTAssertEqual(psu.count, 512 * 6 + 1024 + 3072 + 1024)
        XCTAssertEqual(try PS2SaveArchive.read(psu), save)
    }

    func testPSUToleratesMissingTrailingPadding() throws {
        let save = PS2SaveArchive(directoryName: "DIR", files: [.init(name: "a", data: Data([1, 2, 3]))],
                                  created: Self.fixtureDate, modified: Self.fixtureDate)
        let psu = try save.psuData()
        let trimmed = psu.prefix(psu.count - 1021)
        XCTAssertEqual(try PS2SaveArchive.read(Data(trimmed)).files.first?.data, Data([1, 2, 3]))
    }

    func testPSURejectsTraversalAndBrokenInput() throws {
        func psu(dir: String, files: [(String, UInt16, Data)]) throws -> Data {
            var out = try PS2MCDirEntry(mode: PS2MCDirEntry.dirMode, length: UInt32(files.count + 2),
                                        created: nil, modified: nil, name: dir).encoded()
            for dot in [".", ".."] {
                out += try PS2MCDirEntry(mode: PS2MCDirEntry.dirMode, length: 0, created: nil, modified: nil, name: dot).encoded()
            }
            for (name, mode, data) in files {
                out += try PS2MCDirEntry(mode: mode, length: UInt32(data.count), created: nil, modified: nil, name: name).encoded()
                out += data + Data(count: PS2SaveArchive.roundUp(data.count, 1024) - data.count)
            }
            return out
        }
        let file = PS2MCDirEntry.fileMode
        for bad in ["..", "../evil", "/etc", "a/b", "a\\b", ".hidden", ""] {
            XCTAssertThrowsError(try PS2SaveArchive.read(psu(dir: bad, files: [("f", file, Data([1]))])), bad) {
                XCTAssertEqual($0 as? PS2SaveError, .invalidName(bad))
            }
            XCTAssertThrowsError(try PS2SaveArchive.read(psu(dir: "OK", files: [(bad, file, Data([1]))])), bad) {
                XCTAssertEqual($0 as? PS2SaveError, .invalidName(bad))
            }
        }
        XCTAssertThrowsError(try PS2SaveArchive.read(psu(dir: "OK", files: [("f", file, Data([1])), ("f", file, Data([2]))]))) {
            XCTAssertEqual($0 as? PS2SaveError, .duplicateFileName("f"))
        }
        XCTAssertThrowsError(try PS2SaveArchive.read(psu(dir: "OK", files: [("sub", PS2MCDirEntry.dirMode, Data())]))) {
            XCTAssertEqual($0 as? PS2SaveError, .unsupportedSubdirectory("sub"))
        }
        let good = try psu(dir: "OK", files: [("f", file, Data(repeating: 9, count: 100))])
        XCTAssertThrowsError(try PS2SaveArchive.read(good.prefix(512 * 4 + 50))) {
            XCTAssertEqual($0 as? PS2SaveError, .corrupt("psu: truncated file data"))
        }
        XCTAssertThrowsError(try PS2SaveArchive.read(Data(repeating: 0, count: 2000))) {
            XCTAssertEqual($0 as? PS2SaveError, .unrecognizedFormat)
        }
        XCTAssertNotNil(PS2SaveError.alreadyExists("X").errorDescription)
    }

    // MARK: .max / LZARI

    func testReadsMymcMAX() throws {
        let max = try PS2SaveArchive.read(Self.fixture("mymc-BASLUS-20312GAME.max"))
        let psu = try PS2SaveArchive.read(Self.fixture("mymc-BASLUS-20312GAME.psu"))
        XCTAssertEqual(max.directoryName, "BASLUS-20312GAME")
        XCTAssertEqual(max.files.map(\.name), psu.files.map(\.name))
        XCTAssertEqual(max.files.map(\.data), psu.files.map(\.data))
        XCTAssertNil(max.modified)  // MAX has no timestamps
    }

    func testLZARIRoundTripWithTestEncoder() throws {
        var rng = SplitMix(seed: 42)
        let inputs: [[UInt8]] = [
            [0x41],
            Array("   leading spaces hit the preset ring buffer".utf8),
            [UInt8](repeating: 0, count: 20_000),                      // long matches, model rescaling
            (0..<6000).map { _ in UInt8.random(in: 0...255, using: &rng) }, // incompressible
            Array(String(repeating: "PlayStation 2 memory card ", count: 400).utf8)
                + (0..<5000).map { UInt8($0 % 251) },                  // text, then a period-251 pattern
        ]
        for input in inputs {
            let encoded = LZARIEncoder.encode(input)
            XCTAssertEqual(try PS2LZARI.decode(encoded, outputLength: input.count), input, "len \(input.count)")
        }
    }

    func testLZARIStreamFromMymcEncoder() throws {
        // `lzari_codec().encode(b"abcabcabcabc  PS2 PS2 PS2!")` from the mymc port in make_fixtures.py:
        // literals, a length-3 then a length-6 match at distance 3, and matches into the space-filled
        // initial ring buffer.
        let encoded: [UInt8] = [0xB0, 0xA8, 0xC1, 0xE2, 0xA7, 0x75, 0xF9, 0x27, 0xA6,
                                0xBD, 0x11, 0x94, 0x61, 0x14, 0x84, 0x67, 0x5F, 0xC2]
        let expected = Array("abcabcabcabc  PS2 PS2 PS2!".utf8)
        XCTAssertEqual(try PS2LZARI.decode(encoded, outputLength: expected.count), expected)
        XCTAssertThrowsError(try PS2LZARI.decode([UInt8](), outputLength: 1000))
    }

    func testReadsMAXBuiltInTest() throws {
        let files: [(String, [UInt8])] = [("icon.sys", Array(repeating: 1, count: 964)),
                                          ("a.ico", Array(repeating: 2, count: 13)),
                                          ("save", Array("hello".utf8))]
        var payload: [UInt8] = []
        for (name, data) in files {
            payload += le32(UInt32(data.count)) + Array(name.utf8) + Array(repeating: 0, count: 32 - name.utf8.count)
            payload += data
            payload += Array(repeating: 0, count: PS2SaveArchive.roundUp(payload.count + 8, 16) - 8 - payload.count)
        }
        let compressed = LZARIEncoder.encode(payload)
        var max = Array("Ps2PowerSave".utf8) + le32(0)
        max += Array("BESCES-00000TEST".utf8) + Array(repeating: 0, count: 16)
        max += Array(repeating: 0, count: 32)
        max += le32(UInt32(compressed.count + 4)) + le32(UInt32(files.count)) + le32(UInt32(payload.count))
        max += compressed
        let save = try PS2SaveArchive.read(Data(max))
        XCTAssertEqual(save.directoryName, "BESCES-00000TEST")
        XCTAssertEqual(save.files.map(\.name), files.map(\.0))
        XCTAssertEqual(save.files.map { [UInt8]($0.data) }, files.map(\.1))
        XCTAssertThrowsError(try PS2SaveArchive.read(Data(max.prefix(0x5C + compressed.count / 2))))
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
}

/// Minimal LZARI encoder for tests: Okumura's arithmetic coder (LZARI.C `EncodeChar`,
/// `EncodePosition`, `EncodeEnd`) with a brute-force longest-match search instead of the binary tree.
/// Shares `PS2LZARI.Model`/`positionCum` with the decoder, like LZARI.C shares StartModel/UpdateModel.
enum LZARIEncoder {
    static func encode(_ input: [UInt8]) -> [UInt8] {
        typealias Z = PS2LZARI
        var bits: [UInt8] = []
        var low = 0, high = Z.q4, shifts = 0
        var model = Z.Model()
        let posCum = Z.positionCum

        func output(_ bit: UInt8) {
            bits.append(bit)
            while shifts > 0 { bits.append(bit ^ 1); shifts -= 1 }
        }
        func normalize() {
            while true {
                if high <= Z.q2 { output(0) }
                else if low >= Z.q2 { output(1); low -= Z.q2; high -= Z.q2 }
                else if low >= Z.q1 && high <= Z.q3 { shifts += 1; low -= Z.q1; high -= Z.q1 }
                else { break }
                low += low; high += high
            }
        }
        func encodeChar(_ ch: Int) {
            let sym = model.charToSym[ch], range = high - low
            high = low + range * model.symCum[sym - 1] / model.symCum[0]
            low += range * model.symCum[sym] / model.symCum[0]
            normalize()
            model.update(sym)
        }
        func encodePosition(_ p: Int) {
            let range = high - low
            high = low + range * posCum[p] / posCum[0]
            low += range * posCum[p + 1] / posCum[0]
            normalize()
        }

        // History = (N - F) spaces then the input, as the decoder's ring buffer sees it.
        let pre = Z.n - Z.f
        let text = [UInt8](repeating: 0x20, count: pre) + input
        var pos = pre
        while pos < text.count {
            let maxLen = min(Z.f, text.count - pos)
            var bestLen = 0, bestDist = 0
            if maxLen > Z.threshold {
                var cand = pos - 1
                while cand >= max(0, pos - Z.n) {   // distance 1...N, no overlap into lookahead
                    var l = 0
                    while l < maxLen, cand + l < pos, text[cand + l] == text[pos + l] { l += 1 }
                    if l > bestLen { bestLen = l; bestDist = pos - cand; if l == maxLen { break } }
                    cand -= 1
                }
            }
            if bestLen > Z.threshold {
                encodeChar(255 - Z.threshold + bestLen)
                encodePosition(bestDist - 1)
                pos += bestLen
            } else {
                encodeChar(Int(text[pos]))
                pos += 1
            }
        }
        shifts += 1
        output(low < Z.q1 ? 0 : 1)
        while bits.count % 8 != 0 { bits.append(0) }
        return stride(from: 0, to: bits.count, by: 8).map { i in
            bits[i..<i + 8].reduce(0) { $0 << 1 | $1 }
        }
    }
}

struct SplitMix: RandomNumberGenerator {
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
