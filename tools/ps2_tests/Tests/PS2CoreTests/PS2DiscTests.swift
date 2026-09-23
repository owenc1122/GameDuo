import Compression
import XCTest
@testable import PS2Core

final class PS2DiscTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PS2DiscTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Fixture content

    private static let ps2Cnf = "BOOT2 = cdrom0:\\SLUS_203.12;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n"
    private static let ps2Expected = PS2DiscKind.ps2(serial: "SLUS-20312", bootPath: "cdrom0:\\SLUS_203.12;1")

    private func ps2ISO(padRootEntries: Int = 0) -> Data {
        var root: [TestISO.Node] = (0..<padRootEntries).map { .file(String(format: "PAD%05d.DAT", $0), Data([UInt8($0 & 0xFF)])) }
        root += [
            .file("SLUS_203.12", Data(repeating: 0x7F, count: 3000)),
            .dir("MODULES", [.file("IOPRP.IMG", Data([1, 2, 3]))]),
            .file("SYSTEM.CNF", Data(Self.ps2Cnf.utf8)),
        ]
        return TestISO.build(root)
    }

    // MARK: - identify: plain ISO

    func testPS2PlainISO() throws {
        let url = try write(ps2ISO(), "game.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), Self.ps2Expected)
    }

    func testPS2ISOWithMultiSectorRootDirectory() throws {
        // ~120 records of 46 bytes overflow the first 2048-byte directory sector.
        let iso = ps2ISO(padRootEntries: 120)
        let url = try write(iso, "big.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), Self.ps2Expected)
    }

    func testPS2DemoDiscWithoutSerialKeepsBootPath() throws {
        let iso = TestISO.build([.file("SYSTEM.CNF", Data("boot2 = cdrom0:\\DEMO\\MAIN.ELF;1\n".utf8))])
        let url = try write(iso, "demo.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), .ps2(serial: nil, bootPath: "cdrom0:\\DEMO\\MAIN.ELF;1"))
    }

    func testPSPISOReadsDiscID() throws {
        let sfo = TestISO.paramSFO(["CATEGORY": "UG", "DISC_ID": "ULUS10041", "TITLE": "Test Game"])
        let iso = TestISO.build([
            .file("UMD_DATA.BIN", Data("ULUS-10041|0000000000000001|0001|G".utf8)),
            .dir("PSP_GAME", [.file("ICON0.PNG", Data([0x89, 0x50])), .file("PARAM.SFO", sfo)]),
        ])
        let url = try write(iso, "psp.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), .psp(discID: "ULUS10041"))
    }

    func testPSPISOWithUnreadableSFOStillPSP() throws {
        let iso = TestISO.build([.dir("PSP_GAME", [.file("PARAM.SFO", Data("junk".utf8))])])
        let url = try write(iso, "psp2.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), .psp(discID: nil))
    }

    func testPS1DiscIsUnknown() throws {
        let iso = TestISO.build([
            .file("SYSTEM.CNF", Data("BOOT = cdrom:\\SLUS_000.01;1\r\nTCB = 4\r\nEVENT = 10\r\nSTACK = 801FFFF0\r\n".utf8)),
            .file("SLUS_000.01", Data([0])),
        ])
        let url = try write(iso, "ps1.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), .unknown)
        let bin = try write(TestISO.toRaw2352(iso, mode: 2), "ps1.bin")
        XCTAssertEqual(PS2DiscProbe.identify(url: bin), .unknown)
    }

    func testISOWithoutMarkersIsUnknown() throws {
        let url = try write(TestISO.build([.file("README.TXT", Data("hi".utf8))]), "data.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), .unknown)
    }

    func testGarbageEmptyAndMissingFilesAreUnknown() throws {
        var rng = SystemRandomNumberGenerator()
        let garbage = Data((0..<100_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(garbage, "garbage.iso")), .unknown)
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(Data(), "empty.iso")), .unknown)
        XCTAssertEqual(PS2DiscProbe.identify(url: dir.appendingPathComponent("missing.iso")), .unknown)
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(Data("not a cue".utf8), "bad.cue")), .unknown)
    }

    func testCHDHeaderIsUnknown() throws {
        var chd = Data("MComprHD".utf8)
        chd.append(Data(repeating: 0, count: 200))
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(chd, "game.chd")), .unknown)
    }

    // MARK: - identify: raw 2352 + cue

    func testPS2RawMode2BinAndCue() throws {
        _ = try write(TestISO.toRaw2352(ps2ISO(), mode: 2), "My Game (USA).bin")
        let cue = "FILE \"My Game (USA).bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n    INDEX 01 00:00:00\r\n"
        let cueURL = try write(Data(cue.utf8), "My Game (USA).cue")
        XCTAssertEqual(PS2DiscProbe.identify(url: dir.appendingPathComponent("My Game (USA).bin")), Self.ps2Expected)
        XCTAssertEqual(PS2DiscProbe.identify(url: cueURL), Self.ps2Expected)
    }

    func testPS2RawMode1Bin() throws {
        let url = try write(TestISO.toRaw2352(ps2ISO(), mode: 1), "mode1.bin")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), Self.ps2Expected)
    }

    func testRaw2352WithISOExtensionIsDetectedByContent() throws {
        let url = try write(TestISO.toRaw2352(ps2ISO(), mode: 2), "raw.iso")
        XCTAssertEqual(PS2DiscProbe.identify(url: url), Self.ps2Expected)
    }

    func testCueSkipsAudioTrackAndResolvesSubdirectoryAndCase() throws {
        let sub = dir.appendingPathComponent("tracks")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try TestISO.toRaw2352(ps2ISO(), mode: 2).write(to: sub.appendingPathComponent("game (track 2).bin"))
        let cue = """
        REM comment
        FILE "tracks/audio.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "tracks/GAME (TRACK 2).BIN" BINARY
          TRACK 02 MODE2/2352
            INDEX 01 00:00:00
        """
        let cueURL = try write(Data(cue.utf8), "game.cue")
        XCTAssertEqual(PS2DiscProbe.identify(url: cueURL), Self.ps2Expected)
    }

    func testCueHonoursIndexOffset() throws {
        // Data track starts 2 seconds (150 frames) into the file.
        var bin = Data(repeating: 0, count: 150 * 2352)
        bin.append(TestISO.toRaw2352(ps2ISO(), mode: 2))
        _ = try write(bin, "offset.bin")
        let cue = "FILE \"offset.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 00 00:00:00\n    INDEX 01 00:02:00\n"
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(Data(cue.utf8), "offset.cue")), Self.ps2Expected)
    }

    func testCueWithMissingBinIsUnknown() throws {
        let cue = "FILE \"nope.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(Data(cue.utf8), "nope.cue")), .unknown)
    }

    // MARK: - identify: CSO

    func testPS2CSO() throws {
        let cso = TestISO.toCSO(ps2ISO(), blockSize: 2048, plainBlocks: [16, 19])
        XCTAssertLessThan(cso.count, ps2ISO().count)
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(cso, "game.cso")), Self.ps2Expected)
    }

    func testPS2CSOLargeBlocksWithAlignment() throws {
        let cso = TestISO.toCSO(ps2ISO(padRootEntries: 120), blockSize: 8192, align: 2, plainBlocks: [4])
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(cso, "big.cso")), Self.ps2Expected)
    }

    func testPSPCSO() throws {
        let sfo = TestISO.paramSFO(["DISC_ID": "NPJH50001"])
        let cso = TestISO.toCSO(TestISO.build([.dir("PSP_GAME", [.file("PARAM.SFO", sfo)])]), blockSize: 2048)
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(cso, "psp.cso")), .psp(discID: "NPJH50001"))
    }

    func testTruncatedCSOIsUnknown() throws {
        let cso = TestISO.toCSO(ps2ISO(), blockSize: 2048)
        XCTAssertEqual(PS2DiscProbe.identify(url: try write(cso.prefix(200), "cut.cso")), .unknown)
    }

    // MARK: - SYSTEM.CNF parsing

    func testParseSystemCnfBasic() {
        let r = PS2DiscProbe.parseSystemCnf(Self.ps2Cnf)
        XCTAssertEqual(r?.serial, "SLUS-20312")
        XCTAssertEqual(r?.bootPath, "cdrom0:\\SLUS_203.12;1")
    }

    func testParseSystemCnfTolerance() {
        let cases: [(String, String?)] = [
            ("BOOT2=cdrom0:\\SLUS_203.12;1", "SLUS-20312"),
            ("  boot2   =   cdrom0:\\slus_203.12;1  \n", "SLUS-20312"),
            ("BOOT2 = cdrom0:\\\\SCES_503.60;1\r\n", "SCES-50360"),
            ("BOOT2 = cdrom0:\\SLPM_654.21\n", "SLPM-65421"),
            ("VER = 1.00\nBOOT2\t=\tcdrom0:\\SLES_512.54;1\nVMODE = PAL\n", "SLES-51254"),
            ("BOOT2 = cdrom0:\\ SLUS_203.12 ;1\n", "SLUS-20312"),
            ("BOOT2 = cdrom0:\\DATA\\SLUS_203.12;1\n", "SLUS-20312"),
            ("BOOT2 = cdrom0:\\MAIN.ELF;1\n", nil),
            ("BOOT2 = cdrom0:\\SLUS_203.12;1\0\0\0", "SLUS-20312"),
        ]
        for (text, serial) in cases {
            let r = PS2DiscProbe.parseSystemCnf(text)
            XCTAssertNotNil(r, text)
            XCTAssertEqual(r?.serial, serial, text)
        }
    }

    func testParseSystemCnfRejectsPS1AndEmpty() {
        XCTAssertNil(PS2DiscProbe.parseSystemCnf("BOOT = cdrom:\\SLUS_000.01;1\r\nTCB = 4\r\n"))
        XCTAssertNil(PS2DiscProbe.parseSystemCnf(""))
        XCTAssertNil(PS2DiscProbe.parseSystemCnf("BOOT2 = \n"))
        XCTAssertNil(PS2DiscProbe.parseSystemCnf("VMODE = NTSC"))
    }

    func testNormalizedSerial() {
        XCTAssertEqual(PS2DiscProbe.normalizedSerial(fromBootPath: "cdrom0:\\SLUS_203.12;1"), "SLUS-20312")
        XCTAssertEqual(PS2DiscProbe.normalizedSerial(fromBootPath: "cdrom0:/scus_971.13"), "SCUS-97113")
        XCTAssertEqual(PS2DiscProbe.normalizedSerial(fromBootPath: "SLPS-25053"), "SLPS-25053")
        XCTAssertNil(PS2DiscProbe.normalizedSerial(fromBootPath: "cdrom0:\\SLUS_2031.2;1"))
        XCTAssertNil(PS2DiscProbe.normalizedSerial(fromBootPath: "cdrom0:\\S1US_203.12;1"))
        XCTAssertNil(PS2DiscProbe.normalizedSerial(fromBootPath: ""))
    }
}

