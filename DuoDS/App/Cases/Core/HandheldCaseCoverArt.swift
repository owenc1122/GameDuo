import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Cover art for the Nintendo DS / Nintendo 3DS / PSP retail cases (Handheld_Cases/CONTRACT.md):
// finding the art (`HandheldCoverResolver`) and painting the one insert sheet the case model maps
// back | spine | front (`HandheldCaseInsert`). Pure Foundation / CoreGraphics / ImageIO / CoreText so it
// is unit-tested on macOS by tools/case_tests (`cd tools/case_tests && swift test`).

enum HandheldCasePlatform: String, Sendable, CaseIterable {
    case nds, threeDS, psp

    /// Folder under the cover cache.
    var cacheFolder: String {
        switch self {
        case .nds: "nds"
        case .threeDS: "3ds"
        case .psp: "psp"
        }
    }

    /// GameTDB platform path component (nil: GameTDB has no covers for it).
    var gameTDBPlatform: String? {
        switch self {
        case .nds: "ds"
        case .threeDS: "3ds"
        case .psp: nil
        }
    }
}

enum HandheldCoverSide: String, Sendable, CaseIterable {
    /// Front panel only.
    case front
    /// Back panel only.
    case back
    /// The whole wrap scan, back | spine | front (GameTDB `coverfull*`).
    case full
}

/// The real printed insert sheet, in millimetres: back | spine | front, `height` tall.
/// These are the best current numbers (Handheld_Cases/RESEARCH.md §1–3 and GameTDB scan measurements);
/// the case models state the final ones in Handheld_Cases/<NDS|3DS|UMD>/contract.json (`insert_mm`),
/// which must match these.
struct HandheldCaseInsertLayout: Sendable, Equatable {
    var back: CGFloat
    var spine: CGFloat
    var front: CGFloat
    var height: CGFloat

    /// US DS insert, as published in Handheld_Cases/NDS/contract.json: Cover Project template 130 × 116 mm per
    /// face, spine ≈ 15.7 mm (RESEARCH.md; ≈ 93 of 1616 × 680 px on GameTDB coverfullHQ scans).
    static let nds = HandheldCaseInsertLayout(back: 130, spine: 15.7, front: 130, height: 116)
    /// US 3DS insert, as published in Handheld_Cases/3DS/contract.json: 276 mm × (777 | 70 | 769) / 1616 px of a
    /// GameTDB coverfullHQ scan, 680 px = 116.1 mm (12 mm spine per RESEARCH.md §2).
    static let threeDS = HandheldCaseInsertLayout(back: 132.7, spine: 12, front: 131.3, height: 116.1)
    /// US PSP UMD insert, as published in Handheld_Cases/UMD/contract.json (RESEARCH.md §3 estimate: front
    /// ≈ 100 × 172 mm, libretro fronts are 512 × 884 = 0.579 ≈ 99.5 / 172).
    static let psp = HandheldCaseInsertLayout(back: 99.5, spine: 14, front: 99.5, height: 172)

    static func standard(for platform: HandheldCasePlatform) -> HandheldCaseInsertLayout {
        switch platform {
        case .nds: .nds
        case .threeDS: .threeDS
        case .psp: .psp
        }
    }

    var totalWidth: CGFloat { back + spine + front }

    /// (end of back panel, start of front panel) as fractions of the sheet width — the case UVs.
    var uSplits: (CGFloat, CGFloat) {
        let total = totalWidth
        guard total > 0 else { return (0, 0) }
        return (back / total, (back + spine) / total)
    }

    var frontAspect: CGFloat { height > 0 ? front / height : 1 }
    var backAspect: CGFloat { height > 0 ? back / height : 1 }

    /// Reads `{"insert_mm": {"back": B, "spine": S, "front": F, "height": H}}` from a case `contract.json`.
    static func fromContract(_ data: Data) -> HandheldCaseInsertLayout? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mm = root["insert_mm"] as? [String: Any] else { return nil }
        func value(_ key: String) -> CGFloat? {
            guard let n = mm[key] as? NSNumber, n.doubleValue > 0 else { return nil }
            return CGFloat(n.doubleValue)
        }
        guard let b = value("back"), let s = value("spine"), let f = value("front"), let h = value("height") else { return nil }
        return HandheldCaseInsertLayout(back: b, spine: s, front: f, height: h)
    }
}

enum HandheldCoverDownloadError: Error, Equatable {
    case httpStatus(Int)
    case notHTTP
}

/// Everything found for one game's insert, already in the right precedence (see `resolveInsert`).
struct HandheldCoverArtSet: Sendable, Equatable {
    var full: Data?
    var front: Data?
    var back: Data?

    var isEmpty: Bool { full == nil && front == nil && back == nil }
}

