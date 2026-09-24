import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PS2Core

final class PS2CoverArtTests: XCTestCase {
    // MARK: Fakes

    final class FakeIO: @unchecked Sendable {
        var files: [String: Data] = [:]
        var writes: [String: Data] = [:]
        var downloads: [URL] = []
        var downloadResult: Result<Data, Error> = .failure(PS2CoverDownloadError.httpStatus(404))
    }

    let romDir = URL(fileURLWithPath: "/Games/PS2", isDirectory: true)
    let cacheDir = URL(fileURLWithPath: "/Cache/PS2Covers", isDirectory: true)
    var rom: URL { romDir.appendingPathComponent("Ratchet & Clank.iso") }

    func makeResolver(_ io: FakeIO, online: Bool = true) -> PS2CoverResolver {
        PS2CoverResolver(
            fileExists: { io.files[$0.path] != nil || io.writes[$0.path] != nil },
            readData: { io.files[$0.path] ?? io.writes[$0.path] },
            download: { url in
                io.downloads.append(url)
                return try io.downloadResult.get()
            },
            writeData: { data, url in io.writes[url.path] = data },
            cacheDirectory: cacheDir,
            onlineEnabled: online)
    }

    // MARK: Lookup order

    func testLocalImageWinsOverCacheAndDownload() async {
        let io = FakeIO()
        let local = png(100, 100, red: 255)
        io.files["/Games/PS2/Ratchet & Clank.png"] = local
        io.files["/Cache/PS2Covers/SCUS-97199.jpg"] = png(100, 100, green: 255)
        io.downloadResult = .success(png(100, 100, blue: 255))

        let data = await makeResolver(io).resolve(romURL: rom, serial: "SCUS-97199", directoryHasSingleGame: false)
        XCTAssertEqual(data, local)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testCacheWinsOverDownload() async {
        let io = FakeIO()
        let cached = png(100, 100, green: 255)
        io.files["/Cache/PS2Covers/SCUS-97199.jpg"] = cached
        io.downloadResult = .success(png(100, 100, blue: 255))

        let data = await makeResolver(io).resolve(romURL: rom, serial: "scus-97199", directoryHasSingleGame: false)
        XCTAssertEqual(data, cached)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testDownloadsFromVerifiedURLAndCaches() async {
        let io = FakeIO()
        let remote = png(128, 184, blue: 255)
        io.downloadResult = .success(remote)

        let data = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false)
        XCTAssertEqual(data, remote)
        XCTAssertEqual(io.downloads, [URL(string: "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/SLUS-20312.jpg")!])
        XCTAssertEqual(io.writes["/Cache/PS2Covers/SLUS-20312.jpg"], remote)
    }

    func testDownloadSkippedWhenOffline() async {
        let io = FakeIO()
        io.downloadResult = .success(png(128, 184))
        let data = await makeResolver(io, online: false).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false)
        XCTAssertNil(data)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testDownloadSkippedWithoutSerial() async {
        let io = FakeIO()
        io.downloadResult = .success(png(128, 184))
        let data = await makeResolver(io).resolve(romURL: rom, serial: nil, directoryHasSingleGame: false)
        XCTAssertNil(data)
        XCTAssertTrue(io.downloads.isEmpty)
    }

    func testUnsafeSerialIsRejected() async {
        let io = FakeIO()
        io.downloadResult = .success(png(128, 184))
        let data = await makeResolver(io).resolve(romURL: rom, serial: "../../etc/passwd", directoryHasSingleGame: false)
        XCTAssertNil(data)
        XCTAssertTrue(io.downloads.isEmpty)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func test404ReturnsNilWithSingleAttempt() async {
        let io = FakeIO()
        io.downloadResult = .failure(PS2CoverDownloadError.httpStatus(404))
        let data = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-99999", directoryHasSingleGame: false)
        XCTAssertNil(data)
        XCTAssertEqual(io.downloads.count, 1)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testBadDownloadIsNotCached() async {
        let io = FakeIO()
        io.downloadResult = .success(Data("404: Not Found".utf8))
        let garbage = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false)
        XCTAssertNil(garbage)

        io.downloadResult = .success(png(32, 32))  // decodes, but smaller than 64×64
        let tiny = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false)
        XCTAssertNil(tiny)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testCorruptLocalAndCacheFallThrough() async {
        let io = FakeIO()
        io.files["/Games/PS2/Ratchet & Clank.jpg"] = Data("not an image".utf8)
        io.files["/Cache/PS2Covers/SLUS-20312.jpg"] = Data("truncated".utf8)
        let remote = png(128, 184)
        io.downloadResult = .success(remote)
        let data = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false)
        XCTAssertEqual(data, remote)
    }

    func testFolderCoverOnlyForSingleGameDirectory() async {
        let io = FakeIO()
        let folder = png(100, 100, red: 200)
        io.files["/Games/PS2/cover.jpg"] = folder

        let shared = await makeResolver(io, online: false).resolve(romURL: rom, serial: nil, directoryHasSingleGame: false)
        XCTAssertNil(shared)
        let single = await makeResolver(io, online: false).resolve(romURL: rom, serial: nil, directoryHasSingleGame: true)
        XCTAssertEqual(single, folder)
    }

    func testLocalCandidateOrder() {
        let names = makeResolver(FakeIO()).localCandidates(for: rom, directoryHasSingleGame: true).map(\.lastPathComponent)
        XCTAssertEqual(names.first, "Ratchet & Clank.jpg")
        XCTAssertTrue(names.contains("Ratchet & Clank.JPG"))
        XCTAssertTrue(names.contains("Ratchet & Clank.webp"))
        XCTAssertTrue(names.contains("Ratchet & Clank.cover.png"))
        XCTAssertTrue(names.contains("folder.jpg"))
        XCTAssertLessThan(names.firstIndex(of: "Ratchet & Clank.heic")!, names.firstIndex(of: "Ratchet & Clank.cover.jpg")!)
        XCTAssertLessThan(names.firstIndex(of: "Ratchet & Clank.cover.jpg")!, names.firstIndex(of: "cover.jpg")!)
        XCTAssertTrue(Set(makeResolver(FakeIO()).localCandidates(for: rom, directoryHasSingleGame: true).map { $0.deletingLastPathComponent().path }) == [romDir.path])

        let multi = makeResolver(FakeIO()).localCandidates(for: rom, directoryHasSingleGame: false).map(\.lastPathComponent)
        XCTAssertFalse(multi.contains { $0.hasPrefix("cover.") || $0.hasPrefix("folder.") || $0.hasPrefix("Cover.") })
    }

    // MARK: Back covers

    func testOPLSerial() {
        XCTAssertEqual(PS2CoverResolver.oplSerial("SLUS-20312"), "SLUS_203.12")
        XCTAssertEqual(PS2CoverResolver.oplSerial(" slps-25245 "), "SLPS_252.45")
        XCTAssertNil(PS2CoverResolver.oplSerial("SLPMS-2548"))
        XCTAssertNil(PS2CoverResolver.oplSerial("SLUS_203.12"))
        XCTAssertNil(PS2CoverResolver.oplSerial("../../etc"))
    }

    func testBackDownloadsFromOPLDatabaseAndCaches() async {
        let io = FakeIO()
        io.downloadResult = .success(png(242, 344))
        let data = await makeResolver(io).resolve(romURL: rom, serial: "SLUS-20312", directoryHasSingleGame: false, side: .back)
        XCTAssertNotNil(data)
        XCTAssertEqual(io.downloads.map(\.absoluteString),
                       ["https://raw.githubusercontent.com/Luden02/psx-ps2-opl-art-database/main/PS2/SLUS_203.12/SLUS_203.12_COV2.png"])
        XCTAssertNotNil(io.writes[cacheDir.appendingPathComponent("SLUS-20312.back.png").path])
    }

    func testBackLocalCandidatesDoNotOverlapFront() {
        let resolver = makeResolver(FakeIO())
        let back = resolver.localCandidates(for: rom, directoryHasSingleGame: true, side: .back).map(\.lastPathComponent)
        let front = Set(resolver.localCandidates(for: rom, directoryHasSingleGame: true).map(\.lastPathComponent))
        XCTAssertEqual(back.first, "Ratchet & Clank.back.jpg")
        XCTAssertTrue(back.contains("back.png"))
        XCTAssertTrue(front.isDisjoint(with: back))
        XCTAssertFalse(resolver.localCandidates(for: rom, directoryHasSingleGame: false, side: .back)
            .contains { $0.lastPathComponent.hasPrefix("back.") })
    }

    // MARK: Crop

    func testCropWideImage() {
        let r = PS2CoverResolver.frontCropRect(imageSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.height, 500)
        XCTAssertEqual(r.width, (500 * 129.5 / 183).rounded(), accuracy: 0.001)  // 354
        XCTAssertEqual(r.minX, ((1000 - r.width) / 2).rounded(.down))
        XCTAssertEqual(r.minY, 0)
    }

    func testCropTallImage() {
        // xlenore covers are 512×736: slightly taller than the insert, so trim top and bottom.
        let r = PS2CoverResolver.frontCropRect(imageSize: CGSize(width: 512, height: 736))
        XCTAssertEqual(r.width, 512)
        XCTAssertEqual(r.height, (512 * 183 / 129.5).rounded())  // 724
        XCTAssertEqual(r.minY, 6)
        XCTAssertEqual(r.minX, 0)
        XCTAssertEqual(r.width / r.height, 129.5 / 183, accuracy: 0.002)
    }

    func testCropExactAspect() {
        let size = CGSize(width: 1295, height: 1830)
        XCTAssertEqual(PS2CoverResolver.frontCropRect(imageSize: size), CGRect(origin: .zero, size: size))
    }

    func testCropFillsNeverLetterboxes() {
        for size in [CGSize(width: 1, height: 1000), CGSize(width: 1000, height: 1), CGSize(width: 333, height: 777)] {
            let r = PS2CoverResolver.frontCropRect(imageSize: size)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(r), "\(size) -> \(r)")
            XCTAssertTrue(r.width == size.width || r.height == size.height)
        }
        XCTAssertEqual(PS2CoverResolver.frontCropRect(imageSize: .zero), .zero)
    }

