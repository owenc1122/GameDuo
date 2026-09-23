import CoreGraphics
import Foundation
import ImageIO

enum PS2CoverDownloadError: Error, Equatable {
    case httpStatus(Int)
    case notHTTP
}

/// Finds a PS2 game's cover: local image next to the ROM → cached download → xlenore/ps2-covers → nil.
/// All I/O is injected so the lookup order is unit-testable; use `live(cacheDirectory:onlineEnabled:)` in the app.
/// A cover found inside an archive (`cover.*`) is the caller's job: check it before calling `resolve`.
struct PS2CoverResolver: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var readData: @Sendable (URL) -> Data?
    /// Must throw for non-200 responses (e.g. `PS2CoverDownloadError.httpStatus(404)`) and enforce its own timeout.
    var download: @Sendable (URL) async throws -> Data
    var writeData: @Sendable (Data, URL) throws -> Void
    var cacheDirectory: URL
    var onlineEnabled: Bool

    init(fileExists: @escaping @Sendable (URL) -> Bool,
         readData: @escaping @Sendable (URL) -> Data?,
         download: @escaping @Sendable (URL) async throws -> Data,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = PS2CoverResolver.defaultWrite,
         cacheDirectory: URL,
         onlineEnabled: Bool) {
        self.fileExists = fileExists
        self.readData = readData
        self.download = download
        self.writeData = writeData
        self.cacheDirectory = cacheDirectory
        self.onlineEnabled = onlineEnabled
    }

    // MARK: Constants

    /// Verified 2026-09-23 against github.com/xlenore/ps2-covers (branch `main`): front covers live in
    /// `covers/default/<SERIAL>.jpg` (serial with a hyphen, e.g. SLUS-20312.jpg, 512×736 JPEG); missing serials
    /// return HTTP 404. This is the same template the repo README gives for PCSX2's cover downloader.
    /// (`covers/3d/<SERIAL>.png` holds pre-rendered 3D box shots, which we don't want.)
    static let remoteURLTemplate = "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/${serial}.jpg"

    /// Formats ImageIO decodes on iOS (WebP since iOS 14, HEIC since iOS 11).
    static let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic"]
    /// Front of a US PS2 case insert, width : height in mm.
    static let frontAspect: CGFloat = 129.5 / 183
    static let minimumDownloadSide = 64
    static let maximumDownloadBytes = 8 * 1024 * 1024
    static let downloadTimeout: TimeInterval = 10

    // MARK: Lookup

    /// Serial as used in file names (`SLUS-20312`), or nil if it contains anything but letters, digits, `-`, `_`.
    static func normalizedSerial(_ serial: String) -> String? {
        let s = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty, s.count <= 20,
              s.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        return s
    }

    static func remoteURL(for serial: String) -> URL? {
        guard let s = normalizedSerial(serial) else { return nil }
        return URL(string: remoteURLTemplate.replacingOccurrences(of: "${serial}", with: s))
    }

    func cacheURL(for serial: String) -> URL? {
        guard let s = Self.normalizedSerial(serial) else { return nil }
        return cacheDirectory.appendingPathComponent("\(s).jpg", isDirectory: false)
    }

    /// Image files next to the ROM, in priority order. iOS volumes are case-sensitive, so both
    /// lower- and upper-case extensions are listed. `cover.*` / `folder.*` only count when the
    /// directory holds this game alone; otherwise they could belong to any game.
    func localCandidates(for romURL: URL, directoryHasSingleGame: Bool) -> [URL] {
        let dir = romURL.deletingLastPathComponent()
        let base = romURL.deletingPathExtension().lastPathComponent
        let exts = Self.imageExtensions.flatMap { [$0, $0.uppercased()] }
        var names = exts.map { "\(base).\($0)" } + exts.map { "\(base).cover.\($0)" }
        if directoryHasSingleGame {
            for stem in ["cover", "Cover", "folder", "Folder"] {
                names += exts.map { "\(stem).\($0)" }
            }
        }
        return names.map { dir.appendingPathComponent($0, isDirectory: false) }
    }

    /// Cover image bytes (any ImageIO format), or nil when nothing usable was found.
    func resolve(romURL: URL, serial: String?, directoryHasSingleGame: Bool) async -> Data? {
        for url in localCandidates(for: romURL, directoryHasSingleGame: directoryHasSingleGame) where fileExists(url) {
            if let data = readData(url), Self.decodeImage(data) != nil { return data }
        }

        guard let serial, let cacheURL = cacheURL(for: serial) else { return nil }
        if fileExists(cacheURL), let data = readData(cacheURL), Self.decodeImage(data) != nil {
            return data
        }

        guard onlineEnabled, let remote = Self.remoteURL(for: serial) else { return nil }
        // One attempt; 404 and network errors both mean "no cover".
        guard let data = try? await download(remote), Self.isUsableDownload(data) else { return nil }
        try? writeData(data, cacheURL)
        return data
    }

    static func isUsableDownload(_ data: Data) -> Bool {
        guard data.count <= maximumDownloadBytes, let image = decodeImage(data) else { return false }
        return image.width >= minimumDownloadSide && image.height >= minimumDownloadSide
    }

    // MARK: Production

    @Sendable static func defaultWrite(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func live(cacheDirectory: URL, onlineEnabled: Bool) -> PS2CoverResolver {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = downloadTimeout
        config.timeoutIntervalForResource = downloadTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "GameDuo"]
        let session = URLSession(configuration: config)
        return PS2CoverResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            readData: { try? Data(contentsOf: $0) },
            download: { url in
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw PS2CoverDownloadError.notHTTP }
                guard http.statusCode == 200 else { throw PS2CoverDownloadError.httpStatus(http.statusCode) }
                return data
            },
            cacheDirectory: cacheDirectory,
            onlineEnabled: onlineEnabled)
    }

    // MARK: Image helpers

    static func decodeImage(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Centered aspect-fill crop to the 129.5 : 183 front insert (never letterboxes), in pixel units.
    static func frontCropRect(imageSize: CGSize) -> CGRect {
        let w = imageSize.width, h = imageSize.height
        guard w > 0, h > 0 else { return .zero }
        if w / h > frontAspect {
            let cw = min(w, (h * frontAspect).rounded())
            return CGRect(x: ((w - cw) / 2).rounded(.down), y: 0, width: cw, height: h)
        } else {
            let ch = min(h, (w / frontAspect).rounded())
            return CGRect(x: 0, y: ((h - ch) / 2).rounded(.down), width: w, height: ch)
        }
    }

    /// Most common color (0…1 sRGB) used to extend the spine and back of the insert.
    /// Near-black and near-white pixels are ignored unless they make up more than 90 % of the image.
    static func dominantColor(of image: CGImage) -> (r: Double, g: Double, b: Double) {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        let fallback = (r: 0.5, g: 0.5, b: 0.5)
        guard drawn else { return fallback }

        var colorful = [Int: Bucket](), extreme = [Int: Bucket]()
        var colorfulCount = 0, extremeCount = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a >= 128 else { continue }
            // Un-premultiply.
            let r = min(255, Int(pixels[i]) * 255 / a)
            let g = min(255, Int(pixels[i + 1]) * 255 / a)
            let b = min(255, Int(pixels[i + 2]) * 255 / a)
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)  // 8 levels per channel
            let isExtreme = max(r, g, b) < 28 || min(r, g, b) > 228
            if isExtreme {
                extreme[key, default: Bucket()].add(r, g, b); extremeCount += 1
            } else {
                colorful[key, default: Bucket()].add(r, g, b); colorfulCount += 1
            }
        }
        let total = colorfulCount + extremeCount
        guard total > 0 else { return fallback }
        var histogram = colorful
        if colorfulCount * 10 < total {
            histogram.merge(extreme) { a, b in
                Bucket(count: a.count + b.count, r: a.r + b.r, g: a.g + b.g, b: a.b + b.b)
            }
        }
        guard let top = histogram.values.max(by: { $0.count < $1.count }), top.count > 0 else { return fallback }
        let n = Double(top.count) * 255
        return (Double(top.r) / n, Double(top.g) / n, Double(top.b) / n)
    }
}

private struct Bucket {
    var count = 0, r = 0, g = 0, b = 0

    mutating func add(_ r: Int, _ g: Int, _ b: Int) {
        count += 1; self.r += r; self.g += g; self.b += b
    }
}