/// Finds a DS / 3DS / PSP game's insert art. Order per side: image next to the ROM → cached download →
/// online source → nil. All I/O is injected so the order is unit-testable; use `live(...)` in the app.
///
/// Online sources (verified 2026-09-23):
/// - DS / 3DS: GameTDB, `https://art.gametdb.com/{ds|3ds}/{type}/{REGION}/{ID}.jpg`, ID = the 4-character game
///   code (upper case; lower case 404s). `.full` = `coverfullHQ` (1616 × 680) then `coverfullM` (856 × 352);
///   `.front` = `coverHQ` (768 × 680) then `coverM` (400 × 352). Regions US, EN, then the code's own region
///   (4th letter: E→US, P→EN, J→JA, K→KO, D→DE, F→FR, …). Missing art is HTTP 404.
/// - PSP: libretro-thumbnails `Named_Boxarts` (front only), keyed by the serial → thumbnail-name map
///   bundled as `PSP-Boxart-Names.json` (tools/case_tests/generate_psp_names.py). No keyless back/full
///   source exists, so PSP back/full come only from local files.
///
/// `.back` has no download of its own: after the local and cached back it is cropped out of the `.full` scan
/// (local, cached or downloaded), so the app may either ask for `.back` or simply render the `.full` scan.
struct HandheldCoverResolver: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var readData: @Sendable (URL) -> Data?
    /// Must throw for non-200 responses (`HandheldCoverDownloadError.httpStatus(404)`) and enforce its own timeout.
    /// Any other error (offline, timeout) stops the remaining fallback URLs of that lookup.
    var download: @Sendable (URL) async throws -> Data
    var writeData: @Sendable (Data, URL) throws -> Void
    var cacheDirectory: URL
    var onlineEnabled: Bool
    /// PSP serial ("ULUS-10041") → libretro thumbnail name.
    var pspNames: [String: String]

    init(fileExists: @escaping @Sendable (URL) -> Bool,
         readData: @escaping @Sendable (URL) -> Data?,
         download: @escaping @Sendable (URL) async throws -> Data,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = HandheldCoverResolver.defaultWrite,
         cacheDirectory: URL,
         onlineEnabled: Bool,
         pspNames: [String: String] = [:]) {
        self.fileExists = fileExists
        self.readData = readData
        self.download = download
        self.writeData = writeData
        self.cacheDirectory = cacheDirectory
        self.onlineEnabled = onlineEnabled
        self.pspNames = pspNames
    }

    // MARK: Constants

    static let gameTDBBase = "https://art.gametdb.com"
    /// Resolves the repo's symlinked thumbnails (raw.githubusercontent.com returns the link text for those).
    static let libretroPSPBase = "https://thumbnails.libretro.com/Sony%20-%20PlayStation%20Portable/Named_Boxarts/"
    static let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic"]
    static let minimumDownloadSide = 64
    static let maximumDownloadBytes = 8 * 1024 * 1024
    static let downloadTimeout: TimeInterval = 10

    // MARK: IDs

    /// The ID used for URLs and cache names, or nil when `productID` isn't a plausible code for `platform`.
    /// DS: 4-character game code ("AMCE"; "NTR-P-AMCE" also accepted). 3DS: "CTR-P-AMKE" → "AMKE"
    /// (bare 4-character codes accepted). PSP: disc ID "ULUS-10041" (the hyphen is optional).
    static func normalizedID(_ productID: String?, platform: HandheldCasePlatform) -> String? {
        guard let raw = productID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !raw.isEmpty, raw.count <= 24,
              raw.unicodeScalars.allSatisfy({ isUpperAlnum($0) || $0 == "-" || $0 == "_" }) else { return nil }
        switch platform {
        case .nds, .threeDS:
            let code: Substring
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 1 {
                code = parts[0]
            } else if parts.count >= 3, ["NTR", "TWL", "CTR", "KTR"].contains(String(parts[0])), parts[1].count == 1 {
                code = parts[2]
            } else {
                return nil
            }
            guard code.count == 4, code.unicodeScalars.allSatisfy(isUpperAlnum) else { return nil }
            return String(code)
        case .psp:
            let compact = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            let chars = Array(compact.unicodeScalars)
            guard chars.count == 9,
                  chars[0..<4].allSatisfy({ ("A"..."Z").contains($0) }),
                  chars[4...].allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return "\(String(compact.prefix(4)))-\(String(compact.suffix(5)))"
        }
    }

    private static func isUpperAlnum(_ s: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }

    /// GameTDB regions to try for a 4-character code: US, EN, then the code's own region.
    static func gameTDBRegions(for code: String) -> [String] {
        var regions = ["US", "EN"]
        let own: String? = switch code.last {
        case "E", "T": "US"
        case "P", "X", "Y", "Z", "L", "M", "N", "V": "EN"
        case "J": "JA"
        case "K": "KO"
        case "D": "DE"
        case "F": "FR"
        case "S": "ES"
        case "I": "IT"
        case "H": "NL"
        case "R": "RU"
        case "U": "AU"
        case "C": "ZHCN"
        case "W": "ZHTW"
        default: nil
        }
        if let own, !regions.contains(own) { regions.append(own) }
        return regions
    }

    /// libretro thumbnail file name: `&*/:\`<>?\|"` become `_` (RetroArch's rule; verified
    /// "Harvest Moon - Boy _ Girl (USA).png" 200 vs the `&` spelling 404).
    static func libretroThumbnailName(_ name: String) -> String {
        let forbidden = Set("&*/:`<>?\\|\"")
        return String(name.map { forbidden.contains($0) ? "_" : $0 })
    }

    static func libretroURL(forName name: String) -> URL? {
        let escaped = libretroThumbnailName(name)
        guard !escaped.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        guard let encoded = escaped.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: libretroPSPBase + encoded + ".png")
    }

    /// Download candidates in order (empty when the side has no online source).
    func remoteURLs(id: String, platform: HandheldCasePlatform, side: HandheldCoverSide) -> [URL] {
        switch platform {
        case .nds, .threeDS:
            guard let tdb = platform.gameTDBPlatform else { return [] }
            let types: [String] = switch side {
            case .full: ["coverfullHQ", "coverfullM"]
            case .front: ["coverHQ", "coverM"]
            case .back: []
            }
            let regions = Self.gameTDBRegions(for: id)
            return types.flatMap { type in
                regions.compactMap { URL(string: "\(Self.gameTDBBase)/\(tdb)/\(type)/\($0)/\(id).jpg") }
            }
        case .psp:
            guard side == .front, let name = pspNames[id], let url = Self.libretroURL(forName: name) else { return [] }
            return [url]
        }
    }

    // MARK: Local and cache

    /// Image files next to the ROM, in priority order. iOS volumes are case-sensitive, so lower- and
    /// upper-case extensions are listed. Folder-wide names (`cover.*`, `folder.*`, `back.*`, `full.*`)
    /// only count when the directory holds this game alone.
    func localCandidates(for romURL: URL, directoryHasSingleGame: Bool, side: HandheldCoverSide) -> [URL] {
        let dir = romURL.deletingLastPathComponent()
        let base = romURL.deletingPathExtension().lastPathComponent
        let exts = Self.imageExtensions.flatMap { [$0, $0.uppercased()] }
        var names: [String]
        let stems: [String]
        switch side {
        case .front:
            names = exts.map { "\(base).\($0)" } + exts.map { "\(base).cover.\($0)" }
            stems = ["cover", "Cover", "folder", "Folder"]
        case .back:
            names = exts.map { "\(base).back.\($0)" }
            stems = ["back", "Back"]
        case .full:
            names = exts.map { "\(base).full.\($0)" }
            stems = ["full", "Full"]
        }
        if directoryHasSingleGame {
            for stem in stems { names += exts.map { "\(stem).\($0)" } }
        }
        return names.map { dir.appendingPathComponent($0, isDirectory: false) }
    }

    /// `<cacheDirectory>/<platform>/<ID>.<side>.<ext>`; `ext` is jpg or png, from the downloaded bytes.
    func cacheURL(id: String, platform: HandheldCasePlatform, side: HandheldCoverSide, ext: String) -> URL {
        cacheDirectory
            .appendingPathComponent(platform.cacheFolder, isDirectory: true)
            .appendingPathComponent("\(id).\(side.rawValue).\(ext)", isDirectory: false)
    }

    func localImage(romURL: URL, platform: HandheldCasePlatform, directoryHasSingleGame: Bool, side: HandheldCoverSide) -> Data? {
        for url in localCandidates(for: romURL, directoryHasSingleGame: directoryHasSingleGame, side: side) where fileExists(url) {
            if let data = readData(url), let image = HandheldCaseInsert.decodeImage(data),
               side != .full || Self.isPlausibleFull(image, platform: platform) { return data }
        }
        return nil
    }

    func cachedImage(id: String, platform: HandheldCasePlatform, side: HandheldCoverSide) -> Data? {
        for ext in ["jpg", "png"] {
            let url = cacheURL(id: id, platform: platform, side: side, ext: ext)
            if fileExists(url), let data = readData(url), HandheldCaseInsert.decodeImage(data) != nil { return data }
        }
        return nil
    }

    /// Tries each remote URL in order; HTTP errors and unusable bytes fall through to the next one, any other
    /// error (offline, timeout) ends the lookup. A usable image is written to the cache.
    func downloadImage(id: String, platform: HandheldCasePlatform, side: HandheldCoverSide) async -> Data? {
        guard onlineEnabled else { return nil }
        for url in remoteURLs(id: id, platform: platform, side: side) {
            let data: Data
            do {
                data = try await download(url)
            } catch is HandheldCoverDownloadError {
                continue
            } catch {
                return nil
            }
            guard Self.isUsableDownload(data, platform: platform, side: side) else { continue }
            let ext = Self.isPNG(data) ? "png" : "jpg"
            try? writeData(data, cacheURL(id: id, platform: platform, side: side, ext: ext))
            return data
        }
        return nil
    }

    // MARK: Lookup

    /// Image bytes (any ImageIO format) for one side, or nil when nothing usable was found.
    /// `.back` falls back to the back panel cropped from the `.full` scan (JPEG bytes).
    func resolve(romURL: URL, productID: String?, platform: HandheldCasePlatform,
                 directoryHasSingleGame: Bool, side: HandheldCoverSide) async -> Data? {
        if let local = localImage(romURL: romURL, platform: platform, directoryHasSingleGame: directoryHasSingleGame, side: side) {
            return local
        }
        let id = Self.normalizedID(productID, platform: platform)
        if let id, let cached = cachedImage(id: id, platform: platform, side: side) { return cached }
        if side == .back {
            guard let fullData = await resolve(romURL: romURL, productID: productID, platform: platform,
                                               directoryHasSingleGame: directoryHasSingleGame, side: .full),
                  let full = HandheldCaseInsert.decodeImage(fullData) else { return nil }
            return HandheldCaseInsert.croppedBack(ofFull: full, platform: platform).flatMap(HandheldCaseInsert.encodeJPEG)
        }
        guard let id else { return nil }
        return await downloadImage(id: id, platform: platform, side: side)
    }

    /// The art to render, honouring the user's own files first: a local full scan; else local front
    /// (with a local back if any — no download then overrides them); else a cached/downloaded full scan;
    /// else a cached/downloaded front (plus local back). Pass the result to `HandheldCaseInsert.render`.
    func resolveInsert(romURL: URL, productID: String?, platform: HandheldCasePlatform,
                       directoryHasSingleGame: Bool) async -> HandheldCoverArtSet {
        if let full = localImage(romURL: romURL, platform: platform, directoryHasSingleGame: directoryHasSingleGame, side: .full) {
            return HandheldCoverArtSet(full: full)
        }
        let localBack = localImage(romURL: romURL, platform: platform, directoryHasSingleGame: directoryHasSingleGame, side: .back)
        if let front = localImage(romURL: romURL, platform: platform, directoryHasSingleGame: directoryHasSingleGame, side: .front) {
            return HandheldCoverArtSet(front: front, back: localBack)
        }
        guard let id = Self.normalizedID(productID, platform: platform) else {
            return HandheldCoverArtSet(back: localBack)
        }
        if localBack == nil {
            if let full = cachedImage(id: id, platform: platform, side: .full) {
                return HandheldCoverArtSet(full: full)
            }
            if let full = await downloadImage(id: id, platform: platform, side: .full) {
                return HandheldCoverArtSet(full: full)
            }
        }
        var front = cachedImage(id: id, platform: platform, side: .front)
        if front == nil { front = await downloadImage(id: id, platform: platform, side: .front) }
        return HandheldCoverArtSet(front: front, back: localBack ?? cachedImage(id: id, platform: platform, side: .back))
    }

    /// A wrap scan is much wider than one face: at least 75 % of the sheet's aspect (DS/3DS ≈ 2.38 → 1.78,
    /// PSP ≈ 1.24 → 0.93), so a front mistaken for a full scan is rejected.
    static func isPlausibleFull(_ image: CGImage, platform: HandheldCasePlatform) -> Bool {
        let layout = HandheldCaseInsertLayout.standard(for: platform)
        guard image.height > 0, layout.height > 0 else { return false }
        return CGFloat(image.width) / CGFloat(image.height) >= 0.75 * layout.totalWidth / layout.height
    }

    static func isUsableDownload(_ data: Data, platform: HandheldCasePlatform, side: HandheldCoverSide) -> Bool {
        guard data.count <= maximumDownloadBytes, let image = HandheldCaseInsert.decodeImage(data),
              image.width >= minimumDownloadSide, image.height >= minimumDownloadSide else { return false }
        return side != .full || isPlausibleFull(image, platform: platform)
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: Production

    @Sendable static func defaultWrite(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Serial → libretro thumbnail name map, e.g. `Bundle.main.url(forResource: "PSP-Boxart-Names", withExtension: "json")`.
    static func loadPSPNames(from url: URL?) -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func live(cacheDirectory: URL, onlineEnabled: Bool, pspNames: [String: String]) -> HandheldCoverResolver {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = downloadTimeout
        config.timeoutIntervalForResource = downloadTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "GameDuo"]
        let session = URLSession(configuration: config)
        return HandheldCoverResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            readData: { try? Data(contentsOf: $0) },
            download: { url in
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw HandheldCoverDownloadError.notHTTP }
                guard http.statusCode == 200 else { throw HandheldCoverDownloadError.httpStatus(http.statusCode) }
                return data
            },
            cacheDirectory: cacheDirectory,
            onlineEnabled: onlineEnabled,
            pspNames: pspNames)
    }
}