// MARK: - Synthetic disc writers

enum TestISO {
    indirect enum Node {
        case file(String, Data)
        case dir(String, [Node])
    }

    private final class Entry {
        let name: String
        let data: Data?
        var children: [Entry] = []
        weak var parent: Entry?
        var lba = 0
        var size = 0
        init(name: String, data: Data?) { self.name = name; self.data = data }
        var isDir: Bool { data == nil }
        var recordName: [UInt8] { isDir ? Array(name.utf8) : Array((name + ";1").utf8) }
    }

    private static func recordLength(nameLength: Int) -> Int { 33 + nameLength + (nameLength % 2 == 0 ? 1 : 0) }

    private static func makeTree(_ nodes: [Node], parent: Entry) {
        for node in nodes {
            switch node {
            case let .file(name, data):
                let e = Entry(name: name, data: data); e.parent = parent; e.size = data.count
                parent.children.append(e)
            case let .dir(name, kids):
                let e = Entry(name: name, data: nil); e.parent = parent
                parent.children.append(e)
                makeTree(kids, parent: e)
            }
        }
    }

    /// Packs directory records into 2048-byte sectors (records never straddle a sector).
    private static func layoutRecords(_ dir: Entry) -> [(offset: Int, entry: Entry?, name: [UInt8])] {
        var out: [(Int, Entry?, [UInt8])] = []
        var pos = 0
        let items: [(Entry?, [UInt8])] = [(dir, [0]), (dir.parent ?? dir, [1])] + dir.children.map { ($0, $0.recordName) }
        for (e, name) in items {
            let len = recordLength(nameLength: name.count)
            if pos % 2048 + len > 2048 { pos = (pos / 2048 + 1) * 2048 }
            out.append((pos, e, name))
            pos += len
        }
        return out
    }

