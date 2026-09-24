import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CaseCore

final class FakeIO: @unchecked Sendable {
    var files: [String: Data] = [:]
    var writes: [String: Data] = [:]
    var downloads: [URL] = []
    /// Per-URL responses; anything else gets `defaultResult`.
    var responses: [String: Result<Data, Error>] = [:]
    var defaultResult: Result<Data, Error> = .failure(HandheldCoverDownloadError.httpStatus(404))
}

struct OfflineError: Error {}

let romDir = URL(fileURLWithPath: "/Games/DS", isDirectory: true)
let cacheDir = URL(fileURLWithPath: "/Cache/Handheld", isDirectory: true)

func makeResolver(_ io: FakeIO, online: Bool = true, pspNames: [String: String] = [:]) -> HandheldCoverResolver {
    HandheldCoverResolver(
        fileExists: { io.files[$0.path] != nil || io.writes[$0.path] != nil },
        readData: { io.files[$0.path] ?? io.writes[$0.path] },
        download: { url in
            io.downloads.append(url)
            return try (io.responses[url.absoluteString] ?? io.defaultResult).get()
        },
        writeData: { data, url in io.writes[url.path] = data },
        cacheDirectory: cacheDir,
        onlineEnabled: online,
        pspNames: pspNames)
}

/// Solid image, or vertical bands `[(fromX, toX, (r, g, b))]`.
func makeImage(_ w: Int, _ h: Int, _ rgb: (Int, Int, Int) = (0, 0, 0), bands: [(Int, Int, (Int, Int, Int))] = []) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (x0, x1, c) in bands {
        ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: x0, y: 0, width: x1 - x0, height: h))
    }
    return ctx.makeImage()!
}

func png(_ w: Int, _ h: Int, _ rgb: (Int, Int, Int) = (0, 0, 0), bands: [(Int, Int, (Int, Int, Int))] = []) -> Data {
    HandheldCaseInsert.encodePNG(makeImage(w, h, rgb, bands: bands))!
}

func jpeg(_ w: Int, _ h: Int, _ rgb: (Int, Int, Int) = (0, 0, 0), bands: [(Int, Int, (Int, Int, Int))] = []) -> Data {
    HandheldCaseInsert.encodeJPEG(makeImage(w, h, rgb, bands: bands))!
}

/// RGBA pixel reader; (x, y) with y = 0 at the TOP row, like the image file.
struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// Bitmap memory is top row first.
    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

func assertPixel(_ p: (Int, Int, Int), _ e: (Int, Int, Int), tolerance: Int = 16, _ message: String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    let ok = abs(p.0 - e.0) <= tolerance && abs(p.1 - e.1) <= tolerance && abs(p.2 - e.2) <= tolerance
    XCTAssertTrue(ok, "\(message): got \(p), expected \(e)", file: file, line: line)
}

/// Project root (…/tools/case_tests/Tests/CaseCoreTests/<file> → up four).
func projectRoot(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