// MARK: - Insert sheet

/// Paints the whole insert sheet (back | spine | front seen from outside, image top = case top) that the
/// case's COVER_ART_BACK / COVER_ART_SPINE / COVER_ART share, from whatever art was found:
/// - a wrap scan (`full`): its three panels are mapped piecewise onto the layout's panels;
/// - a front (and optional back): front aspect-filled into the front panel, back = the back image or a
///   generated back, spine = generated (front's dominant colour, platform strip, title);
/// - nothing: a generated placeholder with the platform's banner drawn as plain text.
/// Real scans already carry the platform banner, so banners are only drawn on generated panels.
/// `neutral` (always, see `NeutralBranding`) draws no platform banner, spine strip or platform name at all.
enum HandheldCaseInsert {
    // MARK: Banner geometry (mm, measured on GameTDB scans / RESEARCH.md)

    /// DS: white vertical strip on the front panel's left edge, next to the spine.
    static let ndsBannerWidth: CGFloat = 18
    /// 3DS: white vertical strip at the front panel's far right.
    static let threeDSBannerWidth: CGFloat = 14
    /// PSP: black horizontal bar across the top of the front panel.
    static let pspBannerHeight: CGFloat = 13

    /// Where back|spine and spine|front fall on a GameTDB `coverfullHQ` / `coverfullM` scan, as fractions of
    /// its width (DS 764 / 857 of 1616 px, 3DS 777 / 847 of 1616 px; individual scans vary by ±5 px and are
    /// refined by `detectScanSplits`). PSP has no scan source: local wraps are assumed to match the layout.
    static func nominalScanSplits(for platform: HandheldCasePlatform) -> (CGFloat, CGFloat) {
        switch platform {
        case .nds: (764.0 / 1616, 857.0 / 1616)
        case .threeDS: (777.0 / 1616, 847.0 / 1616)
        case .psp: HandheldCaseInsertLayout.psp.uSplits
        }
    }

