import CoreGraphics
import Foundation
import CoreText
import ImageIO

enum PS2CoverDownloadError: Error, Equatable {
    case httpStatus(Int)
    case notHTTP
}

/// Finds a PS2 game's cover (front: local image next to the ROM → cached download → xlenore/ps2-covers → nil;
/// back: the same order with `<name>.back.*` / `back.*` files and the OPL Manager art database).
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

    /// Which side of the insert to look up.
    enum Side: Sendable {
        case front, back
    }

    // MARK: Constants

    /// Verified 2026-09-23 against github.com/xlenore/ps2-covers (branch `main`): front covers live in
    /// `covers/default/<SERIAL>.jpg` (serial with a hyphen, e.g. SLUS-20312.jpg, 512×736 JPEG); missing serials
    /// return HTTP 404. This is the same template the repo README gives for PCSX2's cover downloader.
    /// (`covers/3d/<SERIAL>.png` holds pre-rendered 3D box shots, which we don't want.)
    static let remoteURLTemplate = "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/${serial}.jpg"
    /// Verified 2026-09-23 against github.com/Luden02/psx-ps2-opl-art-database (branch `main`, a dump of the
    /// OPL Manager art database): back covers live in `PS2/<ID>/<ID>_COV2.png`, where `<ID>` is the serial in
    /// OPL's disc-file form (SLUS-20312 → SLUS_203.12; 11,501 of the 11,506 listed serials follow that rule),
    /// 242×344 PNG; missing ones return HTTP 404.
    static let backRemoteURLTemplate = "https://raw.githubusercontent.com/Luden02/psx-ps2-opl-art-database/main/PS2/${opl}/${opl}_COV2.png"

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

    /// Serial as the OPL art database names it (`SLUS-20312` → `SLUS_203.12`), or nil when it is not
    /// four letters, a hyphen and five digits.
    static func oplSerial(_ serial: String) -> String? {
        guard let s = normalizedSerial(serial), s.count == 10 else { return nil }
        let chars = Array(s)
        guard chars[0..<4].allSatisfy({ $0.isASCII && $0.isLetter }), chars[4] == "-",
              chars[5...].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "\(String(chars[0..<4]))_\(String(chars[5..<8])).\(String(chars[8..<10]))"
    }

    static func remoteURL(for serial: String, side: Side = .front) -> URL? {
        switch side {
        case .front:
            guard let s = normalizedSerial(serial) else { return nil }
            return URL(string: remoteURLTemplate.replacingOccurrences(of: "${serial}", with: s))
        case .back:
            guard let s = oplSerial(serial) else { return nil }
            return URL(string: backRemoteURLTemplate.replacingOccurrences(of: "${opl}", with: s))
        }
    }

    func cacheURL(for serial: String, side: Side = .front) -> URL? {
        guard let s = Self.normalizedSerial(serial) else { return nil }
        return cacheDirectory.appendingPathComponent(side == .front ? "\(s).jpg" : "\(s).back.png", isDirectory: false)
    }

    /// Image files next to the ROM, in priority order. iOS volumes are case-sensitive, so both
    /// lower- and upper-case extensions are listed. `cover.*` / `folder.*` only count when the
    /// directory holds this game alone; otherwise they could belong to any game. Back covers are
    /// `<name>.back.*`, or `back.*` in a single-game directory.
    func localCandidates(for romURL: URL, directoryHasSingleGame: Bool, side: Side = .front) -> [URL] {
        let dir = romURL.deletingLastPathComponent()
        let base = romURL.deletingPathExtension().lastPathComponent
        let exts = Self.imageExtensions.flatMap { [$0, $0.uppercased()] }
        var names: [String]
        switch side {
        case .front:
            names = exts.map { "\(base).\($0)" } + exts.map { "\(base).cover.\($0)" }
            if directoryHasSingleGame {
                for stem in ["cover", "Cover", "folder", "Folder"] {
                    names += exts.map { "\(stem).\($0)" }
                }
            }
        case .back:
            names = exts.map { "\(base).back.\($0)" }
            if directoryHasSingleGame {
                for stem in ["back", "Back"] {
                    names += exts.map { "\(stem).\($0)" }
                }
            }
        }
        return names.map { dir.appendingPathComponent($0, isDirectory: false) }
    }

    /// Cover image bytes (any ImageIO format), or nil when nothing usable was found.
    func resolve(romURL: URL, serial: String?, directoryHasSingleGame: Bool, side: Side = .front) async -> Data? {
        for url in localCandidates(for: romURL, directoryHasSingleGame: directoryHasSingleGame, side: side) where fileExists(url) {
            if let data = readData(url), Self.decodeImage(data) != nil { return data }
        }

        guard let serial, let cacheURL = cacheURL(for: serial, side: side) else { return nil }
        if fileExists(cacheURL), let data = readData(cacheURL), Self.decodeImage(data) != nil {
            return data
        }

        guard onlineEnabled, let remote = Self.remoteURL(for: serial, side: side) else { return nil }
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

    /// True when the front's top banner strip (9.4 %, where real inserts print "PlayStation 2") is one
    /// flat colour: artwork made without the banner (e.g. a homebrew cover), so the case's own lid
    /// print has to show over it.
    static func hasBlankBanner(_ image: CGImage) -> Bool {
        let front = frontCropRect(imageSize: CGSize(width: image.width, height: image.height))
        let strip = CGRect(x: front.minX, y: front.minY, width: front.width, height: (front.height * 0.09).rounded(.down))
        guard strip.height >= 1, let band = image.cropping(to: strip) else { return false }
        let w = 32, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(band, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        for channel in 0..<3 {
            let values = stride(from: channel, to: pixels.count, by: 4).map { Int(pixels[$0]) }
            guard let low = values.min(), let high = values.max(), high - low <= 12 else { return false }
        }
        return true
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

/// Insert sheet for a PS2 game with no cover art (homebrew, unknown serial, offline): a colour picked
/// from the title, disc-groove rings, and the title on the front, spine and back — so the case never
/// looks like a blank sleeve. Same layout as the real insert: back | spine | front seen from outside,
/// image top = case top. The lid's "PlayStation 2" banner (top 9.4 % of the front) and the spine's
/// logo band (top 27.5 % of the spine) are model prints drawn over it, so text stays clear of them.
enum PS2PlaceholderInsert {
    /// Horizontal extents of the three panels, as fractions of the sheet width (the case UVs).
    static let backEnd: CGFloat = 0.4727
    static let spineRange: ClosedRange<CGFloat> = 0.4759...0.5242
    static let frontStart: CGFloat = 0.5272
    static let frontBannerFraction: CGFloat = 0.094
    static let spineBandFraction: CGFloat = 0.275

    /// Deterministic hue in 0..<1 for `title` (FNV-1a), so a game keeps its colour across launches.
    static func hue(for title: String) -> CGFloat {
        var hash: UInt32 = 2_166_136_261
        for byte in title.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return CGFloat(hash % 360) / 360
    }

    static func render(title: String, subtitle: String?, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PS2" : title
        let hue = hue(for: name)

        // Background: a deep vertical gradient in the title's hue (CG origin is bottom-left).
        let top = rgb(hue: hue, saturation: 0.62, brightness: 0.46)
        let bottom = rgb(hue: hue + 0.05, saturation: 0.78, brightness: 0.13)
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        }

        let front = CGRect(x: (w * frontStart).rounded(), y: 0, width: w - (w * frontStart).rounded(), height: h)
        let back = CGRect(x: 0, y: 0, width: (w * backEnd).rounded(), height: h)
        let spine = CGRect(x: (w * spineRange.lowerBound).rounded(), y: 0,
                           width: (w * (spineRange.upperBound - spineRange.lowerBound)).rounded(), height: h)

        // Disc grooves, centred off the lower right of each face.
        drawRings(in: ctx, centre: CGPoint(x: front.maxX - front.width * 0.08, y: h * 0.16), maxRadius: front.width * 0.95)
        drawRings(in: ctx, centre: CGPoint(x: back.minX + back.width * 0.12, y: h * 0.2), maxRadius: back.width * 0.7)

        // Accent rule under the banner.
        ctx.setFillColor(rgb(hue: hue + 0.5, saturation: 0.55, brightness: 0.95, alpha: 0.9))
        let margin = front.width * 0.09
        ctx.fill(CGRect(x: front.minX + margin, y: h * (1 - frontBannerFraction) - h * 0.075, width: front.width * 0.16, height: max(4, h * 0.007)))

        // Front title: largest size (up to four lines) that fits below the accent rule.
        let titleBox = CGRect(x: front.minX + margin, y: h * 0.3,
                              width: front.width - margin * 2, height: h * (1 - frontBannerFraction) - h * 0.1 - h * 0.3)
        var used = CGRect.zero
        for size in stride(from: h * 0.105, through: h * 0.04, by: -h * 0.005) {
            if let fitted = drawText(name, in: titleBox, size: size, weight: .heavy, alpha: 1, ctx: ctx, maxLines: 4, commit: false) {
                used = drawText(name, in: titleBox, size: size, weight: .heavy, alpha: 1, ctx: ctx, maxLines: 4, commit: true) ?? fitted
                break
            }
        }
        if used == .zero {
            used = drawText(name, in: titleBox, size: h * 0.04, weight: .heavy, alpha: 1, ctx: ctx, maxLines: 4,
                            commit: true, truncate: true) ?? .zero
        }
        if let subtitle, !subtitle.isEmpty {
            let box = CGRect(x: titleBox.minX, y: used.minY - h * 0.075, width: titleBox.width, height: h * 0.05)
            _ = drawText(subtitle, in: box, size: h * 0.034, weight: .semibold, alpha: 0.72, ctx: ctx, maxLines: 1,
                         commit: true, truncate: true)
        }

        // Back: the title again, small, top left.
        let backMargin = back.width * 0.08
        let backBox = CGRect(x: back.minX + backMargin, y: h * 0.62, width: back.width - backMargin * 2, height: h * 0.3)
        _ = drawText(name, in: backBox, size: h * 0.05, weight: .bold, alpha: 0.9, ctx: ctx, maxLines: 3,
                     commit: true, truncate: true)

        // Spine: reads top to bottom (like the model's wordmark), below the logo band.
        ctx.saveGState()
        let spineLength = h * (1 - spineBandFraction) - h * 0.05
        ctx.translateBy(x: spine.midX, y: h * (1 - spineBandFraction) - h * 0.025)
        ctx.rotate(by: -.pi / 2)
        let spineBox = CGRect(x: 0, y: -spine.width * 0.5, width: spineLength, height: spine.width)
        _ = drawText(name, in: spineBox, size: spine.width * 0.5, weight: .bold, alpha: 1, ctx: ctx, maxLines: 1,
                     commit: true, truncate: true, verticallyCentred: true)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func drawRings(in ctx: CGContext, centre: CGPoint, maxRadius: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
        var radius = maxRadius * 0.18
        var index = 0
        while radius < maxRadius {
            ctx.setLineWidth(index % 3 == 0 ? maxRadius * 0.012 : maxRadius * 0.004)
            ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            radius += maxRadius * 0.055
            index += 1
        }
        ctx.restoreGState()
    }

    /// Draws `text` top-aligned in `box` (CG coordinates). Returns the used rect, or nil when it doesn't
    /// fit in `maxLines` without breaking a word (unless `truncate`, which ellipsises the last line).
    private static func drawText(_ text: String, in box: CGRect, size: CGFloat, weight: Weight,
                                 alpha: CGFloat, ctx: CGContext, maxLines: Int, commit: Bool,
                                 truncate: Bool = false, verticallyCentred: Bool = false) -> CGRect? {
        let font = weight.font(size: size)
        let colour = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < maxLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(box.width))
            guard count > 0 else { break }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            start += count
            if lines.count == maxLines - 1, start < length {
                guard truncate else { return nil }
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start - count, length: length - start + count))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                line = CTLineCreateTruncatedLine(rest, Double(box.width), .end, ellipsis) ?? line
                start = length
            }
            // A single word wider than the box would be split mid-word.
            if !truncate, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(box.width) + 0.5 { return nil }
            lines.append(line)
        }
        if start < length && !truncate { return nil }
        if lines.count == 1, truncate,
           let only = lines.first, CTLineGetTypographicBounds(only, nil, nil, nil) > Double(box.width) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            lines[0] = CTLineCreateTruncatedLine(only, Double(box.width), .end, ellipsis) ?? only
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.02
        let totalHeight = lineHeight * CGFloat(lines.count)
        guard totalHeight <= box.height + 0.5 || truncate else { return nil }
        var baseline = verticallyCentred ? box.midY + (ascent - descent) / 2 : box.maxY - ascent
        if commit {
            ctx.saveGState()
            ctx.textMatrix = .identity
            for line in lines {
                ctx.textPosition = CGPoint(x: box.minX, y: baseline)
                CTLineDraw(line, ctx)
                baseline -= lineHeight
            }
            ctx.restoreGState()
        }
        let top = verticallyCentred ? box.midY + totalHeight / 2 : box.maxY
        return CGRect(x: box.minX, y: top - totalHeight, width: box.width, height: totalHeight)
    }

    private static func rgb(hue: CGFloat, saturation s: CGFloat, brightness v: CGFloat, alpha: CGFloat = 1) -> CGColor {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    private enum Weight {
        case semibold, bold, heavy

        func font(size: CGFloat) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let value: CGFloat = switch self {
            case .semibold: 0.3
            case .bold: 0.4
            case .heavy: 0.56
            }
            let traits = [kCTFontWeightTrait: value] as CFDictionary
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
    }
}
