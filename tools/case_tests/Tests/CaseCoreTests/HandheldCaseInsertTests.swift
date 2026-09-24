import CoreGraphics
import Foundation
import XCTest
@testable import CaseCore

final class HandheldCaseInsertTests: XCTestCase {
    let ppm: CGFloat = 4

    // MARK: Layout

    func testUSplits() {
        let l = HandheldCaseInsertLayout(back: 100, spine: 20, front: 80, height: 50)
        XCTAssertEqual(l.uSplits.0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(l.uSplits.1, 0.6, accuracy: 1e-9)
        for layout in [HandheldCaseInsertLayout.nds, .threeDS, .psp] {
            let (a, b) = layout.uSplits
            XCTAssertTrue(0 < a && a < b && b < 1)
        }
        XCTAssertEqual(HandheldCaseInsertLayout.standard(for: .psp), .psp)
    }

    func testLayoutFromContract() {
        let json = #"{"insert_mm": {"back": 130, "spine": 15.5, "front": 129, "height": 116}, "u_splits": [0.5, 0.56]}"#
        XCTAssertEqual(HandheldCaseInsertLayout.fromContract(Data(json.utf8)),
                       HandheldCaseInsertLayout(back: 130, spine: 15.5, front: 129, height: 116))
        XCTAssertNil(HandheldCaseInsertLayout.fromContract(Data(#"{"insert_mm": {"back": 1}}"#.utf8)))
        XCTAssertNil(HandheldCaseInsertLayout.fromContract(Data("nope".utf8)))
    }

    /// If the case models have published their contract.json, the built-in layouts must match it.
    func testLayoutsMatchPublishedContracts() throws {
        let root = projectRoot().appendingPathComponent("Handheld_Cases")
        for (folder, layout) in [("NDS", HandheldCaseInsertLayout.nds), ("3DS", .threeDS), ("UMD", .psp)] {
            let url = root.appendingPathComponent("\(folder)/contract.json")
            guard let data = try? Data(contentsOf: url), let published = HandheldCaseInsertLayout.fromContract(data) else { continue }
            XCTAssertEqual(published, layout, folder)
        }
    }

    // MARK: Full scan mapping

    func render(_ platform: HandheldCasePlatform, layout: HandheldCaseInsertLayout? = nil, full: CGImage? = nil,
                front: CGImage? = nil, back: CGImage? = nil, title: String = "Test Game") -> CGImage {
        HandheldCaseInsert.render(platform: platform, layout: layout ?? .standard(for: platform), full: full, front: front,
                                  back: back, title: title, subtitle: "Subtitle", pixelsPerMM: ppm)!
    }

    func testSheetSize() {
        let img = render(.nds)
        XCTAssertEqual(img.width, Int((HandheldCaseInsertLayout.nds.totalWidth * ppm).rounded()))
        XCTAssertEqual(img.height, Int((HandheldCaseInsertLayout.nds.height * ppm).rounded()))
        XCTAssertNil(HandheldCaseInsert.render(platform: .nds, layout: .nds, full: nil, front: nil, back: nil,
                                               title: "x", subtitle: nil, pixelsPerMM: 0))
    }

    func assertPanels(_ img: CGImage, layout: HandheldCaseInsertLayout, file: StaticString = #filePath, line: UInt = #line) {
        let px = Pixels(img)
        let x0 = Int(layout.back * ppm), x1 = Int((layout.back + layout.spine) * ppm), y = img.height / 2
        let inset = Int(ppm) + 1  // 1 mm (+ filtering) from each boundary
        assertPixel(px.at(inset, y), (255, 0, 0), "back left", file: file, line: line)
        assertPixel(px.at(x0 - inset, y), (255, 0, 0), "back right", file: file, line: line)
        assertPixel(px.at(x0 + inset, y), (0, 255, 0), "spine left", file: file, line: line)
        assertPixel(px.at(x1 - inset, y), (0, 255, 0), "spine right", file: file, line: line)
        assertPixel(px.at(x1 + inset, y), (0, 0, 255), "front left", file: file, line: line)
        assertPixel(px.at(img.width - inset, y), (0, 0, 255), "front right", file: file, line: line)
        assertPixel(px.at(x1 + inset, 1), (0, 0, 255), "front top", file: file, line: line)
    }

    func testDSFullScanPanelsLineUp() {
        let scan = makeImage(1616, 680, (0, 0, 255), bands: [(0, 764, (255, 0, 0)), (764, 857, (0, 255, 0))])
        assertPanels(render(.nds, full: scan), layout: .nds)
    }

    func test3DSFullScanPanelsLineUp() {
        let scan = makeImage(1616, 680, (0, 0, 255), bands: [(0, 777, (255, 0, 0)), (777, 847, (0, 255, 0))])
        assertPanels(render(.threeDS, full: scan), layout: .threeDS)
    }

    func testMediumScanAndShiftedSplitsAreMappedPiecewise() {
        // coverfullM size, splits a few pixels off nominal (real scans vary ±5 px at 1616).
        let scan = makeImage(856, 352, (0, 0, 255), bands: [(0, 402, (255, 0, 0)), (402, 456, (0, 255, 0))])
        let (a, b) = HandheldCaseInsert.scanSplits(for: scan, platform: .nds)
        XCTAssertEqual(a, 402, accuracy: 1)
        XCTAssertEqual(b, 456, accuracy: 1)
        assertPanels(render(.nds, full: scan), layout: .nds)
    }

    func testSplitDetectionKeepsNominalWithoutEdge() {
        let flat = makeImage(1616, 680, (128, 128, 128))
        let (a, b) = HandheldCaseInsert.scanSplits(for: flat, platform: .threeDS)
        XCTAssertEqual(a, 777, accuracy: 0.5)
        XCTAssertEqual(b, 847, accuracy: 0.5)
    }

    func testDifferentLayoutStillAlignsPanels() {
        // A layout whose spine is much wider than the scan's: panels are stretched independently.
        let layout = HandheldCaseInsertLayout(back: 120, spine: 30, front: 125, height: 110)
        let scan = makeImage(1616, 680, (0, 0, 255), bands: [(0, 764, (255, 0, 0)), (764, 857, (0, 255, 0))])
        assertPanels(render(.nds, layout: layout, full: scan), layout: layout)
    }

    func testPSPFullUsesLayoutSplits() {
        let l = HandheldCaseInsertLayout.psp
        let w = 1070, split0 = Int(CGFloat(w) * l.uSplits.0), split1 = Int(CGFloat(w) * l.uSplits.1)
        let scan = makeImage(w, 860, (0, 0, 255), bands: [(0, split0, (255, 0, 0)), (split0, split1, (0, 255, 0))])
        assertPanels(render(.psp, full: scan), layout: l)
    }

    func testFullScanGetsNoBanner() {
        // A uniform scan must come out uniform: nothing drawn over real art.
        let scan = makeImage(1616, 680, (40, 160, 90))
        for platform in HandheldCasePlatform.allCases {
            let px = Pixels(render(platform, full: scan))
            for x in stride(from: 2, to: px.width - 2, by: 37) {
                for y in stride(from: 2, to: px.height - 2, by: 29) {
                    assertPixel(px.at(x, y), (40, 160, 90), tolerance: 3, "\(platform) \(x),\(y)")
                }
            }
        }
    }

    // MARK: Front only

    func testFrontOnlyFillsFrontPanelWithoutBanner() {
        let front = makeImage(768, 680, (30, 90, 200))
        for platform in HandheldCasePlatform.allCases {
            let layout = HandheldCaseInsertLayout.standard(for: platform)
            let img = render(platform, front: front)
            let px = Pixels(img)
            let x1 = Int((layout.back + layout.spine) * ppm)
            // Front panel is exactly the art everywhere, including where a banner would be.
            for x in stride(from: x1 + 2, to: img.width - 2, by: 23) {
                for y in stride(from: 2, to: img.height - 2, by: 31) {
                    assertPixel(px.at(x, y), (30, 90, 200), tolerance: 3, "\(platform) front \(x),\(y)")
                }
            }
            // Generated spine: platform strip on top (white for DS/3DS, black for PSP), front colour below.
            let spineX = Int((layout.back + layout.spine / 2) * ppm)
            let strip = platform == .psp ? (0, 0, 0) : (255, 255, 255)
            assertPixel(px.at(spineX - Int(layout.spine * ppm * 0.45), 2), strip, tolerance: 4, "\(platform) spine strip")
            assertPixel(px.at(spineX - Int(layout.spine * ppm * 0.45), img.height - 3), (30, 90, 200), tolerance: 4,
                        "\(platform) spine body")
        }
    }

    func testFrontAndBackImages() {
        let front = makeImage(768, 680, (30, 90, 200))
        let back = makeImage(700, 680, (220, 200, 20))
        let img = render(.threeDS, front: front, back: back)
        let px = Pixels(img)
        assertPixel(px.at(10, img.height / 2), (220, 200, 20), tolerance: 3, "back")
        assertPixel(px.at(Int(HandheldCaseInsertLayout.threeDS.back * ppm) - 3, 5), (220, 200, 20), tolerance: 3, "back corner")
    }

    func testArtCropExcludesBanner() throws {
        // DS front: white 18 mm strip on the left of a red front.
        let w = 768, h = 680, banner = Int(18.0 / 116 * 680)
        let front = makeImage(w, h, (200, 0, 0), bands: [(0, banner, (255, 255, 255))])
        let art = try XCTUnwrap(HandheldCaseInsert.artCrop(ofFront: front, platform: .nds, layout: .nds))
        let px = Pixels(art)
        assertPixel(px.at(1, h / 2), (200, 0, 0), tolerance: 3)
        let c = HandheldCaseInsert.dominantColor(of: art)
        XCTAssertEqual(c.r, 200.0 / 255, accuracy: 0.03)
    }

    // MARK: Placeholder

    func testPlaceholderBanners() {
        for platform in HandheldCasePlatform.allCases {
            let layout = HandheldCaseInsertLayout.standard(for: platform)
            let img = render(platform, title: "Homebrew Quest")
            let px = Pixels(img)
            let frontX = (layout.back + layout.spine) * ppm
            let artSample: (Int, Int)
            switch platform {
            case .nds:
                // White strip, 18 mm, next to the spine; sample its edges (away from the text).
                assertPixel(px.at(Int(frontX + 1.5 * ppm), 3), (255, 255, 255), tolerance: 2, "DS banner top")
                assertPixel(px.at(Int(frontX + 16.5 * ppm), img.height - 4), (255, 255, 255), tolerance: 2, "DS banner bottom")
                artSample = (Int(frontX + 20 * ppm), 3)
                // Dark text somewhere in the strip.
                XCTAssertTrue(column(px, x: Int(frontX + 9 * ppm)).contains { $0.0 < 120 }, "NINTENDO DS text")
            case .threeDS:
                assertPixel(px.at(img.width - 2, 3), (255, 255, 255), tolerance: 2, "3DS banner")
                assertPixel(px.at(Int(frontX + (layout.front - 13) * ppm), img.height - 4), (255, 255, 255), tolerance: 2)
                artSample = (Int(frontX + (layout.front - 16) * ppm), 3)
                XCTAssertTrue(column(px, x: Int(frontX + (layout.front - 7) * ppm)).contains { $0.0 > 150 && $0.1 < 90 }, "red text")
            case .psp:
                assertPixel(px.at(img.width - 3, 2), (0, 0, 0), tolerance: 2, "PSP bar right")
                assertPixel(px.at(Int(frontX + 2), Int(12 * ppm)), (0, 0, 0), tolerance: 2, "PSP bar bottom-left")
                artSample = (Int(frontX + 50 * ppm), Int(15 * ppm))
                let row = (Int(frontX + 5 * ppm)..<Int(frontX + 30 * ppm)).map { px.at($0, Int(6.5 * ppm)) }
                XCTAssertTrue(row.contains { $0.0 > 200 && $0.1 > 200 && $0.2 > 200 }, "white PSP text")
            }
            // Art area is the coloured gradient, not the banner colour.
            let a = px.at(artSample.0, artSample.1)
            XCTAssertFalse(a.0 > 240 && a.1 > 240 && a.2 > 240, "\(platform) art is not white: \(a)")
            XCTAssertFalse(a.0 < 8 && a.1 < 8 && a.2 < 8, "\(platform) art is not black: \(a)")
            // Spine strip on top.
            let spineX = Int((layout.back + layout.spine * 0.08) * ppm)
            assertPixel(px.at(spineX, 2), platform == .psp ? (0, 0, 0) : (255, 255, 255), tolerance: 2, "\(platform) spine strip")
        }
    }

    /// App Review test games: the neutral placeholder has no banner, spine strip or platform name.
    func testNeutralPlaceholderHasNoBanners() {
        for platform in HandheldCasePlatform.allCases {
            let layout = HandheldCaseInsertLayout.standard(for: platform)
            guard let img = HandheldCaseInsert.render(platform: platform, layout: layout, full: nil, front: nil, back: nil,
                                                      title: "Homebrew Quest", subtitle: nil, pixelsPerMM: ppm,
                                                      neutral: true) else { return XCTFail("render") }
            let px = Pixels(img)
            let frontX = (layout.back + layout.spine) * ppm
            let spots: [(Int, Int)] = [
                (Int(frontX + 1.5 * ppm), 3), (Int(frontX + 16.5 * ppm), img.height - 4),   // DS banner
                (img.width - 2, 3), (img.width - 2, img.height - 4),                          // 3DS banner
                (img.width - 3, 2), (Int(frontX + 2), Int(12 * ppm)),                         // PSP bar
                (Int((layout.back + layout.spine * 0.08) * ppm), 2),                          // spine strip
            ]
            for (x, y) in spots {
                let p = px.at(x, y)
                XCTAssertFalse(p.0 > 240 && p.1 > 240 && p.2 > 240, "\(platform) white banner at \(x),\(y): \(p)")
                XCTAssertFalse(p.0 < 8 && p.1 < 8 && p.2 < 8, "\(platform) black banner at \(x),\(y): \(p)")
            }
            // Nothing is drawn in the back panel's footer, where the platform name goes.
            let footerY = img.height - Int(10 * ppm)
            let footer = (Int(10 * ppm)..<Int((layout.back - 10) * ppm)).map { px.at($0, footerY) }
            XCTAssertFalse(footer.contains { $0.0 > 200 && $0.1 > 200 && $0.2 > 200 }, "\(platform) platform name")
            // The normal placeholder is unchanged.
            XCTAssertNotEqual(Pixels(render(platform, title: "Homebrew Quest")).at(Int((layout.back + layout.spine * 0.08) * ppm), 2).0,
                              px.at(Int((layout.back + layout.spine * 0.08) * ppm), 2).0)
        }
    }

    func testPlaceholderIsDeterministicAndTitleHued() {
        let a = HandheldCaseInsert.render(platform: .nds, layout: .nds, full: nil, front: nil, back: nil,
                                          title: "Alpha", subtitle: nil, pixelsPerMM: 2)!
        let b = HandheldCaseInsert.render(platform: .nds, layout: .nds, full: nil, front: nil, back: nil,
                                          title: "Alpha", subtitle: nil, pixelsPerMM: 2)!
        let c = HandheldCaseInsert.render(platform: .nds, layout: .nds, full: nil, front: nil, back: nil,
                                          title: "Omega Zone", subtitle: nil, pixelsPerMM: 2)!
        XCTAssertEqual(HandheldCaseInsert.encodePNG(a), HandheldCaseInsert.encodePNG(b))
        XCTAssertNotEqual(Pixels(a).at(4, 4).0 * 1000 + Pixels(a).at(4, 4).1, Pixels(c).at(4, 4).0 * 1000 + Pixels(c).at(4, 4).1)
    }

    func testPlaceholderHandlesEmptyAndLongTitles() {
        for title in ["", "   ", String(repeating: "Supercalifragilistic ", count: 12), "ドラゴンクエスト"] {
            for platform in HandheldCasePlatform.allCases {
                XCTAssertNotNil(HandheldCaseInsert.render(platform: platform, layout: .standard(for: platform), full: nil,
                                                          front: nil, back: nil, title: title, subtitle: title,
                                                          pixelsPerMM: 2))
            }
        }
    }

    // MARK: Helpers

    func testAspectFillCrop() {
        let r = HandheldCaseInsert.aspectFillCrop(imageSize: CGSize(width: 768, height: 680), aspect: 130.0 / 116)
        XCTAssertEqual(r.height, 680)
        XCTAssertEqual(r.width, (680 * 130.0 / 116).rounded())
        XCTAssertEqual(HandheldCaseInsert.aspectFillCrop(imageSize: .zero, aspect: 1), .zero)
        let tall = HandheldCaseInsert.aspectFillCrop(imageSize: CGSize(width: 512, height: 884), aspect: 100.0 / 172)
        XCTAssertEqual(tall.width, 512)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 512, height: 884).contains(tall))
    }

    func testDominantColour() {
        let img = makeImage(64, 64, (0, 0, 0), bands: [(0, 20, (255, 255, 255)), (20, 40, (20, 60, 200))])
        let c = HandheldCaseInsert.dominantColor(of: img)
        XCTAssertEqual(c.r, 20.0 / 255, accuracy: 0.03)
        XCTAssertEqual(c.b, 200.0 / 255, accuracy: 0.03)
    }

    func column(_ px: Pixels, x: Int) -> [(Int, Int, Int)] {
        (0..<px.height).map { px.at(x, $0) }
    }
}