    // MARK: Render

    static func render(platform: HandheldCasePlatform, layout: HandheldCaseInsertLayout,
                       full: CGImage?, front: CGImage?, back: CGImage?,
                       title: String, subtitle: String?, pixelsPerMM: CGFloat, neutral: Bool = false) -> CGImage? {
        let width = Int((layout.totalWidth * pixelsPerMM).rounded())
        let height = Int((layout.height * pixelsPerMM).rounded())
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let sheet = Sheet(layout: layout, width: CGFloat(width), height: CGFloat(height))
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (neutral ? "" : platform.displayName) : title

        if let full, HandheldCoverResolver.isPlausibleFull(full, platform: platform) {
            drawFull(full, platform: platform, sheet: sheet, ctx: ctx)
        } else if let front = front ?? full {
            let art = artCrop(ofFront: front, platform: platform, layout: layout)
            let colour = art.flatMap { dominantColor(of: $0) } ?? RGB(r: 0.3, g: 0.3, b: 0.3)
            draw(front, aspectFilledIn: sheet.front, ctx: ctx)
            if let back {
                draw(back, aspectFilledIn: sheet.back, ctx: ctx)
            } else {
                drawGeneratedBack(from: art ?? front, colour: colour, title: name, subtitle: subtitle,
                                  platform: platform, rect: sheet.back, sheet: sheet, ctx: ctx, neutral: neutral)
            }
            drawGeneratedSpine(platform: platform, background: colour, title: name, rect: sheet.spine, sheet: sheet,
                               ctx: ctx, neutral: neutral)
        } else {
            drawPlaceholder(platform: platform, back: back, title: name, subtitle: subtitle, sheet: sheet, ctx: ctx,
                            neutral: neutral)
        }
        return ctx.makeImage()
    }

    /// Panel rectangles in sheet pixels (CG coordinates, origin bottom-left).
    struct Sheet {
        var width: CGFloat, height: CGFloat, mm: CGFloat
        var back: CGRect, spine: CGRect, front: CGRect

        init(layout: HandheldCaseInsertLayout, width: CGFloat, height: CGFloat) {
            self.width = width
            self.height = height
            mm = layout.height > 0 ? height / layout.height : 1
            let (u0, u1) = layout.uSplits
            let x0 = (width * u0).rounded(), x1 = (width * u1).rounded()
            back = CGRect(x: 0, y: 0, width: x0, height: height)
            spine = CGRect(x: x0, y: 0, width: x1 - x0, height: height)
            front = CGRect(x: x1, y: 0, width: width - x1, height: height)
        }
    }

    // MARK: Full scan

    /// The scan's panel boundaries in its own pixels: the nominal splits, each moved to the strongest
    /// vertical colour edge within ±0.6 % of the width when there is a clear one.
    static func scanSplits(for image: CGImage, platform: HandheldCasePlatform) -> (CGFloat, CGFloat) {
        detectScanSplits(image, nominal: nominalScanSplits(for: platform))
    }

    static func detectScanSplits(_ image: CGImage, nominal: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
        let w = image.width
        let fallback = (nominal.0 * CGFloat(w), nominal.1 * CGFloat(w))
        guard w >= 64, image.height >= 8 else { return fallback }
        let rows = 48
        guard let columns = columnMeans(of: image, rows: rows) else { return fallback }
        func refine(_ x: CGFloat) -> CGFloat {
            let window = max(3, Int((CGFloat(w) * 0.006).rounded()))
            let centre = Int(x.rounded())
            let lo = max(1, centre - window), hi = min(w - 2, centre + window)
            guard lo < hi else { return x }
            var best = lo, bestValue = -1.0
            var values: [Double] = []
            for i in lo...hi {
                let a = columns[i - 1], b = columns[i + 1]
                let g = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                values.append(g)
                if g > bestValue { bestValue = g; best = i }
            }
            let median = values.sorted()[values.count / 2]
            // Clear edge: strong in absolute terms and well above the local texture.
            guard bestValue >= 0.09, bestValue >= median * 3 else { return x }
            return CGFloat(best)
        }
        let a = refine(fallback.0), b = refine(fallback.1)
        return a < b ? (a, b) : fallback
    }