    // MARK: Dominant color

    func testDominantColorSolid() {
        let c = PS2CoverResolver.dominantColor(of: image([(1.0, (200, 30, 40))]))
        assertColor(c, 200, 30, 40)
    }

    func testDominantColorIgnoresBlackAndWhiteBackground() {
        // 45 % black, 25 % white, 20 % blue, 10 % yellow → blue.
        let img = image([(0.45, (0, 0, 0)), (0.25, (255, 255, 255)), (0.20, (20, 60, 200)), (0.10, (230, 210, 20))])
        assertColor(PS2CoverResolver.dominantColor(of: img), 20, 60, 200)
    }

    func testDominantColorFallsBackToExtremeWhenItDominates() {
        let img = image([(0.97, (5, 5, 5)), (0.03, (220, 20, 20))])
        assertColor(PS2CoverResolver.dominantColor(of: img), 5, 5, 5)
    }

    func testDominantColorOnRealDecodedData() {
        let data = png(80, 120, red: 30, green: 140, blue: 70)
        let decoded = PS2CoverResolver.decodeImage(data)
        XCTAssertEqual(decoded?.width, 80)
        XCTAssertEqual(decoded?.height, 120)
        assertColor(PS2CoverResolver.dominantColor(of: decoded!), 30, 140, 70)
        XCTAssertNil(PS2CoverResolver.decodeImage(Data()))
        XCTAssertNil(PS2CoverResolver.decodeImage(Data("<html>".utf8)))
    }

