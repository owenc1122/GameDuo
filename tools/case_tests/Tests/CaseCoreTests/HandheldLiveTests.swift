import CoreGraphics
import Foundation
import XCTest
@testable import CaseCore

/// Opt-in: `HANDHELD_NETWORK_TESTS=1 swift test`. Hits GameTDB and libretro-thumbnails, then writes sample
/// insert sheets to Handheld_Cases/cover_samples/ for a visual check.
final class HandheldLiveTests: XCTestCase {
    var cache: URL!
    var resolver: HandheldCoverResolver!
    let rom = URL(fileURLWithPath: "/nonexistent/roms/game.bin")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HANDHELD_NETWORK_TESTS"] == "1", "set HANDHELD_NETWORK_TESTS=1")
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("handheld-covers-\(UUID().uuidString)")
        let names = HandheldCoverResolver.loadPSPNames(from: projectRoot().appendingPathComponent("DuoDS/Resources/PSP-Boxart-Names.json"))
        resolver = HandheldCoverResolver.live(cacheDirectory: cache, onlineEnabled: true, pspNames: names)
    }

    override func tearDown() {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    func image(_ id: String, _ platform: HandheldCasePlatform, _ side: HandheldCoverSide) async throws -> CGImage {
        let data = await resolver.resolve(romURL: rom, productID: id, platform: platform, directoryHasSingleGame: false, side: side)
        return try XCTUnwrap(data.flatMap(HandheldCaseInsert.decodeImage), "\(id) \(side)")
    }

    func testGameTDBFullScans() async throws {
        for (id, platform, folder) in [("AMCE", HandheldCasePlatform.nds, "nds"), ("BDYE", .nds, "nds"), ("CTR-P-AMKE", .threeDS, "3ds")] {
            let full = try await image(id, platform, .full)
            XCTAssertEqual(full.width, 1616, id)
            XCTAssertEqual(full.height, 680, id)
            let code = HandheldCoverResolver.normalizedID(id, platform: platform)!
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("\(folder)/\(code).full.jpg").path))
            let (a, b) = HandheldCaseInsert.scanSplits(for: full, platform: platform)
            let nominal = HandheldCaseInsert.nominalScanSplits(for: platform)
            XCTAssertEqual(a, nominal.0 * 1616, accuracy: 10, "\(id) split 0")
            XCTAssertEqual(b, nominal.1 * 1616, accuracy: 10, "\(id) split 1")

            let front = try await image(id, platform, .front)
            XCTAssertGreaterThanOrEqual(front.width, 400)
            let back = try await image(id, platform, .back)
            XCTAssertEqual(CGFloat(back.width), a.rounded(.down), accuracy: 1)
        }
        let missing = await resolver.resolve(romURL: rom, productID: "ZZZE", platform: .nds, directoryHasSingleGame: false, side: .full)
        XCTAssertNil(missing)
    }

    func testPSPLibretroFront() async throws {
        let front = try await image("ULUS-10041", .psp, .front)
        XCTAssertEqual(front.width, 512)
        XCTAssertEqual(front.height, 884)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("psp/ULUS-10041.front.png").path))
        for side in [HandheldCoverSide.back, .full] {
            let none = await resolver.resolve(romURL: rom, productID: "ULUS-10041", platform: .psp, directoryHasSingleGame: false, side: side)
            XCTAssertNil(none)
        }
    }

    func testWriteSampleRenders() async throws {
        let out = projectRoot().appendingPathComponent("Handheld_Cases/cover_samples", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ppm: CGFloat = 6

        func write(_ name: String, _ platform: HandheldCasePlatform, _ set: HandheldCoverArtSet, title: String, subtitle: String? = nil) throws {
            let img = try XCTUnwrap(HandheldCaseInsert.render(
                platform: platform, layout: .standard(for: platform),
                full: set.full.flatMap(HandheldCaseInsert.decodeImage), front: set.front.flatMap(HandheldCaseInsert.decodeImage),
                back: set.back.flatMap(HandheldCaseInsert.decodeImage), title: title, subtitle: subtitle, pixelsPerMM: ppm), name)
            try XCTUnwrap(HandheldCaseInsert.encodePNG(img)).write(to: out.appendingPathComponent("\(name).png"))
        }

        for (name, id, platform, title) in [("nds_AMCE_full", "AMCE", HandheldCasePlatform.nds, "Mario Kart DS"),
                                            ("nds_BDYE_full", "BDYE", .nds, "Call of Duty: Black Ops"),
                                            ("3ds_AMKE_full", "CTR-P-AMKE", .threeDS, "Mario Kart 7"),
                                            ("psp_ULUS-10041_front", "ULUS-10041", .psp, "Grand Theft Auto: Liberty City Stories")] {
            let set = await resolver.resolveInsert(romURL: rom, productID: id, platform: platform, directoryHasSingleGame: false)
            XCTAssertFalse(set.isEmpty, id)
            try write(name, platform, set, title: title)
        }
        // Front-only renders of the Nintendo games (generated spine and back).
        for (name, id, platform, title) in [("nds_AMCE_front_only", "AMCE", HandheldCasePlatform.nds, "Mario Kart DS"),
                                            ("3ds_AMKE_front_only", "CTR-P-AMKE", .threeDS, "Mario Kart 7")] {
            let front = await resolver.resolve(romURL: rom, productID: id, platform: platform, directoryHasSingleGame: false, side: .front)
            try write(name, platform, HandheldCoverArtSet(front: try XCTUnwrap(front)), title: title)
        }
        try write("nds_placeholder", .nds, HandheldCoverArtSet(), title: "Homebrew Kart Deluxe", subtitle: "nds-homebrew v1.2")
        try write("3ds_placeholder", .threeDS, HandheldCoverArtSet(), title: "Pocket Picross 3D", subtitle: "3dsx")
        try write("psp_placeholder", .psp, HandheldCoverArtSet(), title: "Lumines Remix Homebrew", subtitle: "EBOOT.PBP")
    }
}
