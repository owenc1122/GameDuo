import XCTest
@testable import PS2Core

final class PS2WebCoreLogicTests: XCTestCase {
    func testPadButtonsMapToPlayIndices() {
        var pad = PS2PadState()
        pad.setButton(libretroID: 0, pressed: true)   // × → CROSS (13)
        pad.setButton(libretroID: 9, pressed: true)   // △ → TRIANGLE (11)
        pad.setButton(libretroID: 13, pressed: true)  // R2 (18)
        XCTAssertEqual(pad.buttons, (1 << 13) | (1 << 11) | (1 << 18))
        pad.setButton(libretroID: 9, pressed: false)
        XCTAssertEqual(pad.buttons, (1 << 13) | (1 << 18))
        pad.setButton(libretroID: 99, pressed: true)
        XCTAssertEqual(pad.buttons, (1 << 13) | (1 << 18))
    }

    func testAxisMapping() {
        XCTAssertEqual(PS2PadState.axis(0), 127)
        XCTAssertEqual(PS2PadState.axis(-1), 0)
        XCTAssertEqual(PS2PadState.axis(1), 255)
        XCTAssertEqual(PS2PadState.axis(-5), 0)
        XCTAssertEqual(PS2PadState.axis(.nan), 127)
        var pad = PS2PadState()
        pad.setStick(.right, x: 1, y: -1)
        XCTAssertEqual(pad.javaScriptArguments, "0,127,127,255,0")
    }

    func testCardPathRejectsEscapes() {
        let root = URL(fileURLWithPath: "/tmp/card")
        XCTAssertEqual(PS2CardPath.resolve("BASLUS-20312GAME/icon.sys", in: root)?.path, "/tmp/card/BASLUS-20312GAME/icon.sys")
        XCTAssertEqual(PS2CardPath.resolve("BASLUS-20312GAME", in: root)?.path, "/tmp/card/BASLUS-20312GAME")
        for bad in ["", "/etc/passwd", "../x", "A/../../x", "A/./b", ".hidden/x", "A/.x", "A\\b", "A/b/c", "A//b"] {
            XCTAssertNil(PS2CardPath.resolve(bad, in: root), bad)
        }
    }

    func testCardManifestSkipsHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("SAVE1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("SAVE1/icon.sys"))
        try Data([2]).write(to: root.appendingPathComponent("SAVE1/.DS_Store"))
        try Data([3]).write(to: root.appendingPathComponent(".tmp/x"))
        XCTAssertEqual(PS2CardPath.manifest(of: root), ["SAVE1/icon.sys"])
    }

    func testByteRange() {
        XCTAssertEqual(PS2ByteRange.parse("bytes=0-1023", size: 4096), PS2ByteRange(offset: 0, length: 1024))
        XCTAssertEqual(PS2ByteRange.parse("bytes=4000-9999", size: 4096), PS2ByteRange(offset: 4000, length: 96))
        XCTAssertEqual(PS2ByteRange.parse("bytes=100-", size: 4096), PS2ByteRange(offset: 100, length: 3996))
        XCTAssertEqual(PS2ByteRange.parse("bytes=-100", size: 4096), PS2ByteRange(offset: 3996, length: 100))
        XCTAssertNil(PS2ByteRange.parse("bytes=5000-6000", size: 4096))
        XCTAssertNil(PS2ByteRange.parse("bytes=10-5", size: 4096))
        XCTAssertNil(PS2ByteRange.parse("bytes=0-1,5-6", size: 4096))
        XCTAssertNil(PS2ByteRange.parse("items=0-1", size: 4096))
        XCTAssertNil(PS2ByteRange.parse(nil, size: 4096))
        XCTAssertEqual(PS2ByteRange(offset: 0, length: 10).contentRange(size: 20), "bytes 0-9/20")
    }
}