    // MARK: Opt-in network

    func testLiveDownloadFromXlenore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PS2_NETWORK_TESTS"] == "1", "set PS2_NETWORK_TESTS=1")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ps2covers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let resolver = PS2CoverResolver.live(cacheDirectory: cache, onlineEnabled: true)
        let missingROM = cache.appendingPathComponent("roms/none.iso")

        let data = await resolver.resolve(romURL: missingROM, serial: "SLUS-20312", directoryHasSingleGame: false)
        let img = try XCTUnwrap(data.flatMap(PS2CoverResolver.decodeImage))
        XCTAssertGreaterThanOrEqual(img.width, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("SLUS-20312.jpg").path))

        let missing = await resolver.resolve(romURL: missingROM, serial: "SLUS-99999", directoryHasSingleGame: false)
        XCTAssertNil(missing)

        let back = await resolver.resolve(romURL: missingROM, serial: "SLUS-20312", directoryHasSingleGame: false, side: .back)
        let backImage = try XCTUnwrap(back.flatMap(PS2CoverResolver.decodeImage))
        XCTAssertGreaterThanOrEqual(backImage.width, 64)
        let missingBack = await resolver.resolve(romURL: missingROM, serial: "SLUS-99999", directoryHasSingleGame: false, side: .back)
        XCTAssertNil(missingBack)
    }

    // MARK: Helpers

    func assertColor(_ c: (r: Double, g: Double, b: Double), _ r: Int, _ g: Int, _ b: Int,
                     file: StaticString = #filePath, line: UInt = #line) {
        let tol = 6.0 / 255
        XCTAssertEqual(c.r, Double(r) / 255, accuracy: tol, "r", file: file, line: line)
        XCTAssertEqual(c.g, Double(g) / 255, accuracy: tol, "g", file: file, line: line)
        XCTAssertEqual(c.b, Double(b) / 255, accuracy: tol, "b", file: file, line: line)
    }

    /// Horizontal bands, each covering `fraction` of a 64×64 image.
    func image(_ bands: [(Double, (Int, Int, Int))], size: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = 0.0
        for (fraction, (r, g, b)) in bands {
            ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            let h = fraction * Double(size)
            ctx.fill(CGRect(x: 0, y: y, width: Double(size), height: h))
            y += h
        }
        return ctx.makeImage()!
    }

    func png(_ w: Int, _ h: Int, red: Int = 0, green: Int = 0, blue: Int = 0) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