    static func build(_ nodes: [Node]) -> Data {
        let root = Entry(name: "", data: nil)
        makeTree(nodes, parent: root)
        var dirs: [Entry] = [], files: [Entry] = []
        var queue = [root]
        while !queue.isEmpty {
            let d = queue.removeFirst()
            dirs.append(d)
            for c in d.children { if c.isDir { queue.append(c) } else { files.append(c) } }
        }
        var next = 18
        for d in dirs {
            let recs = layoutRecords(d)
            let end = recs.last!.offset + recordLength(nameLength: recs.last!.name.count)
            d.size = (end + 2047) / 2048 * 2048
            d.lba = next
            next += d.size / 2048
        }
        for f in files {
            f.lba = next
            next += max(1, (f.size + 2047) / 2048)
        }
        var image = Data(count: next * 2048)

        func putRecord(at offset: Int, entry: Entry, name: [UInt8]) {
            let len = recordLength(nameLength: name.count)
            var r = [UInt8](repeating: 0, count: len)
            r[0] = UInt8(len)
            putBoth32(&r, 2, UInt32(entry.lba))
            putBoth32(&r, 10, UInt32(entry.size))
            r[25] = entry.isDir ? 0x02 : 0x00
            r[28] = 1; r[31] = 1  // volume sequence number (both-endian 16)
            r[32] = UInt8(name.count)
            r.replaceSubrange(33..<(33 + name.count), with: name)
            image.replaceSubrange(offset..<(offset + len), with: r)
        }

        for d in dirs {
            for rec in layoutRecords(d) { putRecord(at: d.lba * 2048 + rec.offset, entry: rec.entry!, name: rec.name) }
        }
        for f in files {
            image.replaceSubrange((f.lba * 2048)..<(f.lba * 2048 + f.size), with: f.data!)
        }

        // Primary volume descriptor + terminator.
        var pvd = [UInt8](repeating: 0x20, count: 2048)
        pvd[0] = 1; pvd.replaceSubrange(1..<6, with: Array("CD001".utf8)); pvd[6] = 1; pvd[7] = 0
        for i in 72..<2048 { pvd[i] = 0 }
        putBoth32(&pvd, 80, UInt32(next))
        pvd[128] = 0x00; pvd[129] = 0x08; pvd[130] = 0x08; pvd[131] = 0x00  // logical block size 2048 (both-endian)
        var rootRec = [UInt8](repeating: 0, count: 34)
        rootRec[0] = 34; putBoth32(&rootRec, 2, UInt32(root.lba)); putBoth32(&rootRec, 10, UInt32(root.size))
        rootRec[25] = 0x02; rootRec[32] = 1
        pvd.replaceSubrange(156..<190, with: rootRec)
        pvd[881] = 1
        image.replaceSubrange((16 * 2048)..<(17 * 2048), with: pvd)
        var term = [UInt8](repeating: 0, count: 2048)
        term[0] = 255; term.replaceSubrange(1..<6, with: Array("CD001".utf8)); term[6] = 1
        image.replaceSubrange((17 * 2048)..<(18 * 2048), with: term)
        return image
    }