    /// Mean colour (0…1) of each pixel column.
    private static func columnMeans(of image: CGImage, rows: Int) -> [RGB]? {
        let w = image.width
        var pixels = [UInt8](repeating: 0, count: w * rows * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buffer.baseAddress, width: w, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: rows))
            return true
        }
        guard drawn else { return nil }
        var out = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: w)
        for x in 0..<w {
            var r = 0, g = 0, b = 0
            for y in 0..<rows {
                let i = (y * w + x) * 4
                r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
            }
            let n = Double(rows * 255)
            out[x] = RGB(r: Double(r) / n, g: Double(g) / n, b: Double(b) / n)
        }
        return out
    }

    private static func drawFull(_ image: CGImage, platform: HandheldCasePlatform, sheet: Sheet, ctx: CGContext) {
        let (s0, s1) = scanSplits(for: image, platform: platform)
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let pieces: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: s0, height: ih), sheet.back),
            (CGRect(x: s0, y: 0, width: s1 - s0, height: ih), sheet.spine),
            (CGRect(x: s1, y: 0, width: iw - s1, height: ih), sheet.front),
        ]
        for (source, target) in pieces {
            let crop = source.integral.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
            guard crop.width >= 1, crop.height >= 1, let piece = image.cropping(to: crop) else { continue }
            ctx.draw(piece, in: target)
        }
    }

    /// The back panel of a wrap scan (for `HandheldCoverSide.back`).
    static func croppedBack(ofFull image: CGImage, platform: HandheldCasePlatform) -> CGImage? {
        guard HandheldCoverResolver.isPlausibleFull(image, platform: platform) else { return nil }
        let (s0, _) = scanSplits(for: image, platform: platform)
        return image.cropping(to: CGRect(x: 0, y: 0, width: s0.rounded(.down), height: CGFloat(image.height)))
    }

    /// The front panel of a wrap scan.
    static func croppedFront(ofFull image: CGImage, platform: HandheldCasePlatform) -> CGImage? {
        guard HandheldCoverResolver.isPlausibleFull(image, platform: platform) else { return nil }
        let (_, s1) = scanSplits(for: image, platform: platform)
        let x = s1.rounded(.up)
        return image.cropping(to: CGRect(x: x, y: 0, width: CGFloat(image.width) - x, height: CGFloat(image.height)))
    }

    // MARK: Front + back

    /// Centred aspect-fill crop of `imageSize` to `aspect` (width / height), in pixel units.
    static func aspectFillCrop(imageSize: CGSize, aspect: CGFloat) -> CGRect {
        let w = imageSize.width, h = imageSize.height
        guard w > 0, h > 0, aspect > 0 else { return .zero }
        if w / h > aspect {
            let cw = min(w, (h * aspect).rounded())
            return CGRect(x: ((w - cw) / 2).rounded(.down), y: 0, width: cw, height: h)
        } else {
            let ch = min(h, (w / aspect).rounded())
            return CGRect(x: 0, y: ((h - ch) / 2).rounded(.down), width: w, height: ch)
        }
    }

    private static func draw(_ image: CGImage, aspectFilledIn rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let crop = aspectFillCrop(imageSize: CGSize(width: image.width, height: image.height), aspect: rect.width / rect.height)
        guard let cropped = image.cropping(to: crop) else { return }
        ctx.draw(cropped, in: rect)
    }

    /// The front's artwork without the printed platform banner (for colour sampling and the generated back).
    static func artCrop(ofFront image: CGImage, platform: HandheldCasePlatform, layout: HandheldCaseInsertLayout) -> CGImage? {
        let crop = aspectFillCrop(imageSize: CGSize(width: image.width, height: image.height), aspect: layout.frontAspect)
        guard crop.width > 4, crop.height > 4 else { return nil }
        let pxPerMM = crop.height / layout.height
        var art = crop
        switch platform {
        case .nds:
            let cut = min(crop.width * 0.5, ndsBannerWidth * pxPerMM)
            art = CGRect(x: crop.minX + cut, y: crop.minY, width: crop.width - cut, height: crop.height)
        case .threeDS:
            let cut = min(crop.width * 0.5, threeDSBannerWidth * pxPerMM)
            art = CGRect(x: crop.minX, y: crop.minY, width: crop.width - cut, height: crop.height)
        case .psp:
            let cut = min(crop.height * 0.5, pspBannerHeight * pxPerMM)  // image rows run top-down
            art = CGRect(x: crop.minX, y: crop.minY + cut, width: crop.width, height: crop.height - cut)
        }
        return image.cropping(to: art.integral)
    }

    /// Back panel for a game with only a front: its dominant colour, darkened, under a faint blurred mirror
    /// of the artwork, with the title and the platform name.
    private static func drawGeneratedBack(from art: CGImage, colour: RGB, title: String, subtitle: String?,
                                          platform: HandheldCasePlatform, rect: CGRect, sheet: Sheet, ctx: CGContext,
                                          neutral: Bool = false) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(RGB(r: colour.r * 0.6, g: colour.g * 0.6, b: colour.b * 0.6).cgColor)
        ctx.fill(rect)
        // Blur: a tiny copy scaled back up in steps (each bilinear), drawn mirrored.
        if let tiny = downsample(art, width: 8, height: 7).flatMap({ downsample($0, width: 24, height: 21) })
            .flatMap({ downsample($0, width: 72, height: 63) }).flatMap({ downsample($0, width: 216, height: 189) }) {
            ctx.interpolationQuality = .high
            ctx.saveGState()
            ctx.translateBy(x: rect.maxX + rect.minX, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.setAlpha(0.4)
            ctx.draw(tiny, in: rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08))
            ctx.restoreGState()
        }
        // Darken towards the bottom so the text reads.
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1),
                                              CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        ctx.restoreGState()

        let mm = sheet.mm
        let margin = 8 * mm
        let top = rect.maxY - margin - (platform == .psp && !neutral ? pspBannerHeight * mm : 0)
        let box = CGRect(x: rect.minX + margin, y: rect.minY + rect.height * 0.35,
                         width: rect.width - margin * 2, height: top - (rect.minY + rect.height * 0.35))
        let used = TextDrawer.fit(title, in: box, sizes: stride(from: 11 * mm, through: 5 * mm, by: -0.5 * mm),
                                  weight: .heavy, colour: .white, maxLines: 3, ctx: ctx)
        if let subtitle, !subtitle.isEmpty {
            let sub = CGRect(x: box.minX, y: used.minY - 8 * mm, width: box.width, height: 6 * mm)
            _ = TextDrawer.draw(subtitle, in: sub, size: 4.2 * mm, weight: .semibold, colour: RGB.white.with(alpha: 0.75),
                                ctx: ctx, maxLines: 1, commit: true, truncate: true)
        }
        guard !neutral else { return }
        let footer = CGRect(x: rect.minX + margin, y: rect.minY + margin, width: rect.width - margin * 2, height: 6 * mm)
        _ = TextDrawer.draw(platform.fullName.uppercased(), in: footer, size: 3.6 * mm, weight: .bold,
                            colour: RGB.white.with(alpha: 0.6), ctx: ctx, maxLines: 1, commit: true, truncate: true)
    }

    private static func downsample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Spine: flat colour, the platform strip at the top, and the title reading top to bottom.
    private static func drawGeneratedSpine(platform: HandheldCasePlatform, background: RGB, title: String,
                                           rect: CGRect, sheet: Sheet, ctx: CGContext, neutral: Bool = false) {
        guard rect.width > 0 else { return }
        ctx.setFillColor(background.cgColor)
        ctx.fill(rect)
        let stripBottom = neutral ? rect.maxY : drawSpineStrip(platform: platform, rect: rect, sheet: sheet, ctx: ctx)
        let ink: RGB = background.luminance > 0.62 ? RGB(r: 0.12, g: 0.12, b: 0.12) : .white
        drawSpineTitle(title, rect: rect, top: stripBottom - 4 * sheet.mm, bottom: rect.minY + 5 * sheet.mm,
                       colour: ink, ctx: ctx)
    }

    /// The platform strip at the top of the spine; returns its lower edge. DS / 3DS: a white block over the
    /// top quarter with "NINTENDO DS" / "NINTENDO 3DS" reading top to bottom (as on US spines); PSP: a black
    /// block level with the front's top bar and "PSP".
    private static func drawSpineStrip(platform: HandheldCasePlatform, rect: CGRect, sheet: Sheet, ctx: CGContext) -> CGFloat {
        switch platform {
        case .nds, .threeDS:
            let strip = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.27, width: rect.width, height: rect.height * 0.27)
            ctx.setFillColor(RGB.white.cgColor)
            ctx.fill(strip)
            ctx.saveGState()
            ctx.translateBy(x: strip.midX, y: strip.midY)
            ctx.rotate(by: -.pi / 2)
            TextDrawer.drawWordmark(small: "NINTENDO", large: platform == .nds ? "DS" : "3DS",
                                    smallSize: rect.width * 0.2, largeSize: rect.width * 0.42,
                                    colour: .ndsGrey, largeColour: platform == .nds ? .ndsGrey : .threeDSRed,
                                    maxLength: strip.height * 0.86, ctx: ctx)
            ctx.restoreGState()
            return strip.minY
        case .psp:
            let height = min(rect.height * 0.3, pspBannerHeight * sheet.mm)
            let strip = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
            ctx.setFillColor(RGB.black.cgColor)
            ctx.fill(strip)
            TextDrawer.drawCentred("PSP", in: strip.insetBy(dx: rect.width * 0.1, dy: 0), size: min(height * 0.5, rect.width * 0.3),
                                   weight: .heavy, colour: .white, italic: true, ctx: ctx)
            return strip.minY
        }
    }

    private static func drawSpineTitle(_ title: String, rect: CGRect, top: CGFloat, bottom: CGFloat, colour: RGB, ctx: CGContext) {
        guard top > bottom else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: top)
        ctx.rotate(by: -.pi / 2)  // text runs top to bottom
        let box = CGRect(x: 0, y: -rect.width * 0.5, width: top - bottom, height: rect.width)
        // Largest size down to 30 % of the spine width that fits on one line; truncated below that.
        var size = rect.width * 0.46
        while size > rect.width * 0.3,
              TextDrawer.draw(title, in: box, size: size, weight: .bold, colour: colour, ctx: ctx, maxLines: 1,
                              commit: false, verticallyCentred: true) == nil {
            size -= rect.width * 0.02
        }
        _ = TextDrawer.draw(title, in: box, size: size, weight: .bold, colour: colour, ctx: ctx,
                            maxLines: 1, commit: true, truncate: true, verticallyCentred: true)
        ctx.restoreGState()
    }

    // MARK: Placeholder

    /// Deterministic hue in 0..<1 for `title` (FNV-1a), so a game keeps its colour across launches.
    static func hue(for title: String) -> CGFloat {
        var hash: UInt32 = 2_166_136_261
        for byte in title.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return CGFloat(hash % 360) / 360
    }

    /// The front panel's area outside the platform banner.
    static func frontArtRect(platform: HandheldCasePlatform, front: CGRect, mm: CGFloat) -> CGRect {
        switch platform {
        case .nds:
            let b = min(front.width * 0.4, ndsBannerWidth * mm)
            return CGRect(x: front.minX + b, y: front.minY, width: front.width - b, height: front.height)
        case .threeDS:
            let b = min(front.width * 0.4, threeDSBannerWidth * mm)
            return CGRect(x: front.minX, y: front.minY, width: front.width - b, height: front.height)
        case .psp:
            let b = min(front.height * 0.3, pspBannerHeight * mm)
            return CGRect(x: front.minX, y: front.minY, width: front.width, height: front.height - b)
        }
    }

    /// The printed banner strip on the front panel (sheet pixels).
    static func frontBannerRect(platform: HandheldCasePlatform, front: CGRect, mm: CGFloat) -> CGRect {
        let art = frontArtRect(platform: platform, front: front, mm: mm)
        switch platform {
        case .nds: return CGRect(x: front.minX, y: front.minY, width: art.minX - front.minX, height: front.height)
        case .threeDS: return CGRect(x: art.maxX, y: front.minY, width: front.maxX - art.maxX, height: front.height)
        case .psp: return CGRect(x: front.minX, y: art.maxY, width: front.width, height: front.maxY - art.maxY)
        }
    }

    private static func drawPlaceholder(platform: HandheldCasePlatform, back: CGImage?, title: String, subtitle: String?,
                                        sheet: Sheet, ctx: CGContext, neutral: Bool = false) {
        let mm = sheet.mm
        let hue = hue(for: title)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let top = RGB(hue: hue, saturation: 0.62, brightness: 0.5)
        let bottom = RGB(hue: hue + 0.05, saturation: 0.78, brightness: 0.14)
        if let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: sheet.height), end: .zero, options: [])
        }
        // Neutral: no banner, the artwork takes the whole front.
        let art = neutral ? sheet.front : frontArtRect(platform: platform, front: sheet.front, mm: mm)

        // Motif: faint outlines of the medium (game card / UMD) off the lower right of each face.
        ctx.saveGState()
        ctx.clip(to: art)
        drawMotif(platform: platform, anchor: CGPoint(x: art.maxX - art.width * 0.1, y: art.minY + art.height * 0.18),
                  scale: art.height, ctx: ctx)
        ctx.restoreGState()
        if back == nil {
            ctx.saveGState()
            ctx.clip(to: sheet.back)
            drawMotif(platform: platform, anchor: CGPoint(x: sheet.back.minX + sheet.back.width * 0.15,
                                                          y: sheet.back.minY + sheet.back.height * 0.2),
                      scale: sheet.back.height * 0.8, ctx: ctx)
            ctx.restoreGState()
        }

        // Front title: the largest size (up to four lines) that fits the upper part of the art area.
        let margin = min(art.width, art.height) * 0.08
        let accentY = art.maxY - margin
        ctx.setFillColor(RGB(hue: hue + 0.5, saturation: 0.55, brightness: 0.95).with(alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: art.minX + margin, y: accentY - max(3, 0.8 * mm), width: art.width * 0.16, height: max(3, 0.8 * mm)))
        let titleBox = CGRect(x: art.minX + margin, y: art.minY + art.height * 0.3,
                              width: art.width - margin * 2, height: accentY - 5 * mm - (art.minY + art.height * 0.3))
        let largest = platform == .psp ? 16 * mm : 14 * mm
        let used = TextDrawer.fit(title, in: titleBox, sizes: stride(from: largest, through: 5 * mm, by: -0.5 * mm),
                                  weight: .heavy, colour: .white, maxLines: 4, ctx: ctx)
        if let subtitle, !subtitle.isEmpty {
            let box = CGRect(x: titleBox.minX, y: used.minY - 9 * mm, width: titleBox.width, height: 6.5 * mm)
            _ = TextDrawer.draw(subtitle, in: box, size: 4.5 * mm, weight: .semibold, colour: RGB.white.with(alpha: 0.72),
                                ctx: ctx, maxLines: 1, commit: true, truncate: true)
        }

        // Back: a real back image if there is one, else the title again, smaller.
        if let back {
            draw(back, aspectFilledIn: sheet.back, ctx: ctx)
        } else {
            let bm = 8 * mm
            let backTop = sheet.back.maxY - bm - (platform == .psp && !neutral ? pspBannerHeight * mm : 0)
            let box = CGRect(x: sheet.back.minX + bm, y: sheet.back.minY + sheet.back.height * 0.45,
                             width: sheet.back.width - bm * 2, height: backTop - (sheet.back.minY + sheet.back.height * 0.45))
            _ = TextDrawer.fit(title, in: box, sizes: stride(from: 8 * mm, through: 4 * mm, by: -0.5 * mm),
                               weight: .bold, colour: RGB.white.with(alpha: 0.9), maxLines: 3, ctx: ctx)
            if !neutral {
                let footer = CGRect(x: sheet.back.minX + bm, y: sheet.back.minY + bm, width: sheet.back.width - bm * 2, height: 6 * mm)
                _ = TextDrawer.draw(platform.fullName.uppercased(), in: footer, size: 3.6 * mm, weight: .bold,
                                    colour: RGB.white.with(alpha: 0.55), ctx: ctx, maxLines: 1, commit: true, truncate: true)
            }
        }

        // Spine: platform strip on top (not when neutral), title reading top to bottom.
        let stripBottom = neutral ? sheet.spine.maxY : drawSpineStrip(platform: platform, rect: sheet.spine, sheet: sheet, ctx: ctx)
        drawSpineTitle(title, rect: sheet.spine, top: stripBottom - 4 * mm, bottom: sheet.spine.minY + 5 * mm,
                       colour: .white, ctx: ctx)

        if !neutral { drawFrontBanner(platform: platform, sheet: sheet, ctx: ctx) }
    }

    /// The platform banner of a US insert, as plain type (not the trademarked logos).
    private static func drawFrontBanner(platform: HandheldCasePlatform, sheet: Sheet, ctx: CGContext) {
        let banner = frontBannerRect(platform: platform, front: sheet.front, mm: sheet.mm)
        guard banner.width > 0, banner.height > 0 else { return }
        switch platform {
        case .nds, .threeDS:
            ctx.setFillColor(RGB.white.cgColor)
            ctx.fill(banner)
            let ink: RGB = platform == .nds ? .ndsGrey : .threeDSRed
            let mark = platform == .nds ? "DS" : "3DS"
            // Reads bottom to top: rotate the text frame a quarter turn anticlockwise.
            ctx.saveGState()
            ctx.translateBy(x: banner.midX, y: banner.midY)
            ctx.rotate(by: .pi / 2)
            let across = banner.width
            TextDrawer.drawWordmark(small: "NINTENDO", large: mark, smallSize: across * 0.3, largeSize: across * 0.62,
                                    colour: ink, largeColour: ink, maxLength: banner.height * 0.9, ctx: ctx)
            ctx.restoreGState()
        case .psp:
            ctx.setFillColor(RGB.black.cgColor)
            ctx.fill(banner)
            let box = CGRect(x: banner.minX + 5 * sheet.mm, y: banner.minY, width: banner.width * 0.5, height: banner.height)
            TextDrawer.drawCentred("PSP", in: box, size: banner.height * 0.62, weight: .heavy, colour: .white,
                                   italic: true, alignLeft: true, ctx: ctx)
        }
    }

    private static func drawMotif(platform: HandheldCasePlatform, anchor: CGPoint, scale: CGFloat, ctx: CGContext) {
        ctx.setStrokeColor(RGB.white.with(alpha: 0.08).cgColor)
        switch platform {
        case .nds, .threeDS:
            // Stacked game-card outlines (35 × 33 mm, notched corner), rotated a little.
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: -0.18)
            for i in 0..<5 {
                let s = scale * (0.5 + CGFloat(i) * 0.16)
                let w = s * 0.94, h = s
                let path = CGMutablePath()
                let r = s * 0.05, notch = s * 0.12
                path.move(to: CGPoint(x: -w / 2 + r, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2 - r, y: -h / 2))
                path.addQuadCurve(to: CGPoint(x: w / 2, y: -h / 2 + r), control: CGPoint(x: w / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: h / 2 - notch))
                path.addLine(to: CGPoint(x: w / 2 - notch, y: h / 2))
                path.addLine(to: CGPoint(x: -w / 2 + r, y: h / 2))
                path.addQuadCurve(to: CGPoint(x: -w / 2, y: h / 2 - r), control: CGPoint(x: -w / 2, y: h / 2))
                path.addLine(to: CGPoint(x: -w / 2, y: -h / 2 + r))
                path.addQuadCurve(to: CGPoint(x: -w / 2 + r, y: -h / 2), control: CGPoint(x: -w / 2, y: -h / 2))
                ctx.setLineWidth(i % 2 == 0 ? scale * 0.012 : scale * 0.005)
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .psp:
            var radius = scale * 0.12
            var index = 0
            while radius < scale * 0.75 {
                ctx.setLineWidth(index % 3 == 0 ? scale * 0.01 : scale * 0.004)
                ctx.strokeEllipse(in: CGRect(x: anchor.x - radius, y: anchor.y - radius, width: radius * 2, height: radius * 2))
                radius += scale * 0.04
                index += 1
            }
        }
    }

    // MARK: Image helpers

    static func decodeImage(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func encodeJPEG(_ image: CGImage) -> Data? {
        encode(image, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        encode(image, type: "public.png", options: [:])
    }

    private static func encode(_ image: CGImage, type: String, options: [CFString: Any]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Most common colour of `image`, favouring saturated colours (a bucket scores count × (0.1 + chroma)²), so a
    /// red cap beats a much larger light-grey background; near-black and near-white pixels are ignored unless they
    /// make up more than 90 % of it.
    static func dominantColor(of image: CGImage) -> RGB {
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
        let fallback = RGB(r: 0.5, g: 0.5, b: 0.5)
        guard drawn else { return fallback }
        var colourful = [Int: ColourBucket](), extreme = [Int: ColourBucket]()
        var colourfulCount = 0, extremeCount = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a >= 128 else { continue }
            let r = min(255, Int(pixels[i]) * 255 / a)
            let g = min(255, Int(pixels[i + 1]) * 255 / a)
            let b = min(255, Int(pixels[i + 2]) * 255 / a)
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            if max(r, g, b) < 28 || min(r, g, b) > 228 {
                extreme[key, default: ColourBucket()].add(r, g, b); extremeCount += 1
            } else {
                colourful[key, default: ColourBucket()].add(r, g, b); colourfulCount += 1
            }
        }
        let total = colourfulCount + extremeCount
        guard total > 0 else { return fallback }
        var histogram = colourful
        if colourfulCount * 10 < total {
            histogram.merge(extreme) { a, b in ColourBucket(count: a.count + b.count, r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
        }
        guard let top = histogram.values.max(by: { $0.score < $1.score }), top.count > 0 else { return fallback }
        let n = Double(top.count) * 255
        return RGB(r: Double(top.r) / n, g: Double(top.g) / n, b: Double(top.b) / n)
    }

    /// sRGB colour, 0…1.
    struct RGB: Sendable, Equatable {
        var r: Double, g: Double, b: Double, a: Double = 1

        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)
        static let ndsGrey = RGB(r: 0.3, g: 0.3, b: 0.32)
        static let threeDSRed = RGB(r: 0.84, g: 0.05, b: 0.1)

        init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(hue: CGFloat, saturation s: CGFloat, brightness v: CGFloat) {
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
            self.init(r: Double(r + m), g: Double(g + m), b: Double(b + m))
        }

        func with(alpha: Double) -> RGB { RGB(r: r, g: g, b: b, a: alpha) }
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }
}

extension HandheldCasePlatform {
    var displayName: String {
        switch self {
        case .nds: "DS"
        case .threeDS: "3DS"
        case .psp: "PSP"
        }
    }

    var fullName: String {
        switch self {
        case .nds: "Nintendo DS"
        case .threeDS: "Nintendo 3DS"
        case .psp: "PSP"
        }
    }
}

private struct ColourBucket {
    var count = 0, r = 0, g = 0, b = 0

    mutating func add(_ r: Int, _ g: Int, _ b: Int) {
        count += 1; self.r += r; self.g += g; self.b += b
    }

    var score: Double {
        guard count > 0 else { return 0 }
        let n = Double(count)
        let chroma = (max(Double(r), Double(g), Double(b)) - min(Double(r), Double(g), Double(b))) / n / 255
        return n * (0.1 + chroma) * (0.1 + chroma)
    }
}

// MARK: - Text

private enum TextDrawer {
    enum Weight {
        case semibold, bold, heavy

        var trait: CGFloat {
            switch self {
            case .semibold: 0.3
            case .bold: 0.4
            case .heavy: 0.56
            }
        }
    }

    static func font(size: CGFloat, weight: Weight, italic: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: [CFString: Any] = [kCTFontWeightTrait: weight.trait]
        if italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        if italic, !CTFontGetSymbolicTraits(font).contains(.traitItalic) {
            // No italic face: slant the upright one.
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            return CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(font), size, &skew)
        }
        return font
    }

    static func attributes(_ font: CTFont, _ colour: HandheldCaseInsert.RGB) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour.cgColor,
        ]
    }

    /// Draws `text` at the largest of `sizes` that fits `box` without breaking words; the smallest,
    /// truncated, otherwise. Returns the used rect.
    @discardableResult
    static func fit(_ text: String, in box: CGRect, sizes: StrideThrough<CGFloat>, weight: Weight,
                    colour: HandheldCaseInsert.RGB, maxLines: Int, ctx: CGContext) -> CGRect {
        guard box.width > 1, box.height > 1 else { return CGRect(x: box.minX, y: box.maxY, width: 0, height: 0) }
        var smallest: CGFloat = 0
        for size in sizes {
            smallest = size
            if draw(text, in: box, size: size, weight: weight, colour: colour, ctx: ctx, maxLines: maxLines, commit: false) != nil {
                return draw(text, in: box, size: size, weight: weight, colour: colour, ctx: ctx, maxLines: maxLines, commit: true) ?? box
            }
        }
        return draw(text, in: box, size: smallest, weight: weight, colour: colour, ctx: ctx, maxLines: maxLines,
                    commit: true, truncate: true) ?? box
    }

    /// Draws `text` top-aligned in `box` (CG coordinates). Returns the used rect, or nil when it doesn't
    /// fit in `maxLines` without breaking a word (unless `truncate`, which ellipsises the last line).
    static func draw(_ text: String, in box: CGRect, size: CGFloat, weight: Weight, colour: HandheldCaseInsert.RGB,
                     ctx: CGContext, maxLines: Int, commit: Bool, truncate: Bool = false,
                     verticallyCentred: Bool = false) -> CGRect? {
        guard size > 0, box.width > 0 else { return nil }
        let font = font(size: size, weight: weight)
        let attrs = attributes(font, colour)
        let string = NSAttributedString(string: text, attributes: attrs)
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
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                line = CTLineCreateTruncatedLine(rest, Double(box.width), .end, ellipsis) ?? line
                start = length
            }
            if !truncate, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(box.width) + 0.5 { return nil }
            lines.append(line)
        }
        if start < length && !truncate { return nil }
        if lines.count == 1, truncate, let only = lines.first,
           CTLineGetTypographicBounds(only, nil, nil, nil) > Double(box.width) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            lines[0] = CTLineCreateTruncatedLine(only, Double(box.width), .end, ellipsis) ?? only
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.0
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

    /// One line centred in `box` (or left-aligned), vertically centred on its cap height; shrinks to fit the width.
    static func drawCentred(_ text: String, in box: CGRect, size: CGFloat, weight: Weight, colour: HandheldCaseInsert.RGB,
                            italic: Bool = false, alignLeft: Bool = false, ctx: CGContext) {
        guard size > 0, box.width > 0 else { return }
        var size = size
        var font = font(size: size, weight: weight, italic: italic)
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(font, colour)))
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > box.width {
            size *= box.width / width
            font = self.font(size: size, weight: weight, italic: italic)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(font, colour)))
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let cap = CTFontGetCapHeight(font)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: alignLeft ? box.minX : box.midX - width / 2, y: box.midY - cap / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// "NINTENDO" small + mark large on one baseline, centred on the current origin (x along the text).
    static func drawWordmark(small: String, large: String, smallSize: CGFloat, largeSize: CGFloat,
                             colour: HandheldCaseInsert.RGB, largeColour: HandheldCaseInsert.RGB,
                             maxLength: CGFloat, ctx: CGContext) {
        var scale: CGFloat = 1
        func lines(_ k: CGFloat) -> (CTLine, CTLine, CTFont, CGFloat, CGFloat) {
            let sf = font(size: smallSize * k, weight: .semibold)
            let lf = font(size: largeSize * k, weight: .heavy)
            let s = CTLineCreateWithAttributedString(NSAttributedString(string: small, attributes: attributes(sf, colour)))
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: large, attributes: attributes(lf, largeColour)))
            return (s, l, lf, CGFloat(CTLineGetTypographicBounds(s, nil, nil, nil)), CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)))
        }
        var (s, l, lf, sw, lw) = lines(1)
        let gap = largeSize * 0.12
        if sw + gap + lw > maxLength, sw + gap + lw > 0 {
            scale = maxLength / (sw + gap + lw)
            (s, l, lf, sw, lw) = lines(scale)
        }
        let total = sw + gap * scale + lw
        let baseline = -CTFontGetCapHeight(lf) / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -total / 2, y: baseline)
        CTLineDraw(s, ctx)
        ctx.textPosition = CGPoint(x: -total / 2 + sw + gap * scale, y: baseline)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
}
