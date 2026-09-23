import XCTest
@testable import PS2Core

final class PS2MemoryCardTests: XCTestCase {
    private var base: URL!
    private var card: PS2MemoryCard!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PS2MemoryCardTests-\(UUID().uuidString)", isDirectory: true)
        card = PS2MemoryCard(root: base.appendingPathComponent("SLUS-20312", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = base.appendingPathComponent("in-\(name)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try PS2SaveArchiveTests.fixture(name).write(to: url)
        return url
    }

    private func rootContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: card.root.path).sorted()
    }

    func testMissingRootIsEmptyCard() throws {
        XCTAssertEqual(try card.saves(), [])
    }

    func testImportPSUListsEntry() throws {
        let entry = try card.importArchive(at: fixtureURL("mymc-BASLUS-20312GAME.psu"))
        XCTAssertEqual(entry.name, "BASLUS-20312GAME")
        XCTAssertEqual(entry.fallbackTitle, "BASLUS-20312GAME")
        XCTAssertEqual(entry.files.map(\.name), ["BASLUS-20312GAME", "empty.bin", "icon.sys", "view.ico"])
        XCTAssertEqual(entry.totalSize, 964 + 604 + 7624)
        XCTAssertTrue(entry.hasIconSys)
        XCTAssertEqual(entry.iconSysURL.lastPathComponent, "icon.sys")
        XCTAssertEqual(entry.iconSysData()?.count, 964)
        // Stored PS2 timestamp survives import.
        XCTAssertEqual(entry.modificationDate, PS2SaveArchiveTests.fixtureDate)
        XCTAssertEqual(try card.saves(), [entry])
        XCTAssertEqual(try rootContents(), ["BASLUS-20312GAME"])  // no temp dirs left behind
    }

    func testImportMAX() throws {
        let entry = try card.importArchive(at: fixtureURL("mymc-BASLUS-20312GAME.max"))
        XCTAssertEqual(entry.name, "BASLUS-20312GAME")
        XCTAssertEqual(entry.totalSize, 964 + 604 + 7624)
        XCTAssertNotNil(entry.modificationDate)
    }

    func testCollisionNeedsOverwrite() throws {
        let url = try fixtureURL("mymc-BASLUS-20312GAME.psu")
        try card.importArchive(at: url)
        XCTAssertThrowsError(try card.importArchive(at: url)) {
            XCTAssertEqual($0 as? PS2SaveError, .alreadyExists("BASLUS-20312GAME"))
        }
        let replacement = PS2SaveArchive(directoryName: "BASLUS-20312GAME",
                                         files: [.init(name: "only", data: Data([1, 2]))])
        let entry = try card.importSave(replacement, overwrite: true)
        XCTAssertEqual(entry.files.map(\.name), ["only"])  // old files are gone, not merged
        XCTAssertEqual(entry.totalSize, 2)
        XCTAssertEqual(try rootContents(), ["BASLUS-20312GAME"])
    }

    func testExportImportRoundTrip() throws {
        let original = try card.importArchive(at: fixtureURL("mymc-BASLUS-20312GAME.psu"))
        let exportDir = base.appendingPathComponent("export", isDirectory: true)
        let psu = try card.exportPSU(original, to: exportDir)
        XCTAssertEqual(psu.lastPathComponent, "BASLUS-20312GAME.psu")

        let other = PS2MemoryCard(root: base.appendingPathComponent("Other", isDirectory: true))
        let copy = try other.importArchive(at: psu)
        XCTAssertEqual(copy.name, original.name)
        XCTAssertEqual(copy.files.map(\.name), original.files.map(\.name))
        for (a, b) in zip(original.files, copy.files) {
            XCTAssertEqual(try Data(contentsOf: a.url), try Data(contentsOf: b.url), a.name)
            XCTAssertEqual(a.modified, b.modified, a.name)
        }
        XCTAssertEqual(copy.modificationDate, original.modificationDate)
        // Stable: exporting the copy gives the same bytes.
        let again = try other.exportPSU(copy, to: base.appendingPathComponent("export2", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: again), try Data(contentsOf: psu))
    }

    func testDelete() throws {
        let entry = try card.importArchive(at: fixtureURL("mymc-BASLUS-20312GAME.psu"))
        try card.delete(entry)
        XCTAssertEqual(try card.saves(), [])
        XCTAssertThrowsError(try card.delete(entry)) {
            XCTAssertEqual($0 as? PS2SaveError, .notFound("BASLUS-20312GAME"))
        }
    }

    func testImportRejectsUnsafeNamesWithoutTouchingDisk() throws {
        for bad in ["..", "../escape", "/abs", "a/b", ".hidden", "", String(repeating: "x", count: 33)] {
            let asDir = PS2SaveArchive(directoryName: bad, files: [.init(name: "f", data: Data([1]))])
            XCTAssertThrowsError(try card.importSave(asDir), bad) {
                XCTAssertEqual($0 as? PS2SaveError, .invalidName(bad))
            }
            let asFile = PS2SaveArchive(directoryName: "OK", files: [.init(name: bad, data: Data([1]))])
            XCTAssertThrowsError(try card.importSave(asFile), bad) {
                XCTAssertEqual($0 as? PS2SaveError, .invalidName(bad))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: card.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("escape").path))
    }

    func testListingSkipsHiddenAndLooseFiles() throws {
        try card.importSave(PS2SaveArchive(directoryName: "B", files: [.init(name: "x", data: Data([1]))]))
        try card.importSave(PS2SaveArchive(directoryName: "A", files: [.init(name: "y", data: Data([1, 2]))]))
        let fm = FileManager.default
        try fm.createDirectory(at: card.root.appendingPathComponent(".import-stale"), withIntermediateDirectories: true)
        try Data().write(to: card.root.appendingPathComponent("loose.txt"))
        try Data([0]).write(to: card.root.appendingPathComponent("A/.DS_Store"))
        let saves = try card.saves()
        XCTAssertEqual(saves.map(\.name), ["A", "B"])
        XCTAssertEqual(saves[0].totalSize, 2)
        XCTAssertFalse(saves[0].hasIconSys)
        XCTAssertNil(saves[0].iconSysData())
    }

    func testCardFolderName() {
        XCTAssertEqual(PS2MemoryCard.folderName(serial: "SLUS-20312", title: "Ignored"), "SLUS-20312")
        XCTAssertEqual(PS2MemoryCard.folderName(serial: nil, title: "../Final: Fantasy/X?"), "_Final_ Fantasy_X_")
        XCTAssertEqual(PS2MemoryCard.folderName(serial: "  ", title: "..."), "Untitled")
        XCTAssertEqual(PS2MemoryCard.root(in: URL(fileURLWithPath: "/tmp/MC"), serial: "SLUS-1", title: "").path,
                       "/tmp/MC/SLUS-1")
    }
}