    private static func putBoth32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 {
            b[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF)
            b[o + 7 - i] = UInt8((v >> (8 * UInt32(i))) & 0xFF)
        }
    }

    /// Wraps 2048-byte sectors into raw 2352-byte CD sectors (sync + header [+ subheader]; EDC/ECC left zero).
    static func toRaw2352(_ iso: Data, mode: Int) -> Data {
        let count = iso.count / 2048
        var out = Data(capacity: count * 2352)
        func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | (v % 10)) }
        for lba in 0..<count {
            var s = [UInt8](repeating: 0, count: 2352)
            for i in 1...10 { s[i] = 0xFF }
            let abs = lba + 150
            s[12] = bcd(abs / 4500); s[13] = bcd(abs / 75 % 60); s[14] = bcd(abs % 75); s[15] = UInt8(mode)
            let dataOffset = mode == 2 ? 24 : 16
            if mode == 2 { s[18] = 0x08; s[22] = 0x08 }  // form 1 data subheader
            iso.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for i in 0..<2048 { s[dataOffset + i] = src[lba * 2048 + i] }
            }
            out.append(contentsOf: s)
        }
        return out
    }

    /// CSO v1: 24-byte header, (n+1) u32 index, raw-deflate blocks (high bit = stored).
    static func toCSO(_ iso: Data, blockSize: Int, align: Int = 0, plainBlocks: Set<Int> = []) -> Data {
        let blocks = (iso.count + blockSize - 1) / blockSize
        var header = Data()
        header.append(contentsOf: Array("CISO".utf8))
        header.appendLE(UInt32(0x18)); header.appendLE(UInt64(iso.count)); header.appendLE(UInt32(blockSize))
        header.append(contentsOf: [1, UInt8(align), 0, 0])
        var index = [UInt32](repeating: 0, count: blocks + 1)
        var body = Data()
        var pos = header.count + (blocks + 1) * 4
        func padToAlign() {
            let unit = 1 << align
            let pad = (unit - pos % unit) % unit
            body.append(Data(count: pad)); pos += pad
        }
        for b in 0..<blocks {
            padToAlign()
            var block = iso.subdata(in: (b * blockSize)..<min(iso.count, (b + 1) * blockSize))
            if block.count < blockSize { block.append(Data(count: blockSize - block.count)) }
            var stored = plainBlocks.contains(b)
            var payload = block
            if !stored {
                var dst = [UInt8](repeating: 0, count: blockSize * 2 + 64)
                let n = block.withUnsafeBytes { src in
                    compression_encode_buffer(&dst, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, blockSize, nil, COMPRESSION_ZLIB)
                }
                if n > 0 && n < blockSize { payload = Data(dst[0..<n]) } else { stored = true }
            }
            index[b] = UInt32(pos >> align) | (stored ? 0x8000_0000 : 0)
            body.append(payload); pos += payload.count
        }
        padToAlign()
        index[blocks] = UInt32(pos >> align)
        var out = header
        for v in index { out.appendLE(v) }
        out.append(body)
        return out
    }

    /// Minimal PARAM.SFO with UTF-8 string values.
    static func paramSFO(_ values: [String: String]) -> Data {
        let keys = values.keys.sorted()
        var keyTable = Data(), dataTable = Data(), entries = Data()
        for k in keys {
            let v = Data(values[k]!.utf8) + Data([0])
            let maxLen = (v.count + 3) / 4 * 4
            entries.appendLE(UInt16(keyTable.count)); entries.appendLE(UInt16(0x0204))
            entries.appendLE(UInt32(v.count)); entries.appendLE(UInt32(maxLen)); entries.appendLE(UInt32(dataTable.count))
            keyTable.append(Data(k.utf8) + Data([0]))
            dataTable.append(v + Data(count: maxLen - v.count))
        }
        while keyTable.count % 4 != 0 { keyTable.append(0) }
        let keyStart = 20 + entries.count
        var out = Data([0, 0x50, 0x53, 0x46])
        out.appendLE(UInt32(0x0101)); out.appendLE(UInt32(keyStart)); out.appendLE(UInt32(keyStart + keyTable.count))
        out.appendLE(UInt32(keys.count))
        out.append(entries); out.append(keyTable); out.append(dataTable)
        return out
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
