import CoreGraphics
import Foundation
import XCTest
@testable import CaseCore

final class HandheldCoverResolverTests: XCTestCase {
    var rom: URL { romDir.appendingPathComponent("Mario Kart DS.nds") }
    let tdbFull = "https://art.gametdb.com/ds/coverfullHQ/US/AMCE.jpg"

    func fullScan() -> Data { jpeg(1616, 680, (200, 30, 30)) }

    // MARK: IDs

    func testNormalizedIDs() {
        XCTAssertEqual(HandheldCoverResolver.normalizedID("AMCE", platform: .nds), "AMCE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID(" bdye ", platform: .nds), "BDYE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("NTR-P-A2DE", platform: .nds), "A2DE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("NTR-P-A2DE-USA", platform: .nds), "A2DE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("CTR-P-AMKE", platform: .threeDS), "AMKE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("KTR-P-CAFE", platform: .threeDS), "CAFE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("AMKE", platform: .threeDS), "AMKE")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("ULUS-10041", platform: .psp), "ULUS-10041")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("ulus10041", platform: .psp), "ULUS-10041")
        XCTAssertEqual(HandheldCoverResolver.normalizedID("ULUS_10041", platform: .psp), "ULUS-10041")
        for bad in [nil, "", "AMC", "AMCEE", "../AMCE", "AM/E", "XYZ-P-AMCE", "CTR-PP-AMKE", "ÄMCE"] {
            XCTAssertNil(HandheldCoverResolver.normalizedID(bad, platform: .nds), bad ?? "nil")
            XCTAssertNil(HandheldCoverResolver.normalizedID(bad, platform: .threeDS), bad ?? "nil")
        }
        for bad in ["ULUS-1004", "ULU-10041", "ULUS-1004A", "../../etc", "ULUS-100411"] {
            XCTAssertNil(HandheldCoverResolver.normalizedID(bad, platform: .psp), bad)
        }
    }

    // MARK: URL building

    func testGameTDBRegionFallback() {
        XCTAssertEqual(HandheldCoverResolver.gameTDBRegions(for: "AMCE"), ["US", "EN"])
        XCTAssertEqual(HandheldCoverResolver.gameTDBRegions(for: "AMCP"), ["US", "EN"])
        XCTAssertEqual(HandheldCoverResolver.gameTDBRegions(for: "AMKJ"), ["US", "EN", "JA"])
        XCTAssertEqual(HandheldCoverResolver.gameTDBRegions(for: "A2DD"), ["US", "EN", "DE"])
        XCTAssertEqual(HandheldCoverResolver.gameTDBRegions(for: "A2DK"), ["US", "EN", "KO"])
    }

    func testGameTDBURLs() {
        let r = makeResolver(FakeIO())
        XCTAssertEqual(r.remoteURLs(id: "AMCE", platform: .nds, side: .full).map(\.absoluteString), [
            "https://art.gametdb.com/ds/coverfullHQ/US/AMCE.jpg",
            "https://art.gametdb.com/ds/coverfullHQ/EN/AMCE.jpg",
            "https://art.gametdb.com/ds/coverfullM/US/AMCE.jpg",
            "https://art.gametdb.com/ds/coverfullM/EN/AMCE.jpg",
        ])
        XCTAssertEqual(r.remoteURLs(id: "AMKJ", platform: .threeDS, side: .front).map(\.absoluteString), [
            "https://art.gametdb.com/3ds/coverHQ/US/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverHQ/EN/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverHQ/JA/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverM/US/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverM/EN/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverM/JA/AMKJ.jpg",
        ])
        XCTAssertTrue(r.remoteURLs(id: "AMCE", platform: .nds, side: .back).isEmpty)
    }

    func testPSPNameEscapingAndURL() {
        XCTAssertEqual(HandheldCoverResolver.libretroThumbnailName("Harvest Moon - Boy & Girl (USA)"), "Harvest Moon - Boy _ Girl (USA)")
        XCTAssertEqual(HandheldCoverResolver.libretroThumbnailName(#"A*B/C:D`E<F>G?H\I|J"K"#), "A_B_C_D_E_F_G_H_I_J_K")
        XCTAssertEqual(HandheldCoverResolver.libretroThumbnailName("Already _ Escaped"), "Already _ Escaped")

        let names = ["ULUS-10041": "Grand Theft Auto - Liberty City Stories (USA) (En,Fr,De,Es,It) (v1.05)",
                     "ULUS-10062": "ATV Offroad Fury - Blazin' Trails (USA) & More"]
        let r = makeResolver(FakeIO(), pspNames: names)
        XCTAssertEqual(r.remoteURLs(id: "ULUS-10041", platform: .psp, side: .front).map(\.absoluteString), [
            "https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/"
                + "Grand%20Theft%20Auto%20-%20Liberty%20City%20Stories%20%28USA%29%20%28En%2CFr%2CDe%2CEs%2CIt%29%20%28v1.05%29.png",
        ])
        XCTAssertEqual(r.remoteURLs(id: "ULUS-10062", platform: .psp, side: .front).first?.absoluteString,
                       "https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/"
                           + "ATV%20Offroad%20Fury%20-%20Blazin%27%20Trails%20%28USA%29%20_%20More.png")
        XCTAssertTrue(r.remoteURLs(id: "ULUS-10041", platform: .psp, side: .back).isEmpty)
        XCTAssertTrue(r.remoteURLs(id: "ULUS-10041", platform: .psp, side: .full).isEmpty)
        XCTAssertTrue(r.remoteURLs(id: "ULUS-99999", platform: .psp, side: .front).isEmpty)
    }

    func testBundledPSPNamesContainGTA() throws {
        let url = projectRoot().appendingPathComponent("DuoDS/Resources/PSP-Boxart-Names.json")
        let names = HandheldCoverResolver.loadPSPNames(from: url)
        XCTAssertGreaterThan(names.count, 1000)
        XCTAssertEqual(names["ULUS-10041"], "Grand Theft Auto - Liberty City Stories (USA) (En,Fr,De,Es,It) (v1.05)")
        XCTAssertTrue(names.keys.allSatisfy { HandheldCoverResolver.normalizedID($0, platform: .psp) == $0 })
        XCTAssertTrue(HandheldCoverResolver.loadPSPNames(from: nil).isEmpty)
    }

    // MARK: Local files

    func testLocalCandidateOrder() {
        let r = makeResolver(FakeIO())
        let front = r.localCandidates(for: rom, directoryHasSingleGame: true, side: .front).map(\.lastPathComponent)
        XCTAssertEqual(front.first, "Mario Kart DS.jpg")
        XCTAssertTrue(front.contains("Mario Kart DS.PNG"))
        XCTAssertLessThan(front.firstIndex(of: "Mario Kart DS.heic")!, front.firstIndex(of: "Mario Kart DS.cover.jpg")!)
        XCTAssertLessThan(front.firstIndex(of: "Mario Kart DS.cover.jpg")!, front.firstIndex(of: "cover.jpg")!)
        XCTAssertTrue(front.contains("folder.png"))

        let back = r.localCandidates(for: rom, directoryHasSingleGame: true, side: .back).map(\.lastPathComponent)
        let full = r.localCandidates(for: rom, directoryHasSingleGame: true, side: .full).map(\.lastPathComponent)
        XCTAssertEqual(back.first, "Mario Kart DS.back.jpg")
        XCTAssertEqual(full.first, "Mario Kart DS.full.jpg")
        XCTAssertTrue(back.contains("back.png"))
        XCTAssertTrue(full.contains("full.webp"))
        XCTAssertTrue(Set(front).isDisjoint(with: back))
        XCTAssertTrue(Set(front).isDisjoint(with: full))
        XCTAssertTrue(Set(back).isDisjoint(with: full))

        for side in HandheldCoverSide.allCases {
            let multi = r.localCandidates(for: rom, directoryHasSingleGame: false, side: side).map(\.lastPathComponent)
            XCTAssertTrue(multi.allSatisfy { $0.hasPrefix("Mario Kart DS.") }, "\(side)")
        }
    }

    func testLocalWinsOverCacheAndDownload() async {
        let io = FakeIO()
        let local = png(100, 90, (255, 0, 0))
        io.files["/Games/DS/Mario Kart DS.png"] = local
        io.files["/Cache/Handheld/nds/AMCE.front.jpg"] = jpeg(100, 90, (0, 255, 0))
        io.defaultResult = .success(jpeg(768, 680))
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .front)
        XCTAssertEqual(data, local)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testFolderFilesOnlyForSingleGameDirectory() async {
        let io = FakeIO()
        let folderFull = png(300, 120, (1, 2, 3))
        io.files["/Games/DS/full.png"] = folderFull
        io.files["/Games/DS/cover.jpg"] = jpeg(100, 90)
        let r = makeResolver(io, online: false)
        let shared = await r.resolve(romURL: rom, productID: nil, platform: .nds, directoryHasSingleGame: false, side: .full)
        XCTAssertNil(shared)
        let sharedFront = await r.resolve(romURL: rom, productID: nil, platform: .nds, directoryHasSingleGame: false, side: .front)
        XCTAssertNil(sharedFront)
        let single = await r.resolve(romURL: rom, productID: nil, platform: .nds, directoryHasSingleGame: true, side: .full)
        XCTAssertEqual(single, folderFull)
        let singleFront = await r.resolve(romURL: rom, productID: nil, platform: .nds, directoryHasSingleGame: true, side: .front)
        XCTAssertNotNil(singleFront)
    }

    func testLocalFullMustBeWide() async {
        let io = FakeIO()
        io.files["/Games/DS/Mario Kart DS.full.png"] = png(100, 100)  // square: not a wrap scan
        let data = await makeResolver(io, online: false).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                                 directoryHasSingleGame: false, side: .full)
        XCTAssertNil(data)
    }

    func testCorruptLocalAndCacheFallThrough() async {
        let io = FakeIO()
        io.files["/Games/DS/Mario Kart DS.full.jpg"] = Data("not an image".utf8)
        io.files["/Cache/Handheld/nds/AMCE.full.jpg"] = Data("truncated".utf8)
        let remote = fullScan()
        io.responses[tdbFull] = .success(remote)
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertEqual(data, remote)
    }

    // MARK: Cache

    func testCacheWinsOverDownload() async {
        let io = FakeIO()
        let cached = jpeg(1616, 680, (0, 200, 0))
        io.files["/Cache/Handheld/3ds/AMKE.full.jpg"] = cached
        io.defaultResult = .success(fullScan())
        let data = await makeResolver(io).resolve(romURL: rom, productID: "CTR-P-AMKE", platform: .threeDS,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertEqual(data, cached)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testCachedPNGIsFound() async {
        let io = FakeIO()
        let cached = png(512, 884, (0, 0, 200))
        io.files["/Cache/Handheld/psp/ULUS-10041.front.png"] = cached
        let data = await makeResolver(io, online: false).resolve(romURL: rom, productID: "ULUS10041", platform: .psp,
                                                                 directoryHasSingleGame: false, side: .front)
        XCTAssertEqual(data, cached)
    }

    // MARK: Downloads

    func testDownloadsFullAndCaches() async {
        let io = FakeIO()
        let remote = fullScan()
        io.responses[tdbFull] = .success(remote)
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertEqual(data, remote)
        XCTAssertEqual(io.downloads.map(\.absoluteString), [tdbFull])
        XCTAssertEqual(io.writes["/Cache/Handheld/nds/AMCE.full.jpg"], remote)
    }

    func testRegionAndSizeFallback() async {
        let io = FakeIO()
        let medium = jpeg(856, 352)
        io.responses["https://art.gametdb.com/3ds/coverfullM/JA/AMKJ.jpg"] = .success(medium)
        let data = await makeResolver(io).resolve(romURL: rom, productID: "CTR-P-AMKJ", platform: .threeDS,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertEqual(data, medium)
        XCTAssertEqual(io.downloads.map(\.absoluteString), [
            "https://art.gametdb.com/3ds/coverfullHQ/US/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverfullHQ/EN/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverfullHQ/JA/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverfullM/US/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverfullM/EN/AMKJ.jpg",
            "https://art.gametdb.com/3ds/coverfullM/JA/AMKJ.jpg",
        ])
        XCTAssertEqual(io.writes["/Cache/Handheld/3ds/AMKJ.full.jpg"], medium)
    }

    func testAll404ReturnsNilAndCachesNothing() async {
        let io = FakeIO()
        let data = await makeResolver(io).resolve(romURL: rom, productID: "ZZZE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .front)
        XCTAssertNil(data)
        XCTAssertEqual(io.downloads.count, 4)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testBadDownloadsAreSkippedNotCached() async {
        let io = FakeIO()
        io.responses["https://art.gametdb.com/ds/coverHQ/US/AMCE.jpg"] = .success(Data("<html>404</html>".utf8))
        io.responses["https://art.gametdb.com/ds/coverHQ/EN/AMCE.jpg"] = .success(png(32, 32))  // too small
        let good = jpeg(400, 352)
        io.responses["https://art.gametdb.com/ds/coverM/US/AMCE.jpg"] = .success(good)
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .front)
        XCTAssertEqual(data, good)
        XCTAssertEqual(io.writes.count, 1)
        XCTAssertEqual(io.writes["/Cache/Handheld/nds/AMCE.front.jpg"], good)
    }

    func testFullDownloadMustBeWide() async {
        let io = FakeIO()
        io.defaultResult = .success(jpeg(768, 680))  // a front, not a wrap
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertNil(data)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testOversizedDownloadRejected() {
        var big = png(100, 100)
        big.append(Data(count: HandheldCoverResolver.maximumDownloadBytes))
        XCTAssertFalse(HandheldCoverResolver.isUsableDownload(big, platform: .nds, side: .front))
    }

    func testNetworkErrorStopsFallbacks() async {
        let io = FakeIO()
        io.defaultResult = .failure(OfflineError())
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .full)
        XCTAssertNil(data)
        XCTAssertEqual(io.downloads.count, 1)
    }

    func testOfflineNilIDAndUnsafeIDNeverDownload() async {
        for (online, id) in [(false, "AMCE"), (true, nil), (true, "../../etc/passwd")] as [(Bool, String?)] {
            let io = FakeIO()
            io.defaultResult = .success(fullScan())
            let data = await makeResolver(io, online: online).resolve(romURL: rom, productID: id, platform: .nds,
                                                                      directoryHasSingleGame: false, side: .full)
            XCTAssertNil(data)
            XCTAssertTrue(io.downloads.isEmpty)
            XCTAssertTrue(io.writes.isEmpty)
        }
    }

    func testPSPFrontDownloadsViaNameMapAndCachesPNG() async {
        let io = FakeIO()
        let remote = png(512, 884, (10, 20, 30))
        io.defaultResult = .success(remote)
        let r = makeResolver(io, pspNames: ["ULUS-10041": "Grand Theft Auto - Liberty City Stories (USA) (En,Fr,De,Es,It) (v1.05)"])
        let data = await r.resolve(romURL: rom, productID: "ULUS-10041", platform: .psp, directoryHasSingleGame: false, side: .front)
        XCTAssertEqual(data, remote)
        XCTAssertEqual(io.downloads.count, 1)
        XCTAssertEqual(io.writes["/Cache/Handheld/psp/ULUS-10041.front.png"], remote)

        // No online back or full for PSP, and unknown serials make no request.
        for side in [HandheldCoverSide.back, .full] {
            let none = await r.resolve(romURL: rom, productID: "ULUS-10041", platform: .psp, directoryHasSingleGame: false, side: side)
            XCTAssertNil(none, "\(side)")
        }
        let unknown = await r.resolve(romURL: rom, productID: "ULUS-99999", platform: .psp, directoryHasSingleGame: false, side: .front)
        XCTAssertNil(unknown)
        XCTAssertEqual(io.downloads.count, 1)
    }

    // MARK: Back

    func testBackIsCroppedFromFullScan() async throws {
        let io = FakeIO()
        // DS scan: red back 0–764, green spine 764–857, blue front.
        io.responses[tdbFull] = .success(png(1616, 680, (0, 0, 255), bands: [(0, 764, (255, 0, 0)), (764, 857, (0, 255, 0))]))
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .back)
        let back = try XCTUnwrap(data.flatMap(HandheldCaseInsert.decodeImage))
        XCTAssertEqual(back.height, 680)
        XCTAssertEqual(back.width, 764, accuracy: 2)
        let px = Pixels(back)
        assertPixel(px.at(5, 340), (255, 0, 0), "left edge")
        assertPixel(px.at(back.width - 3, 340), (255, 0, 0), "right edge")
        // The full scan was cached; the derived back was not.
        XCTAssertNotNil(io.writes["/Cache/Handheld/nds/AMCE.full.png"])
        XCTAssertEqual(io.writes.count, 1)
    }

    func testLocalBackWins() async {
        let io = FakeIO()
        let local = png(100, 90, (9, 9, 9))
        io.files["/Games/DS/Mario Kart DS.back.png"] = local
        io.defaultResult = .success(fullScan())
        let data = await makeResolver(io).resolve(romURL: rom, productID: "AMCE", platform: .nds,
                                                  directoryHasSingleGame: false, side: .back)
        XCTAssertEqual(data, local)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    // MARK: resolveInsert precedence

    func testResolveInsertPrefersLocalFrontOverOnlineFull() async {
        let io = FakeIO()
        let front = png(100, 90, (1, 1, 1))
        io.files["/Games/DS/Mario Kart DS.cover.png"] = front
        io.defaultResult = .success(fullScan())
        let set = await makeResolver(io).resolveInsert(romURL: rom, productID: "AMCE", platform: .nds, directoryHasSingleGame: false)
        XCTAssertEqual(set, HandheldCoverArtSet(full: nil, front: front, back: nil))
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testResolveInsertLocalFullFirst() async {
        let io = FakeIO()
        let full = png(1616, 680)
        io.files["/Games/DS/Mario Kart DS.full.png"] = full
        io.files["/Games/DS/Mario Kart DS.png"] = png(100, 90)
        let set = await makeResolver(io).resolveInsert(romURL: rom, productID: "AMCE", platform: .nds, directoryHasSingleGame: false)
        XCTAssertEqual(set, HandheldCoverArtSet(full: full))
    }

    func testResolveInsertDownloadsFullThenFront() async {
        let io = FakeIO()
        let remote = fullScan()
        io.responses[tdbFull] = .success(remote)
        let set = await makeResolver(io).resolveInsert(romURL: rom, productID: "AMCE", platform: .nds, directoryHasSingleGame: false)
        XCTAssertEqual(set, HandheldCoverArtSet(full: remote))

        let io2 = FakeIO()
        let front = jpeg(768, 680)
        io2.responses["https://art.gametdb.com/ds/coverHQ/US/AMCE.jpg"] = .success(front)
        let set2 = await makeResolver(io2).resolveInsert(romURL: rom, productID: "AMCE", platform: .nds, directoryHasSingleGame: false)
        XCTAssertEqual(set2, HandheldCoverArtSet(front: front))
        XCTAssertEqual(io2.downloads.count, 5)  // 4 full candidates, then the first front
    }

    func testResolveInsertLocalBackSkipsOnlineFull() async {
        let io = FakeIO()
        let back = png(100, 90, (5, 5, 5))
        io.files["/Games/DS/Mario Kart DS.back.png"] = back
        io.defaultResult = .success(jpeg(768, 680))
        let set = await makeResolver(io).resolveInsert(romURL: rom, productID: "AMCE", platform: .nds, directoryHasSingleGame: false)
        XCTAssertEqual(set.back, back)
        XCTAssertNotNil(set.front)
        XCTAssertNil(set.full)
        XCTAssertTrue(io.downloads.allSatisfy { $0.absoluteString.contains("/coverHQ/") })
    }

    func testResolveInsertHomebrewIsEmpty() async {
        let io = FakeIO()
        let set = await makeResolver(io).resolveInsert(romURL: rom, productID: nil, platform: .nds, directoryHasSingleGame: false)
        XCTAssertTrue(set.isEmpty)
        XCTAssertTrue(io.downloads.isEmpty)
    }
}
