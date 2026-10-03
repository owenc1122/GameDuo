import Foundation
import CryptoKit
import SceneKit
import SwiftUI
import UIKit
import CoreImage

enum GamePlatform: String, Codable, Hashable {
    case nds = "Nintendo DS"
    case threeDS = "Nintendo 3DS"

    case n64 = "Nintendo 64"
    case psp = "Sony PSP"
    case ps2 = "Sony PS2"

    /// Library label. The raw value is persisted, so the UI never shows it (no maker names).
    var displayName: String {
        switch self {
        case .nds: "DS"
        case .threeDS: "3DS"
        case .n64: "N64"
        case .psp: "PSP"
        case .ps2: "PS2"
        }
    }
    static let ndsROMExtensions = ROMFiles.nds
    static let threeDSROMExtensions = ROMFiles.threeDS
    static let threeDSInstallableExtensions = ROMFiles.packages

    static func resolve(fileExtension: String) -> GamePlatform? {
        let ext = fileExtension.lowercased()
        if ROMFiles.n64.contains(ext) { return .n64 }
        if ROMFiles.psp.contains(ext) { return .psp }
        if ndsROMExtensions.contains(ext) { return .nds }
        if threeDSROMExtensions.contains(ext) { return .threeDS }
        return nil
    }

    /// Like `resolve(fileExtension:)`, but `.iso/.cso/.chd/.bin/.cue` are told apart by content:
    /// `SYSTEM.CNF` → PS2, `PSP_GAME/PARAM.SFO` → PSP. Unrecognised ISO/CSO/CHD stay PSP (the pre-PS2
    /// behaviour); unrecognised BIN/CUE are not games.
    static func resolve(url: URL) -> GamePlatform? {
        let ext = url.pathExtension.lowercased()
        guard ROMFiles.discImages.contains(ext) else { return resolve(fileExtension: ext) }
        switch ROMFiles.ps2DiscKind(url) {
        case .ps2: return .ps2
        case .psp: return .psp
        case .unknown: return ROMFiles.psp.contains(ext) ? .psp : nil
        }
    }

    static func isInstallablePackage(fileExtension: String) -> Bool {
        threeDSInstallableExtensions.contains(fileExtension.lowercased())
    }
}

enum GameCardKind {
    case ndsStandard
    case ndsInfrared
    case dsiEnhanced
    case dsiExclusive
    case threeDS
    case umd
    case ps2Case

    var modelNodeName: String {
        switch self {
        case .ndsStandard: return "ndsStandard"
        case .ndsInfrared: return "ndsInfrared"
        case .dsiEnhanced: return "dsiEnhanced"
        case .dsiExclusive: return "dsiExclusive"
        case .threeDS: return "threeDS"
        case .umd: return "umd"
        case .ps2Case: return "ps2Case"
        }
    }

    static func fallback(for platform: GamePlatform, fileExtension: String) -> GameCardKind {
        if platform == .nds { return .ndsStandard }
        if platform == .psp { return .umd }
        if platform == .ps2 { return .ps2Case }
        return .threeDS
    }
}

enum CartridgeShellColor: String, Codable, CaseIterable, Identifiable {
    case dsGray, infraredBlack, threeDSWhite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dsGray: String(localized: "DS 深灰")
        case .infraredBlack: String(localized: "红外卡带黑")
        case .threeDSWhite: String(localized: "3DS 浅灰白")
        }
    }
    var uiColor: UIColor {
        switch self {
        case .dsGray: UIColor(white: 0.20, alpha: 1)
        case .infraredBlack: UIColor(red: 0.085, green: 0.09, blue: 0.085, alpha: 1)
        case .threeDSWhite: UIColor(white: 0.84, alpha: 1)
        }
    }
}

struct HandheldCaseArt {
    var full: UIImage?
    var front: UIImage?
    var back: UIImage?
}

struct GameLibraryItem: Identifiable {
    let url: URL
    let title: String
    let detail: String
    let platform: GamePlatform
    let cartridgeKind: GameCardKind
    var icon: UIImage?
    /// PS2 only: the back of the case insert (`PS2CoverResolver` `.back`), when one was found.
    var backCover: UIImage? = nil
    /// DS / 3DS / PSP retail-case insert art (`HandheldCoverResolver.resolveInsert`): a whole
    /// back | spine | front scan, or the box front (and back) alone. Separate from `icon`, which
    /// stays the cartridge / UMD label.
    var caseArt: HandheldCaseArt? = nil
    let isBundledTest: Bool
    let programID: UInt64?
    let productID: String?
    var engraving: String? = nil
    var shellColor: CartridgeShellColor? = nil
    var appearanceRevision = UUID()

    var id: String { url.standardizedFileURL.path }

    var canBeDeleted: Bool { true }
    var isInstalledTitle: Bool { url.path.contains("/Azahar/sdmc/") }
    var isBundledMK64Port: Bool { isBundledTest && url.lastPathComponent == "MK64-3DS.3dsx" }
}

enum PS2LibrarySettings {
    /// Missing covers are always downloaded by serial (front: xlenore/ps2-covers; back: OPL art
    /// database; DS / 3DS / PSP box art too); there is no setting for it. Owner requirement:
    /// online box art stays. Only the brand prints of our own models are neutral (`NeutralBranding`).
    static let onlineCoversEnabled = true
}

/// Retail cases in the library, all platforms (`UserDefaults.standard`; bind with
/// `@AppStorage(HandheldCaseSettings.hideCasesKey) var hideCases = false`).
enum HandheldCaseSettings {
    /// Bool, default false: show the bare cartridge / UMD / PS2 disc instead of its retail case.
    static let hideCasesKey = "hideHandheldCases"

    static var casesHidden: Bool { UserDefaults.standard.bool(forKey: hideCasesKey) }
}

struct GameSaveInfo: Identifiable {
    let game: GameLibraryItem
    let location: URL?
    let metadataLocation: URL?
    var additionalLocations: [URL] = []
    let byteCount: Int64
    let modifiedAt: Date?

    var id: String { game.id }
    var exists: Bool { location != nil || metadataLocation != nil || !additionalLocations.isEmpty }
}

@MainActor
final class GameLibraryStore: ObservableObject {
    @Published private(set) var games: [GameLibraryItem] = []
    @Published var selectedID: GameLibraryItem.ID?
    @Published var importError: String?
    @Published private(set) var isImporting = false
    @Published var importMessage: String?

    private let fileManager = FileManager.default
    private static let hiddenBundledGamesKey = "hiddenBundledGameFilenames.v1"

    var hasHiddenBundledGames: Bool { !hiddenBundledGameFilenames.isEmpty }

    private var hiddenBundledGameFilenames: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.hiddenBundledGamesKey) ?? [])
    }

    private struct PreservedSaveRecord: Codable {
        let key: String
        let title: String
        let originalPath: String
        let platform: GamePlatform
        let programID: UInt64?
        let productID: String?
    }

    private struct ImportResult: Sendable {
        let paths: [String]
        let message: String
        let launchBundledMK64: Bool
    }

    init() {
        reload()
        #if DEBUG
        // `-import-path <file>`: import a ROM or archive at launch, as the Files picker would.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-import-path"), arguments.indices.contains(index + 1) {
            let source = URL(fileURLWithPath: arguments[index + 1])
            Task { [weak self] in
                let game = await self?.importGame(from: source)
                print("DUO_IMPORT", game?.title ?? "nil", game?.productID ?? "-", self?.importMessage ?? self?.importError ?? "")
                fflush(stdout)
            }
        }
        #endif
    }

    func originalCover(for game: GameLibraryItem) -> UIImage? {
        if game.platform == .ps2 { return ps2Covers[game.id] }
        return ROMMetadataReader.read(from: game.url, platform: game.platform).icon
    }

    func reload() {
        var urls: [(URL, Bool)] = []
        let hiddenBundledGames = hiddenBundledGameFilenames
        if let directory = try? romDirectory() {
            upgradeKnownBuggyTrailMix(in: directory)
        }
        if let directory = try? romDirectory(),
           let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            urls += enumerator.allObjects.compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.map { ($0, false) }
        }
        let support = ROMFiles.supportDirectory()
        let manifestURL = support.appendingPathComponent("InstalledTitles.json")
        let manifest = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: manifestURL))) ?? [:]
        let installedNames = Dictionary(manifest.values.compactMap { entry -> (String, String)? in
            guard let path = entry["path"], let title = entry["title"] else { return nil }
            let url = support.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            urls.append((url, false))
            return (url.path, title)
        }, uniquingKeysWith: { first, _ in first })

        if let mars = Bundle.main.url(forResource: "Mars3D", withExtension: "3dsx"),
           !hiddenBundledGames.contains(mars.lastPathComponent) {
            urls.append((mars, true))
        }
        if let nds = Bundle.main.url(forResource: "FuzedNeo", withExtension: "nds"),
           !hiddenBundledGames.contains(nds.lastPathComponent) {
            urls.append((nds, true))
        }
        if let trailMix = Bundle.main.url(forResource: "TrailMix", withExtension: "nds"),
           !hiddenBundledGames.contains(trailMix.lastPathComponent) {
            urls.append((trailMix, true))
        }
        if let mk64 = Bundle.main.url(forResource: "MK64-3DS", withExtension: "3dsx"),
           !hiddenBundledGames.contains(mk64.lastPathComponent) {
            urls.append((mk64, true))
        }

        // A cue sheet stands for its BIN tracks; list only the cue.
        let cueTracks = Set(urls.filter { $0.0.pathExtension.lowercased() == "cue" }
            .flatMap { ROMFiles.cueReferencedFiles($0.0) }.map { $0.standardizedFileURL.path })
        games = urls.compactMap { url, bundled -> GameLibraryItem? in
            guard !cueTracks.contains(url.standardizedFileURL.path),
                  let platform = GamePlatform.resolve(url: url) else { return nil }
            let metadata = ROMMetadataReader.read(from: url, platform: platform)
            let pro = DuoProStore.shared.preferences(for: url)
            return GameLibraryItem(
                url: url,
                title: pro.customTitle.isEmpty ? (metadata.title ?? installedNames[url.path] ?? url.deletingPathExtension().lastPathComponent) : pro.customTitle,
                detail: bundled ? String(localized: "开源测试游戏") : (metadata.detail ?? url.pathExtension.uppercased()),
                platform: platform,
                cartridgeKind: metadata.cartridgeKind ?? .fallback(for: platform, fileExtension: url.pathExtension),
                icon: DuoProStore.shared.cover(for: url) ?? metadata.icon
                    ?? (platform == .ps2 ? ps2Covers[url.standardizedFileURL.path] : nil),
                isBundledTest: bundled,
                programID: metadata.programID,
                productID: metadata.productID,
                engraving: pro.cartridgeEngraving,
                shellColor: pro.cartridgeColor
            )
        }
        .map { game -> GameLibraryItem in
            var game = game
            game.backCover = ps2BackCovers[game.id]
            game.caseArt = handheldCaseArt[game.id]
            return game
        }
        .sorted { lhs, rhs in
            let lhsFavorite = DuoProStore.shared.preferences(for: lhs.url).favorite
            let rhsFavorite = DuoProStore.shared.preferences(for: rhs.url).favorite
            if lhsFavorite != rhsFavorite { return lhsFavorite }
            if lhs.isBundledTest != rhs.isBundledTest { return !lhs.isBundledTest }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-store-review") {
            games = games.filter { ["TrailMix.nds", "Mars3D.3dsx"].contains($0.url.lastPathComponent) }
        }
        #endif
        if selectedID == nil || !games.contains(where: { $0.id == selectedID }) {
            selectedID = games.first?.id
        }
        requestPS2Covers()
        requestHandheldCaseArt()
    }

    // MARK: PS2 covers

    /// Resolved covers (front and back) by game id, kept for the session so reloads don't hit the disk or network again.
    private var ps2Covers: [String: UIImage] = [:]
    private var ps2BackCovers: [String: UIImage] = [:]
    /// Game id → whether online lookup was enabled for the attempt. A miss with online enabled is final
    /// for this launch; a miss while it was disabled is retried once the setting is turned on.
    private var ps2CoverAttempts: [String: Bool] = [:]

    nonisolated static var ps2CoverDirectory: URL {
        ROMFiles.supportDirectory().appendingPathComponent("PS2/Covers", isDirectory: true)
    }

    /// Looks up the missing front and back covers of PS2 games off the main thread; each result
    /// refreshes its card.
    private func requestPS2Covers() {
        let online = PS2LibrarySettings.onlineCoversEnabled
        let pending = games.filter { game in
            guard game.platform == .ps2, game.icon == nil || game.backCover == nil else { return false }
            guard let attempt = ps2CoverAttempts[game.id] else { return true }
            return !attempt && online
        }
        guard !pending.isEmpty else { return }
        let resolver = PS2CoverResolver.live(cacheDirectory: Self.ps2CoverDirectory, onlineEnabled: online)
        for game in pending {
            ps2CoverAttempts[game.id] = online
            let id = game.id, url = game.url, serial = game.productID
            let needsFront = game.icon == nil, needsBack = game.backCover == nil
            Task { [weak self] in
                let (front, back) = await Task.detached(priority: .utility) { () -> (Data?, Data?) in
                    let single = Self.directoryHasSingleGame(url)
                    async let front = needsFront
                        ? resolver.resolve(romURL: url, serial: serial, directoryHasSingleGame: single) : nil
                    async let back = needsBack
                        ? resolver.resolve(romURL: url, serial: serial, directoryHasSingleGame: single, side: .back) : nil
                    return await (front, back)
                }.value
                self?.applyPS2Covers(front: front, back: back, for: id)
            }
        }
    }

    // MARK: DS / 3DS / PSP case covers

    private var handheldCaseArt: [String: HandheldCaseArt] = [:]
    private var handheldCaseArtAttempts: Set<String> = []
    private nonisolated static let pspBoxartNames = HandheldCoverResolver.loadPSPNames(
        from: Bundle.main.url(forResource: "PSP-Boxart-Names", withExtension: "json"))

    nonisolated static var handheldCoverDirectory: URL {
        ROMFiles.supportDirectory().appendingPathComponent("CaseCovers", isDirectory: true)
    }

    /// Looks up the retail-case insert art of DS / 3DS / PSP games once per launch, off the main
    /// thread; each result refreshes its card.
    private func requestHandheldCaseArt() {
        let pending = games.filter { game in
            guard game.caseArt == nil, !handheldCaseArtAttempts.contains(game.id), game.url.scheme != "duo-tutorial" else { return false }
            return [.nds, .threeDS, .psp].contains(game.platform)
        }
        guard !pending.isEmpty else { return }
        let resolver = HandheldCoverResolver.live(cacheDirectory: Self.handheldCoverDirectory,
                                                  onlineEnabled: PS2LibrarySettings.onlineCoversEnabled,
                                                  pspNames: Self.pspBoxartNames)
        for game in pending {
            handheldCaseArtAttempts.insert(game.id)
            let platform: HandheldCasePlatform = switch game.platform {
            case .threeDS: .threeDS
            case .psp: .psp
            default: .nds
            }
            let id = game.id, url = game.url
            // PSPSDK stamps every homebrew EBOOT with the disc ID UCJS10041 (a retail game's), so
            // a PBP carrying it is homebrew: no box art lookup, local files only.
            let isHomebrewPBP = platform == .psp && url.pathExtension.lowercased() == "pbp"
                && game.productID?.replacingOccurrences(of: "-", with: "").uppercased() == "UCJS10041"
            let productID = isHomebrewPBP ? nil : game.productID
            Task { [weak self] in
                let set = await Task.detached(priority: .utility) {
                    await resolver.resolveInsert(romURL: url, productID: productID, platform: platform,
                                                 directoryHasSingleGame: Self.directoryHasSingleGame(url))
                }.value
                self?.applyHandheldCaseArt(set, for: id)
            }
        }
    }

    private func applyHandheldCaseArt(_ set: HandheldCoverArtSet, for id: String) {
        guard !set.isEmpty else { return }
        let art = HandheldCaseArt(full: set.full.flatMap(UIImage.init(data:)),
                                  front: set.front.flatMap(UIImage.init(data:)),
                                  back: set.back.flatMap(UIImage.init(data:)))
        guard art.full != nil || art.front != nil || art.back != nil else { return }
        handheldCaseArt[id] = art
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].caseArt = art
        games[index].appearanceRevision = UUID()
    }

    private func applyPS2Covers(front: Data?, back: Data?, for id: String) {
        let frontImage = front.flatMap(UIImage.init(data:)), backImage = back.flatMap(UIImage.init(data:))
        if let frontImage { ps2Covers[id] = frontImage }
        if let backImage { ps2BackCovers[id] = backImage }
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let frontImage, games[index].icon == nil { games[index].icon = frontImage; changed = true }
        if let backImage, games[index].backCover == nil { games[index].backCover = backImage; changed = true }
        if changed { games[index].appearanceRevision = UUID() }
    }

    /// True when the ROM's folder holds no other game (a cue and its BIN tracks count as one), so
    /// `cover.*` / `folder.*` there belong to it. Each import gets its own folder, so this is the usual case.
    nonisolated static func directoryHasSingleGame(_ romURL: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: romURL.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        let gameExtensions = ROMFiles.nds.union(ROMFiles.threeDS).union(ROMFiles.n64).union(ROMFiles.psp)
            .union(ROMFiles.discImages).union(ROMFiles.packages)
        let candidates = items.filter { gameExtensions.contains($0.pathExtension.lowercased()) }
        let tracks = Set(candidates.filter { $0.pathExtension.lowercased() == "cue" }
            .flatMap(ROMFiles.cueReferencedFiles).map(\.lastPathComponent))
        return candidates.filter { !tracks.contains($0.lastPathComponent) }.count == 1
    }

    // MARK: PS2 memory cards

    /// Per-game folder memory card: `Application Support/PS2/MemoryCards/<serial or file name>/`.
    /// Falls back to the ROM's file name rather than `title`, so renaming a game keeps its saves.
    nonisolated static func ps2MemoryCardRoot(for item: GameLibraryItem) -> URL {
        PS2MemoryCard.root(
            in: ROMFiles.supportDirectory().appendingPathComponent("PS2/MemoryCards", isDirectory: true),
            serial: item.productID, title: item.url.deletingPathExtension().lastPathComponent)
    }

    /// v3.0.0 can block forever while saving immediately before its Game Over screen.
    /// Replace only the byte-exact upstream release; user-modified ROMs remain untouched.
    private func upgradeKnownBuggyTrailMix(in directory: URL) {
        guard let replacement = Bundle.main.url(forResource: "TrailMix", withExtension: "nds"),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let buggySHA256 = "f83cdf6ef9f63d6c7d665e980b0c77e818f0d82a24bd2c5eee3a6d5aff4f5e1f"
        for case let candidate as URL in enumerator where candidate.lastPathComponent.caseInsensitiveCompare("TrailMix.nds") == .orderedSame {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, values.fileSize == 4_715_520,
                  let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == buggySHA256 else { continue }
            let staged = candidate.deletingLastPathComponent().appendingPathComponent(".TrailMix-v3.1.1.nds")
            do {
                try? fileManager.removeItem(at: staged)
                try fileManager.copyItem(at: replacement, to: staged)
                _ = try fileManager.replaceItemAt(candidate, withItemAt: staged)
            } catch {
                try? fileManager.removeItem(at: staged)
                importError = String(localized: "Trail Mix 更新失败：\(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func importGame(from source: URL) async -> GameLibraryItem? {
        guard !isImporting else { return nil }
        isImporting = true
        importError = nil
        importMessage = nil
        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            isImporting = false
            if didAccess { source.stopAccessingSecurityScopedResource() }
        }
        let support = ROMFiles.supportDirectory()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.performImport(source, support: support)
            }.value
            if result.launchBundledMK64 {
                setBundledGameHidden(filename: "MK64-3DS.3dsx", hidden: false)
            }
            reload()
            let importedGame = result.launchBundledMK64
                ? games.first(where: \.isBundledMK64Port)
                : result.paths.first.flatMap { path in games.first(where: { $0.url.path == path }) }
            if let importedGame { selectedID = importedGame.id }
            importMessage = result.message
            return importedGame
        } catch {
            importError = String(localized: "导入失败：\(error.localizedDescription)")
            reload()
            return nil
        }
    }

    nonisolated private static func performImport(_ source: URL, support: URL) throws -> ImportResult {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("DuoImport-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let candidates = try ROMFiles.prepare(source, in: staging)
        if candidates.isEmpty {
            if ROMFiles.isArchive(source) {
                let companions = try routeVirtualSDCompanions(from: staging, support: support, fileManager: fm)
                if companions.copied > 0 || companions.conflicts > 0 {
                    let message = companions.copied > 0
                        ? String(localized: "已自动导入 3DS 虚拟 SD 与存档数据（\(companions.copied) 个文件）")
                        : String(localized: "3DS 虚拟 SD 中已有相同路径的数据，现有文件已保留")
                    return ImportResult(paths: [], message: message, launchBundledMK64: false)
                }
                let pspFiles = try routePSPSaveCompanions(from: staging, support: support, fileManager: fm)
                if pspFiles.copied > 0 || pspFiles.conflicts > 0 {
                    let message = pspFiles.copied > 0
                        ? String(localized: "已自动导入 PSP 存档（\(pspFiles.copied) 个文件）")
                        : String(localized: "PSP 中已有相同路径的存档，现有文件已保留")
                    return ImportResult(paths: [], message: message, launchBundledMK64: false)
                }
            }
            throw ROMFiles.Failure(message: String(localized: "压缩包内没有可导入的游戏或存档文件"))
        }
        // Validate the complete batch before installing or publishing any of its entries.
        let validated = try candidates.map { ($0, try ROMFiles.canonicalExtension($0)) }
        let batchROMs = validated.compactMap { file, ext in
            (ROMFiles.nds.contains(ext) || ROMFiles.n64.contains(ext) || ROMFiles.psp.contains(ext)) ? file : nil
        }
        let roms = support.appendingPathComponent("ROMs/" + UUID().uuidString, isDirectory: true)
        let manifestURL = support.appendingPathComponent("InstalledTitles.json")
        var manifest = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: manifestURL))) ?? [:]
        var paths: [String] = []
        var messages: [String] = []
        var retainedROMs = false
        var stagedROMs: [(staged: URL, published: String)] = []
        var configuredMK64 = false
        let packageHasMK64O2R = validated.contains {
            $0.1 == "o2r" && $0.0.lastPathComponent.lowercased() == "mk64.o2r"
        }
        for (file, ext) in validated {
            if ext == "save" {
                let result = try routeSave(file, support: support, additionalROMs: batchROMs,
                                           fileManager: fm)
                messages.append(result)
                try fm.removeItem(at: file)
                continue
            }
            if ext == "system", let name = ROMFiles.systemFilename(file) {
                let directory = support.appendingPathComponent("DS/System", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    guard fm.contentsEqual(atPath: file.path, andPath: target.path) else {
                        throw ROMFiles.Failure(message: String(localized: "已有不同的系统文件 \(name)，未覆盖现有配置"))
                    }
                } else { try fm.copyItem(at: file, to: target) }
                try fm.removeItem(at: file)
                messages.append(String(localized: "已配置系统文件 \(name)"))
                continue
            }
            if ROMFiles.packages.contains(ext) {
                let saves = ROMFiles.azaharSaves(support)
                try fm.createDirectory(at: saves, withIntermediateDirectories: true)
                let result = try AzaharCoreBridge.installPackageURL(file, saveDirectory: saves)
                if let path = result["path"], !path.isEmpty, let id = result["titleID"] {
                    let relative = String(path.dropFirst(support.path.count + 1))
                    manifest[id] = ["path": relative, "title": file.deletingPathExtension().lastPathComponent]
                    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                    paths.append(path)
                    messages.append(String(localized: "已安装游戏 \(file.deletingPathExtension().lastPathComponent)"))
                } else {
                    messages.append(String(localized: "已安装更新或 DLC，启动对应本体后生效"))
                }
                try fm.removeItem(at: file)
                continue
            }
            if ext == "o2r" {
                guard ROMFiles.hasBundledMK64Port, file.lastPathComponent.lowercased() == "mk64.o2r" else { throw ROMFiles.Failure(message: String(localized: "O2R 是移植游戏资源，请使用对应游戏的数据导入方式")) }
                let directory = ROMFiles.mk64Directory(support)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent("mk64.o2r")
                try replaceCopy(of: file, at: target, fileManager: fm)
                try fm.removeItem(at: file)
                configuredMK64 = true
                messages.append(String(localized: "已自动配置 MK64 游戏资源"))
                continue
            }
            var file = file
            // A homebrew archive laid out as a memory stick (PSP/GAME/<name>/EBOOT.PBP): PPSSPP
            // treats a PBP under PSP/GAME/ as a game directory and fails to open it as a file, so
            // the game's folder (with any data next to the EBOOT) moves to the import root.
            if ext == "pbp" {
                let parts = file.deletingLastPathComponent().pathComponents
                if parts.count >= 3, parts[parts.count - 2].uppercased() == "GAME", parts[parts.count - 3].uppercased() == "PSP" {
                    let gameDirectory = file.deletingLastPathComponent()
                    let flattened = staging.appendingPathComponent(gameDirectory.lastPathComponent, isDirectory: true)
                    if !fm.fileExists(atPath: flattened.path) {
                        try fm.moveItem(at: gameDirectory, to: flattened)
                        file = flattened.appendingPathComponent(file.lastPathComponent)
                    }
                }
            }
            let canonical = file.deletingPathExtension().appendingPathExtension(ext)
            if canonical != file, fm.fileExists(atPath: canonical.path) { throw ROMFiles.Failure(message: String(localized: "包内含有转换后同名的游戏，请分别导入")) }
            if ext == "z64" {
                try ROMFiles.normalizeN64(file, to: canonical)
                if canonical != file { try fm.removeItem(at: file) }
                if ROMFiles.hasBundledMK64Port, try ROMFiles.isMarioKartUSA(canonical) {
                    let directory = ROMFiles.mk64Directory(support)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent("mk64.z64")
                    let changed = !fm.fileExists(atPath: target.path) || !fm.contentsEqual(atPath: canonical.path, andPath: target.path)
                    if changed {
                        try replaceCopy(of: canonical, at: target, fileManager: fm)
                        let generated = directory.appendingPathComponent("mk64.o2r")
                        if !packageHasMK64O2R, fm.fileExists(atPath: generated.path) { try fm.removeItem(at: generated) }
                    }
                    configuredMK64 = true
                    messages.append(changed ? String(localized: "已识别并自动配置美版 Mario Kart 64 ROM") : String(localized: "已确认 Mario Kart 64 ROM 配置完整"))
                }
            } else if canonical != file { try fm.moveItem(at: file, to: canonical) }
            let relative = String(canonical.path.dropFirst(staging.path.count + 1))
            let published = roms.appendingPathComponent(relative).path
            paths.append(published)
            stagedROMs.append((canonical, published))
            retainedROMs = true
        }
        // BIN tracks of an imported cue stay on disk next to it but are not separate games.
        let cueTracks = Set(stagedROMs.map(\.staged).filter { $0.pathExtension.lowercased() == "cue" }
            .flatMap(ROMFiles.cueReferencedFiles).map { $0.standardizedFileURL.path })
        let trackPaths = Set(stagedROMs.filter { cueTracks.contains($0.staged.standardizedFileURL.path) }.map(\.published))
        paths.removeAll { trackPaths.contains($0) }
        if ROMFiles.isArchive(source) {
            let ps2Games = stagedROMs.map(\.staged).filter {
                !cueTracks.contains($0.standardizedFileURL.path) && ROMFiles.isPS2Disc($0)
            }
            keepPS2ArchiveCovers(in: staging, games: ps2Games, fileManager: fm)
        }
        if ROMFiles.isArchive(source) {
            let companions = try routeVirtualSDCompanions(from: staging, support: support, fileManager: fm)
            if companions.copied > 0 { messages.append(String(localized: "已自动配置 \(companions.copied) 个虚拟 SD 数据文件")) }
            if companions.conflicts > 0 { messages.append(String(localized: "保留了 \(companions.conflicts) 个已有的用户数据文件")) }
            let pspFiles = try routePSPSaveCompanions(from: staging, support: support, fileManager: fm)
            if pspFiles.copied > 0 { messages.append(String(localized: "已自动导入 \(pspFiles.copied) 个 PSP 存档文件")) }
            if pspFiles.conflicts > 0 { messages.append(String(localized: "保留了 \(pspFiles.conflicts) 个已有的 PSP 存档文件")) }
        }
        if retainedROMs {
            try fm.createDirectory(at: roms.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: roms)
        }
        if !paths.isEmpty { messages.insert(String(localized: "已导入 \(paths.count) 个游戏"), at: 0) }
        if configuredMK64 { messages.append(String(localized: "正在启动 Mario Kart 64 3DS")) }
        return ImportResult(paths: paths, message: messages.joined(separator: "\n"), launchBundledMK64: configuredMK64)
    }

    /// Archive covers: an image named like the game anywhere in the archive, or `cover.*` / `folder.*`
    /// when the archive holds a single PS2 game, is copied next to the image as `<basename>.<ext>`
    /// so `PS2CoverResolver`'s local lookup finds it; likewise `<basename>.back.*` / `back.*` for the back.
    nonisolated private static func keepPS2ArchiveCovers(in staging: URL, games: [URL], fileManager: FileManager) {
        guard !games.isEmpty, let enumerator = fileManager.enumerator(
            at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return }
        let images = enumerator.compactMap { $0 as? URL }.filter {
            !$0.pathComponents.contains("__MACOSX") &&
                PS2CoverResolver.imageExtensions.contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path.count < $1.path.count }
        for game in games {
            let base = game.deletingPathExtension().lastPathComponent
            let directory = game.deletingLastPathComponent().standardizedFileURL
            for (name, generic) in [(base, ["cover", "folder"]), ("\(base).back", ["back"])] {
                let alreadyBeside = images.contains {
                    $0.deletingLastPathComponent().standardizedFileURL == directory &&
                        $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
                }
                guard !alreadyBeside else { continue }
                let stem: (URL) -> String = { $0.deletingPathExtension().lastPathComponent.lowercased() }
                let source = images.first { stem($0) == name.lowercased() }
                    ?? (games.count == 1 ? images.first { generic.contains(stem($0)) } : nil)
                guard let source else { continue }
                let target = directory.appendingPathComponent("\(name).\(source.pathExtension.lowercased())")
                if !fileManager.fileExists(atPath: target.path) { try? fileManager.copyItem(at: source, to: target) }
            }
        }
    }

    nonisolated private static func routeSave(
        _ source: URL, support: URL, additionalROMs: [URL] = [], fileManager: FileManager
    ) throws -> String {
        let sourceExtension = source.pathExtension.lowercased()
        if sourceExtension == "ppst" {
            let target = support.appendingPathComponent("PSP/MemoryStick/PSP/PPSSPP_STATE", isDirectory: true)
                .appendingPathComponent(source.lastPathComponent)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                if fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
                    return String(localized: "已确认 PSP 即时存档配置完整")
                }
                let backupDirectory = support.appendingPathComponent("Save Backups/PSP", isDirectory: true)
                try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                try fileManager.copyItem(
                    at: target,
                    to: backupDirectory.appendingPathComponent(target.lastPathComponent + "." + stamp + ".bak")
                )
            }
            try replaceCopy(of: source, at: target, fileManager: fileManager)
            return String(localized: "已导入 PSP 即时存档")
        }
        let sourceStem = normalizedSaveStem(source.deletingPathExtension().lastPathComponent)
        let romRoot = support.appendingPathComponent("ROMs", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let installedROMs = (fileManager.enumerator(at: romRoot, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])?
            .allObjects.compactMap { $0 as? URL } ?? []).filter {
                guard (try? $0.resourceValues(forKeys: keys).isRegularFile) == true else { return false }
                let ext = $0.pathExtension.lowercased()
                return ROMFiles.nds.contains(ext) || ROMFiles.n64.contains(ext) || ROMFiles.psp.contains(ext)
            }
        let roms = installedROMs + additionalROMs

        let allowedPlatforms: Set<GamePlatform>
        switch sourceExtension {
        case "dsv": allowedPlatforms = [.nds]
        case "srm": allowedPlatforms = [.n64]
        default: allowedPlatforms = [.nds, .n64]
        }
        let eligible = roms.compactMap { rom -> (URL, GamePlatform)? in
            guard let platform = GamePlatform.resolve(fileExtension: rom.pathExtension),
                  allowedPlatforms.contains(platform) else { return nil }
            return (rom, platform)
        }
        let exact = eligible.filter { rom, _ in
            let stem = normalizedSaveStem(rom.deletingPathExtension().lastPathComponent)
            return stem == sourceStem || normalizedSaveStem(rom.lastPathComponent) == sourceStem
        }
        let match: (URL, GamePlatform)
        let batchPaths = Set(additionalROMs.map { $0.standardizedFileURL.path })
        let exactBatch = exact.filter { batchPaths.contains($0.0.standardizedFileURL.path) }
        if exactBatch.count == 1 { match = exactBatch[0] }
        else if exact.count == 1 { match = exact[0] }
        else if exact.count > 1 {
            throw ROMFiles.Failure(message: String(localized: "找到多个同名游戏，无法确定存档属于哪一个；请让存档文件名与完整 ROM 文件名一致"))
        } else if eligible.count == 1 {
            match = eligible[0]
        } else {
            throw ROMFiles.Failure(message: String(localized: "无法自动匹配存档；请先导入对应游戏，并让存档文件名与游戏文件名一致"))
        }

        let target: URL
        switch match.1 {
        case .nds:
            target = support.appendingPathComponent("Saves", isDirectory: true)
                .appendingPathComponent(match.0.deletingPathExtension().lastPathComponent + ".dsv")
        case .n64:
            let canonicalROMName = match.0.deletingPathExtension().appendingPathExtension("z64").lastPathComponent
            target = support.appendingPathComponent("N64/Saves", isDirectory: true)
                .appendingPathComponent(canonicalROMName + ".srm")
        case .threeDS:
            throw ROMFiles.Failure(message: String(localized: "3DS 存档需要包含 Nintendo 3DS 目录结构的 ZIP、7Z 或 RAR 包"))
        case .psp:
            throw ROMFiles.Failure(message: String(localized: "PSP 存档需要包含 PSP/SAVEDATA 目录结构的 ZIP、7Z 或 RAR 包"))
        case .ps2:
            // Not reachable today (only NDS/N64 are eligible above). PS2 saves go through the memory card page.
            throw ROMFiles.Failure(message: String(localized: "PS2 存档请在该游戏的记忆卡页面导入 .psu 或 .max"))
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            if fileManager.contentsEqual(atPath: source.path, andPath: target.path) {
                return String(localized: "已确认 \(match.0.deletingPathExtension().lastPathComponent) 的存档配置完整")
            }
            let backupDirectory = support.appendingPathComponent("Save Backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = backupDirectory.appendingPathComponent(target.lastPathComponent + "." + stamp + ".bak")
            try fileManager.copyItem(at: target, to: backup)
        }
        try replaceCopy(of: source, at: target, fileManager: fileManager)
        return String(localized: "已为 \(match.0.deletingPathExtension().lastPathComponent) 自动导入 \(match.1.rawValue) 存档")
    }

    nonisolated private static func normalizedSaveStem(_ name: String) -> String {
        var value = name.lowercased()
        for suffix in [".nds", ".dsi", ".srl", ".z64", ".n64", ".v64", ".iso", ".cso", ".chd", ".pbp", ".pspelf", ".prx"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value.replacingOccurrences(of: "[^a-z0-9\\p{L}]", with: "", options: .regularExpression)
    }

    nonisolated private static func replaceCopy(of source: URL, at target: URL, fileManager: FileManager) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: temporary)
        do {
            if fileManager.fileExists(atPath: target.path) { _ = try fileManager.replaceItemAt(target, withItemAt: temporary) }
            else { try fileManager.moveItem(at: temporary, to: target) }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    nonisolated private static func routeVirtualSDCompanions(
        from staging: URL, support: URL, fileManager: FileManager
    ) throws -> (copied: Int, conflicts: Int) {
        guard let enumerator = fileManager.enumerator(
            at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let sdmc = ROMFiles.azaharSaves(support).appendingPathComponent("Azahar/sdmc", isDirectory: true)
        var copied = 0, conflicts = 0
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(file.path.dropFirst(staging.path.count)).split(separator: "/").map(String.init)
            let lowered = relative.map { $0.lowercased() }
            let tail: ArraySlice<String>?
            if let index = lowered.firstIndex(of: "sdmc") { tail = relative.suffix(from: index + 1) }
            else if let index = lowered.firstIndex(of: "3ds") { tail = relative.suffix(from: index) }
            else if let index = lowered.firstIndex(of: "nintendo 3ds") { tail = relative.suffix(from: index) }
            else { tail = nil }
            guard let tail, !tail.isEmpty,
                  !ROMFiles.n64.contains(file.pathExtension.lowercased()),
                  file.pathExtension.lowercased() != "o2r" else { continue }
            let target = tail.reduce(sdmc) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                if !fileManager.contentsEqual(atPath: file.path, andPath: target.path) { conflicts += 1 }
            } else {
                try fileManager.copyItem(at: file, to: target)
                copied += 1
            }
        }
        return (copied, conflicts)
    }

    /// PPSSPP uses a Memory Stick tree. Preserve that structure so games can
    /// see standard savedata, install data, textures and save states unchanged.
    nonisolated private static func routePSPSaveCompanions(
        from staging: URL, support: URL, fileManager: FileManager
    ) throws -> (copied: Int, conflicts: Int) {
        guard let enumerator = fileManager.enumerator(
            at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let memoryStick = support.appendingPathComponent("PSP/MemoryStick", isDirectory: true)
        let recognizedRoots = ["savedata", "ppsspp_state", "game", "textures", "cheats"]
        var copied = 0, conflicts = 0
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(file.path.dropFirst(staging.path.count)).split(separator: "/").map(String.init)
            let lowered = relative.map { $0.lowercased() }
            guard let pspIndex = lowered.firstIndex(of: "psp"), pspIndex + 1 < lowered.count,
                  recognizedRoots.contains(lowered[pspIndex + 1]) else { continue }
            let tail = relative.suffix(from: pspIndex)
            let target = tail.reduce(memoryStick) { $0.appendingPathComponent($1) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                if !fileManager.contentsEqual(atPath: file.path, andPath: target.path) { conflicts += 1 }
            } else {
                try fileManager.copyItem(at: file, to: target)
                copied += 1
            }
        }
        return (copied, conflicts)
    }

    func deleteGame(_ game: GameLibraryItem) throws {
        if saveInfo(for: game).exists { try rememberPreservedSave(for: game) }
        if game.isBundledTest {
            setBundledGameHidden(filename: game.url.lastPathComponent, hidden: true)
        } else if game.isInstalledTitle {
            let titleDirectory = game.url.deletingLastPathComponent().deletingLastPathComponent()
            try fileManager.removeItem(at: titleDirectory)
            let support = ROMFiles.supportDirectory()
            let manifestURL = support.appendingPathComponent("InstalledTitles.json")
            if var manifest = try? JSONDecoder().decode(
                [String: [String: String]].self, from: Data(contentsOf: manifestURL)
            ) {
                manifest = manifest.filter { _, entry in
                    guard let path = entry["path"] else { return true }
                    return support.appendingPathComponent(path).standardizedFileURL != game.url.standardizedFileURL
                }
                try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            }
        } else {
            if game.url.pathExtension.lowercased() == "cue" {
                for track in ROMFiles.cueReferencedFiles(game.url) where fileManager.fileExists(atPath: track.path) {
                    try fileManager.removeItem(at: track)
                }
            }
            try fileManager.removeItem(at: game.url)
        }
        reload()
    }

    func restoreBundledGames() {
        UserDefaults.standard.removeObject(forKey: Self.hiddenBundledGamesKey)
        reload()
    }

    private func setBundledGameHidden(filename: String, hidden: Bool) {
        var filenames = hiddenBundledGameFilenames
        if hidden { filenames.insert(filename) } else { filenames.remove(filename) }
        UserDefaults.standard.set(filenames.sorted(), forKey: Self.hiddenBundledGamesKey)
    }

    func managedSaveInfos() -> [GameSaveInfo] {
        var infos = games.map(saveInfo(for:))
        let activeKeys = Set(games.map(saveKey(for:)))
        for record in (try? preservedSaveRecords()) ?? [] where !activeKeys.contains(record.key) {
            let game = GameLibraryItem(
                url: URL(fileURLWithPath: record.originalPath), title: record.title,
                detail: String(localized: "已保留的存档"), platform: record.platform,
                cartridgeKind: .fallback(for: record.platform, fileExtension: ""),
                icon: nil, isBundledTest: false, programID: record.programID,
                productID: record.productID
            )
            let info = saveInfo(for: game)
            if info.exists { infos.append(info) }
        }
        return infos.sorted { $0.game.title.localizedStandardCompare($1.game.title) == .orderedAscending }
    }

    func saveInfo(for game: GameLibraryItem) -> GameSaveInfo {
        let support = ROMFiles.supportDirectory()
        switch game.platform {
        case .nds:
            let url = support.appendingPathComponent("Saves", isDirectory: true)
                .appendingPathComponent(game.url.deletingPathExtension().lastPathComponent + ".dsv")
            return makeSaveInfo(game: game, location: url, metadata: nil)
        case .n64:
            let url = support.appendingPathComponent("N64/Saves", isDirectory: true)
                .appendingPathComponent(game.url.lastPathComponent + ".srm")
            return makeSaveInfo(game: game, location: url, metadata: nil)
        case .threeDS:
            guard let programID = game.programID else {
                return GameSaveInfo(game: game, location: nil, metadataLocation: nil,
                                    byteCount: 0, modifiedAt: nil)
            }
            let high = String(format: "%08x", UInt32(programID >> 32))
            let low = String(format: "%08x", UInt32(programID & 0xffff_ffff))
            let titleRoot = ROMFiles.azaharSaves(support)
                .appendingPathComponent("Azahar/sdmc/Nintendo 3DS")
                .appendingPathComponent(String(repeating: "0", count: 32))
                .appendingPathComponent(String(repeating: "0", count: 32))
                .appendingPathComponent("title/\(high)/\(low)/data")
            return makeSaveInfo(
                game: game,
                location: titleRoot.appendingPathComponent("00000001", isDirectory: true),
                metadata: titleRoot.appendingPathComponent("00000001.metadata")
            )
        case .psp:
            guard let productID = game.productID else {
                return GameSaveInfo(game: game, location: nil, metadataLocation: nil,
                                    byteCount: 0, modifiedAt: nil)
            }
            let prefix = productID.replacingOccurrences(of: "-", with: "").uppercased()
            let root = support.appendingPathComponent("PSP/MemoryStick/PSP/SAVEDATA", isDirectory: true)
            let candidates = ((try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []).filter {
                $0.lastPathComponent.uppercased().hasPrefix(prefix) &&
                    ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            let sorted = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            guard let location = sorted.first else {
                return GameSaveInfo(game: game, location: nil, metadataLocation: nil,
                                    byteCount: 0, modifiedAt: nil)
            }
            return makeSaveInfo(game: game, location: location, metadata: nil,
                                additionalLocations: Array(sorted.dropFirst()))
        case .ps2:
            let root = Self.ps2MemoryCardRoot(for: game)
            guard let saves = try? PS2MemoryCard(root: root).saves(), !saves.isEmpty else {
                return GameSaveInfo(game: game, location: nil, metadataLocation: nil,
                                    byteCount: 0, modifiedAt: nil)
            }
            return makeSaveInfo(game: game, location: root, metadata: nil)
        }
    }

    func deleteSave(_ save: GameSaveInfo) throws {
        if let location = save.location, fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        if let metadata = save.metadataLocation, fileManager.fileExists(atPath: metadata.path) {
            try fileManager.removeItem(at: metadata)
        }
        for location in save.additionalLocations where fileManager.fileExists(atPath: location.path) {
            try fileManager.removeItem(at: location)
        }
        try forgetPreservedSave(for: save.game)
    }

    private func saveKey(for game: GameLibraryItem) -> String {
        switch game.platform {
        case .nds: return "nds:" + game.url.deletingPathExtension().lastPathComponent.lowercased()
        case .n64: return "n64:" + game.url.lastPathComponent.lowercased()
        case .threeDS:
            return game.programID.map { String(format: "3ds:%016llx", $0) }
                ?? "3ds:" + game.url.deletingPathExtension().lastPathComponent.lowercased()
        case .psp:
            return "psp:" + (game.productID?.lowercased() ?? game.url.deletingPathExtension().lastPathComponent.lowercased())
        case .ps2:
            return "ps2:" + Self.ps2MemoryCardRoot(for: game).lastPathComponent.lowercased()
        }
    }

    private var preservedSavesURL: URL {
        ROMFiles.supportDirectory().appendingPathComponent("PreservedSaves.json")
    }

    private func preservedSaveRecords() throws -> [PreservedSaveRecord] {
        guard fileManager.fileExists(atPath: preservedSavesURL.path) else { return [] }
        return try JSONDecoder().decode([PreservedSaveRecord].self, from: Data(contentsOf: preservedSavesURL))
    }

    private func writePreservedSaveRecords(_ records: [PreservedSaveRecord]) throws {
        try JSONEncoder().encode(records).write(to: preservedSavesURL, options: .atomic)
    }

    private func rememberPreservedSave(for game: GameLibraryItem) throws {
        let key = saveKey(for: game)
        var records = try preservedSaveRecords().filter { $0.key != key }
        records.append(PreservedSaveRecord(
            key: key, title: game.title, originalPath: game.url.path,
            platform: game.platform, programID: game.programID, productID: game.productID
        ))
        try writePreservedSaveRecords(records)
    }

    private func forgetPreservedSave(for game: GameLibraryItem) throws {
        let records = try preservedSaveRecords()
        let remaining = records.filter { $0.key != saveKey(for: game) }
        if remaining.count != records.count { try writePreservedSaveRecords(remaining) }
    }

    private func romDirectory() throws -> URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ROMs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSaveInfo(
        game: GameLibraryItem, location: URL, metadata: URL?, additionalLocations: [URL] = []
    ) -> GameSaveInfo {
        let locationExists = fileManager.fileExists(atPath: location.path)
        let metadataExists = metadata.map { fileManager.fileExists(atPath: $0.path) } ?? false
        guard locationExists || metadataExists else {
            return GameSaveInfo(game: game, location: nil, metadataLocation: nil,
                                byteCount: 0, modifiedAt: nil)
        }
        var size: Int64 = 0
        var latest: Date?
        for root in [location, metadata].compactMap({ $0 }) + additionalLocations
            where fileManager.fileExists(atPath: root.path) {
            if (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) {
                for case let file as URL in enumerator {
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    size += Int64(values?.fileSize ?? 0)
                    if let date = values?.contentModificationDate, latest == nil || date > latest! { latest = date }
                }
            } else if let values = try? root.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                size += Int64(values.fileSize ?? 0)
                latest = values.contentModificationDate
            }
        }
        return GameSaveInfo(game: game, location: locationExists ? location : nil,
                            metadataLocation: metadataExists ? metadata : nil,
                            additionalLocations: additionalLocations,
                            byteCount: size, modifiedAt: latest)
    }

}

private struct ROMMetadata {
    var title: String?
    var detail: String?
    var icon: UIImage?
    var cartridgeKind: GameCardKind?
    var programID: UInt64?
    var productID: String?
}

private enum ROMMetadataReader {
    static func read(from url: URL, platform: GamePlatform) -> ROMMetadata {
        switch platform {
        case .nds: return readNDS(from: url)
        case .threeDS: return read3DS(from: url)
        case .n64:
            let data = try? ROMFiles.header(url)
            let title = data.flatMap { $0.count >= 0x34 ? String(data: $0[0x20..<0x34], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            return ROMMetadata(title: title, detail: "Nintendo 64", cartridgeKind: .ndsStandard)
        case .psp:
            return readPSP(from: url)
        case .ps2:
            var serial: String?
            if case .ps2(let found, _) = ROMFiles.ps2DiscKind(url) { serial = found }
            // Cover art is resolved asynchronously by GameLibraryStore.
            return ROMMetadata(title: url.deletingPathExtension().lastPathComponent,
                               detail: serial ?? "PS2", cartridgeKind: .ps2Case, productID: serial)
        }
    }

    private struct ISOEntry {
        let extent: UInt64
        let size: Int
        let isDirectory: Bool
    }

    private static func readPSP(from url: URL) -> ROMMetadata {
        let fallback = ROMMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            detail: "Universal Media Disc", cartridgeKind: .umd
        )
        guard let handle = try? FileHandle(forReadingFrom: url) else { return fallback }
        defer { try? handle.close() }
        let ext = url.pathExtension.lowercased()
        var sfo: Data?
        var iconData: Data?
        if ext == "pbp", let header = try? read(handle, offset: 0, count: 40), header.count == 40,
           header.prefix(4) == Data([0x00, 0x50, 0x42, 0x50]) {
            let offsets = stride(from: 8, through: 36, by: 4).map { Int(littleEndian32(header, at: $0)) }
            if offsets.count == 8, offsets[0] >= 40, offsets[1] >= offsets[0] {
                sfo = try? read(handle, offset: UInt64(offsets[0]), count: offsets[1] - offsets[0])
            }
            if offsets.count == 8, offsets[2] > offsets[1] {
                iconData = try? read(handle, offset: UInt64(offsets[1]), count: offsets[2] - offsets[1])
            }
        } else if ext == "iso" {
            sfo = isoFile(handle, path: ["PSP_GAME", "PARAM.SFO"])
            iconData = isoFile(handle, path: ["PSP_GAME", "ICON0.PNG"])
        }
        guard let values = sfo.flatMap(parseSFO) else { return fallback }
        let title = values["TITLE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let productID = values["DISC_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ROMMetadata(
            title: title?.isEmpty == false ? title : fallback.title,
            detail: productID?.isEmpty == false ? productID : "Universal Media Disc",
            icon: iconData.flatMap(UIImage.init(data:)), cartridgeKind: .umd,
            productID: productID?.isEmpty == false ? productID : nil
        )
    }

    private static func parseSFO(_ data: Data) -> [String: String]? {
        guard data.count >= 20, data.prefix(4) == Data([0x00, 0x50, 0x53, 0x46]) else { return nil }
        let keyTable = Int(littleEndian32(data, at: 8))
        let dataTable = Int(littleEndian32(data, at: 12))
        let count = Int(littleEndian32(data, at: 16))
        guard count <= 4096, 20 + count * 16 <= data.count,
              keyTable >= 20, keyTable < data.count, dataTable >= keyTable, dataTable <= data.count else { return nil }
        var values: [String: String] = [:]
        for index in 0..<count {
            let entry = 20 + index * 16
            let keyOffset = Int(littleEndian16(data, at: entry))
            let format = littleEndian16(data, at: entry + 2)
            let valueLength = Int(littleEndian32(data, at: entry + 4))
            let valueOffset = Int(littleEndian32(data, at: entry + 12))
            guard keyTable + keyOffset < data.count, dataTable + valueOffset <= data.count else { continue }
            let keyTail = data[(keyTable + keyOffset)...]
            guard let keyEnd = keyTail.firstIndex(of: 0),
                  let key = String(data: keyTail[..<keyEnd], encoding: .utf8), !key.isEmpty else { continue }
            if format == 0x0204 || format == 0x0004 {
                let start = dataTable + valueOffset
                let end = min(data.count, start + max(0, valueLength))
                guard end >= start else { continue }
                let bytes = data[start..<end]
                let trimmed = bytes.prefix { $0 != 0 }
                if let value = String(data: trimmed, encoding: .utf8) { values[key] = value }
            }
        }
        return values
    }

    private static func isoFile(_ handle: FileHandle, path: [String]) -> Data? {
        guard let pvd = try? read(handle, offset: 16 * 2048, count: 2048), pvd.count == 2048,
              pvd[0] == 1, String(data: pvd[1..<6], encoding: .ascii) == "CD001",
              let root = isoRecord(pvd, offset: 156) else { return nil }
        var current = root
        for component in path {
            guard current.isDirectory,
                  let directory = try? read(handle, offset: current.extent * 2048, count: current.size),
                  let next = isoFind(directory, name: component) else { return nil }
            current = next
        }
        guard !current.isDirectory, current.size <= 32 * 1024 * 1024 else { return nil }
        return try? read(handle, offset: current.extent * 2048, count: current.size)
    }

    private static func isoFind(_ directory: Data, name: String) -> ISOEntry? {
        var offset = 0
        while offset < directory.count {
            let length = Int(directory[offset])
            if length == 0 { offset = ((offset / 2048) + 1) * 2048; continue }
            guard offset + length <= directory.count, length >= 34 else { break }
            let nameLength = Int(directory[offset + 32])
            guard offset + 33 + nameLength <= directory.count else { break }
            let raw = directory[(offset + 33)..<(offset + 33 + nameLength)]
            let candidate = String(data: raw, encoding: .ascii)?.split(separator: ";", maxSplits: 1).first.map(String.init)
            if candidate?.caseInsensitiveCompare(name) == .orderedSame { return isoRecord(directory, offset: offset) }
            offset += length
        }
        return nil
    }

    private static func isoRecord(_ data: Data, offset: Int) -> ISOEntry? {
        guard offset >= 0, offset + 34 <= data.count, Int(data[offset]) >= 34 else { return nil }
        let extent = UInt64(littleEndian32(data, at: offset + 2))
        let size = Int(littleEndian32(data, at: offset + 10))
        return ISOEntry(extent: extent, size: size, isDirectory: data[offset + 25] & 0x02 != 0)
    }


    private static func readNDS(from url: URL) -> ROMMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ROMMetadata() }
        defer { try? handle.close() }
        guard let header = try? read(handle, offset: 0, count: 0x200), header.count == 0x200 else {
            return ROMMetadata()
        }

        let headerTitle = ascii(header[0..<12])
        let gameCode = ascii(header[12..<16])
        let unitCode = header[0x12]
        let cartridgeKind: GameCardKind
        if gameCode.first == "I" {
            // melonDS uses the same game-code discriminator for Slot-1 IR carts.
            cartridgeKind = .ndsInfrared
        } else if unitCode == 3 {
            cartridgeKind = .dsiExclusive
        } else if unitCode == 2 {
            cartridgeKind = .dsiEnhanced
        } else {
            cartridgeKind = .ndsStandard
        }
        let bannerOffset = Int(littleEndian32(header, at: 0x68))
        guard bannerOffset > 0,
              let banner = try? read(handle, offset: UInt64(bannerOffset), count: 0x840),
              banner.count >= 0x840 else {
            return ROMMetadata(title: headerTitle, detail: gameCode, icon: nil, cartridgeKind: cartridgeKind,
                               productID: ndsProductID(gameCode))
        }

        let localizedTitleBlock = [1, 0, 6, 7, 2, 3, 4, 5]
            .lazy
            .compactMap { utf16LE(banner, offset: 0x240 + $0 * 0x100, byteCount: 0x100) }
            .first
        let localizedTitle = localizedTitleBlock?
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return ROMMetadata(
            title: localizedTitle ?? headerTitle,
            detail: gameCode.isEmpty ? "Nintendo DS" : gameCode,
            icon: ndsIcon(from: banner),
            cartridgeKind: cartridgeKind,
            productID: ndsProductID(gameCode)
        )
    }

    /// The 4-character game code (e.g. `A2DE`) when it looks like a retail one; homebrew often
    /// leaves `####` or zeros there.
    private static func ndsProductID(_ gameCode: String) -> String? {
        let code = gameCode.uppercased()
        guard code.count == 4, code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }),
              code != "####", code != "0000" else { return nil }
        return code
    }

    private static func read3DS(from url: URL) -> ROMMetadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ROMMetadata() }
        defer { try? handle.close() }

        if url.pathExtension.lowercased() == "3dsx",
           let header = try? read(handle, offset: 0, count: 44),
           header.count >= 44,
           String(data: header.prefix(4), encoding: .ascii) == "3DSX",
           littleEndian16(header, at: 4) >= 44 {
            let smdhOffset = UInt64(littleEndian32(header, at: 32))
            let smdhSize = Int(littleEndian32(header, at: 36))
            if smdhOffset > 0, smdhSize >= 0x36C0,
               let smdh = try? read(handle, offset: smdhOffset, count: 0x36C0),
               let metadata = parseSMDH(smdh) {
                var homebrewMetadata = metadata
                homebrewMetadata.cartridgeKind = .threeDS
                homebrewMetadata.programID = readProgramID(from: handle)
                return homebrewMetadata
            }
        }

        // Decrypted NCCH/CCI images commonly expose the ExeFS SMDH. Encrypted
        // retail dumps intentionally fall back to the physical cartridge label.
        if let smdh = findSMDH(in: handle), let metadata = parseSMDH(smdh) {
            var retailMetadata = metadata
            retailMetadata.cartridgeKind = .threeDS
            retailMetadata.programID = readProgramID(from: handle)
            retailMetadata.productID = readProductCode(from: handle)
            return retailMetadata
        }
        return ROMMetadata(
            detail: url.pathExtension.lowercased() == "3dsx" ? "3DS Homebrew" : "Nintendo 3DS",
            cartridgeKind: .threeDS,
            programID: readProgramID(from: handle),
            productID: readProductCode(from: handle)
        )
    }

    /// NCCH product code (0x150, e.g. `CTR-P-AMKE`), which is outside the encrypted regions.
    private static func readProductCode(from handle: FileHandle) -> String? {
        guard let header = try? read(handle, offset: 0, count: 0x200), header.count == 0x200 else { return nil }
        let magic = String(data: header.subdata(in: 0x100..<0x104), encoding: .ascii)
        let ncchOffset: UInt64
        if magic == "NCCH" {
            ncchOffset = 0
        } else if magic == "NCSD" {
            ncchOffset = UInt64(littleEndian32(header, at: 0x120)) * 0x200
        } else {
            return nil
        }
        guard let ncch = try? read(handle, offset: ncchOffset, count: 0x160), ncch.count >= 0x160,
              String(data: ncch.subdata(in: 0x100..<0x104), encoding: .ascii) == "NCCH" else { return nil }
        let code = ascii(ncch[0x150..<0x160])
        guard code.hasPrefix("CTR-") || code.hasPrefix("KTR-") else { return nil }
        return code
    }

    private static func readProgramID(from handle: FileHandle) -> UInt64? {
        guard let header = try? read(handle, offset: 0, count: 0x200), header.count == 0x200 else { return nil }
        let magic = String(data: header.subdata(in: 0x100..<0x104), encoding: .ascii)
        let ncchOffset: UInt64
        if magic == "NCCH" {
            ncchOffset = 0
        } else if magic == "NCSD" {
            ncchOffset = UInt64(littleEndian32(header, at: 0x120)) * 0x200
        } else {
            return nil
        }
        guard let ncch = try? read(handle, offset: ncchOffset, count: 0x120), ncch.count >= 0x120,
              String(data: ncch.subdata(in: 0x100..<0x104), encoding: .ascii) == "NCCH" else { return nil }
        return littleEndian64(ncch, at: 0x118)
    }

    private static func findSMDH(in handle: FileHandle) -> Data? {
        let chunkSize = 1_048_576
        let maximumBytes = 128 * chunkSize
        var offset = 0
        var carry = Data()
        while offset < maximumBytes {
            guard let chunk = try? read(handle, offset: UInt64(offset), count: chunkSize), !chunk.isEmpty else { break }
            var searchable = carry
            searchable.append(chunk)
            if let range = searchable.range(of: Data("SMDH".utf8)) {
                let absolute = max(0, offset - carry.count + range.lowerBound)
                if let candidate = try? read(handle, offset: UInt64(absolute), count: 0x36C0), candidate.count == 0x36C0 {
                    return candidate
                }
            }
            carry = searchable.suffix(3)
            offset += chunk.count
            if chunk.count < chunkSize { break }
        }
        return nil
    }

    private static func parseSMDH(_ data: Data) -> ROMMetadata? {
        guard data.count >= 0x36C0, String(data: data.prefix(4), encoding: .ascii) == "SMDH" else { return nil }
        let preferredLanguages = [1, 6, 10, 0, 2, 3, 4, 5, 7, 8, 9]
        var title: String?
        var publisher: String?
        for language in preferredLanguages {
            let base = 8 + language * 0x200
            if let candidate = utf16LE(data, offset: base, byteCount: 0x80), !candidate.isEmpty {
                title = candidate
                publisher = utf16LE(data, offset: base + 0x180, byteCount: 0x80)
                break
            }
        }
        return ROMMetadata(title: title, detail: publisher, icon: smdhLargeIcon(from: data))
    }

    private static func ndsIcon(from banner: Data) -> UIImage? {
        guard banner.count >= 0x240 else { return nil }
        let bitmap = banner.subdata(in: 0x20..<0x220)
        let paletteData = banner.subdata(in: 0x220..<0x240)
        var palette = [(UInt8, UInt8, UInt8, UInt8)]()
        for index in 0..<16 {
            let color = littleEndian16(paletteData, at: index * 2)
            palette.append((
                UInt8((Int(color & 0x1F) * 255) / 31),
                UInt8((Int((color >> 5) & 0x1F) * 255) / 31),
                UInt8((Int((color >> 10) & 0x1F) * 255) / 31),
                index == 0 ? 0 : 255
            ))
        }
        var rgba = [UInt8](repeating: 0, count: 32 * 32 * 4)
        for tileY in 0..<4 {
            for tileX in 0..<4 {
                let tile = tileY * 4 + tileX
                for row in 0..<8 {
                    for pair in 0..<4 {
                        let byte = bitmap[tile * 32 + row * 4 + pair]
                        for nibble in 0..<2 {
                            let colorIndex = Int(nibble == 0 ? byte & 0x0F : byte >> 4)
                            let x = tileX * 8 + pair * 2 + nibble
                            let y = tileY * 8 + row
                            let destination = (y * 32 + x) * 4
                            let color = palette[colorIndex]
                            rgba[destination] = color.0
                            rgba[destination + 1] = color.1
                            rgba[destination + 2] = color.2
                            rgba[destination + 3] = color.3
                        }
                    }
                }
            }
        }
        return image(width: 32, height: 32, rgba: rgba)
    }

    private static func smdhLargeIcon(from smdh: Data) -> UIImage? {
        let offset = 0x24C0
        guard smdh.count >= offset + 48 * 48 * 2 else { return nil }
        let tileOrder = [
            0, 1, 8, 9, 2, 3, 10, 11, 16, 17, 24, 25, 18, 19, 26, 27,
            4, 5, 12, 13, 6, 7, 14, 15, 20, 21, 28, 29, 22, 23, 30, 31,
            32, 33, 40, 41, 34, 35, 42, 43, 48, 49, 56, 57, 50, 51, 58, 59,
            36, 37, 44, 45, 38, 39, 46, 47, 52, 53, 60, 61, 54, 55, 62, 63
        ]
        var rgba = [UInt8](repeating: 255, count: 48 * 48 * 4)
        var sourcePixel = 0
        for tileY in stride(from: 0, to: 48, by: 8) {
            for tileX in stride(from: 0, to: 48, by: 8) {
                for order in tileOrder {
                    let color = littleEndian16(smdh, at: offset + sourcePixel * 2)
                    sourcePixel += 1
                    let x = tileX + (order & 7)
                    let y = tileY + (order >> 3)
                    let destination = (y * 48 + x) * 4
                    rgba[destination] = UInt8((Int((color >> 11) & 0x1F) * 255) / 31)
                    rgba[destination + 1] = UInt8((Int((color >> 5) & 0x3F) * 255) / 63)
                    rgba[destination + 2] = UInt8((Int(color & 0x1F) * 255) / 31)
                }
            }
        }
        return image(width: 48, height: 48, rgba: rgba)
    }

    private static func image(width: Int, height: Int, rgba: [UInt8]) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func littleEndian16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func littleEndian64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return (0..<8).reduce(0) { result, index in
            result | UInt64(data[offset + index]) << UInt64(index * 8)
        }
    }

    private static func ascii(_ bytes: Data.SubSequence) -> String {
        String(data: Data(bytes), encoding: .ascii)?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func utf16LE(_ data: Data, offset: Int, byteCount: Int) -> String? {
        guard offset >= 0, offset + byteCount <= data.count else { return nil }
        let bytes = data.subdata(in: offset..<(offset + byteCount))
        guard let string = String(data: bytes, encoding: .utf16LittleEndian) else { return nil }
        let clean = string
            .split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }
}

/// A trailing pane stays the same size as the cover display while space is revealed on its left.
/// Calibrated to the current Duo simulator's 2853 × 2007 open canvas; not a hinge-angle API.
enum DuoLibraryLayout {
    // Reserve the cover camera band in both postures, even when the inner display reports zero.
    static func headerClearance(safeTop: CGFloat) -> CGFloat { max(64, safeTop) }
    static func paneWidth(in size: CGSize) -> CGFloat {
        min(size.width, size.height * (1426.5 / 2007))
    }

    #if DEBUG
    static func check() {
        let closed = CGSize(width: 1426.5, height: 2007)
        let open = CGSize(width: 2853, height: 2007)
        assert(paneWidth(in: closed) == paneWidth(in: open))
        for width in stride(from: closed.width, through: open.width, by: 50) {
            assert(paneWidth(in: CGSize(width: width, height: open.height)) == closed.width)
        }
        assert(paneWidth(in: CGSize(width: 390, height: 844)) == 390)
        assert(headerClearance(safeTop: 0) == headerClearance(safeTop: 62))
        assert(headerClearance(safeTop: 80) >= 80)
    }
    #endif
}

struct GameLibraryView: View {
    @ObservedObject var library: GameLibraryStore
    let isExiting: Bool
    let onImport: () -> Void
    let onLaunch: (GameLibraryItem) -> Void
    let onFinished: () -> Void
    let onReturned: () -> Void
    let onSettings: () -> Void
    var highlightImport = false
    var isVisible = true
    @State private var stageActive = false
    @State private var cameraClearance: CGFloat = 64
    @AppStorage("scrollCueEnabled") private var scrollCueEnabled = true
    @AppStorage(HandheldCaseSettings.hideCasesKey) private var hideCases = false
    #if DEBUG
    @State private var previewPaneWidth: CGFloat?
    #endif

    private var selectedGame: GameLibraryItem? {
        library.games.first(where: { $0.id == library.selectedID }) ?? library.games.first
    }
    private var selectedIndex: Int {
        library.games.firstIndex(where: { $0.id == selectedGame?.id }) ?? 0
    }

    var body: some View {
      GeometryReader { safeArea in
        libraryCanvas(topInset: max(cameraClearance, DuoLibraryLayout.headerClearance(safeTop: safeArea.safeAreaInsets.top)))
          .ignoresSafeArea()
          .onChange(of: safeArea.safeAreaInsets.top, initial: true) { _, top in
              cameraClearance = max(cameraClearance, DuoLibraryLayout.headerClearance(safeTop: top))
              #if DEBUG
              print("DUO_SAFE_AREA: top=\(top), reserved=\(cameraClearance), size=\(safeArea.size)")
              fflush(stdout)
              #endif
          }
      }
    }

    private func libraryCanvas(topInset: CGFloat) -> some View {
      GeometryReader { proxy in
        ZStack(alignment: .trailing) {
          DragCartridgeSceneView(
            games: library.games,
            selectedID: library.selectedID,
            isExiting: isExiting,
            onSelect: { library.selectedID = $0 },
            onInserted: onLaunch,
            onFinished: onFinished,
            onReturned: onReturned,
            onImport: onImport,
            onStageActivityChanged: { stageActive = $0 },
            circularWhenExpanded: true,
            isVisible: isVisible
        )
          VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Game Duo")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.95))
                }
                .allowsHitTesting(false)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 44, height: 48)
                }
                .foregroundStyle(Color(white: 0.85))
                .accessibilityLabel(String(localized: "设置"))
                Button(action: onImport) {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color(white: 0.95))
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 17))
                        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(highlightImport ? Color.teal : .white.opacity(0.10), lineWidth: highlightImport ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "导入游戏"))
            }
            Spacer(minLength: 20)
            if let game = selectedGame {
                VStack(spacing: 13) {
                    if scrollCueEnabled {
                        // A retail case opens first, so the pull-down cue only shows for a bare
                        // cartridge / UMD / disc; its space stays so the title does not jump.
                        let tapToOpen = !hideCases && [.ps2, .nds, .threeDS, .psp].contains(game.platform)
                        SegmentedScrollCue(paused: stageActive || isExiting || tapToOpen)
                            .opacity(tapToOpen ? 0 : 1)
                            .padding(.bottom, 1)
                    }
                    Text(game.platform.displayName.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color(red: 0.64, green: 0.77, blue: 0.81))
                    Text(game.title)
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.96))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 7) {
                        Image(systemName: "internaldrive")
                        Text(String(localized: "本机游戏"))
                        Text("·")
                        Text("\(selectedIndex + 1) / \(library.games.count)").monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    // One lookup for all dots: `selectedIndex` scans the library (and standardizes every URL).
                    let dot = min(selectedIndex, 8)
                    HStack(spacing: 5) {
                        ForEach(0..<min(library.games.count, 9), id: \.self) { index in
                            Capsule()
                                .fill(.white.opacity(index == dot ? 0.8 : 0.18))
                                .frame(width: index == dot ? 18 : 4, height: 4)
                        }
                    }
                    .padding(.top, 9)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 36)
                .allowsHitTesting(false)
            } else {
                VStack(spacing: 15) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 36, weight: .light))
                    Text(String(localized: "收藏，从第一张卡带开始"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(String(localized: "导入 DS 或 3DS 游戏文件，\n自动识别卡带和游戏图标。"))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                    Button(String(localized: "导入游戏"), action: onImport)
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.46, green: 0.63, blue: 0.69))
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
          }
          .padding(.horizontal, 28)
          .padding(.top, topInset + 22)
          .padding(.bottom, 24)
          .frame(width: proxy.size.width)
          .opacity(stageActive || isExiting ? 0 : 1)
          .allowsHitTesting(!stageActive && !isExiting)
          .accessibilityHidden(stageActive || isExiting)
          .animation(.easeInOut(duration: 0.18), value: stageActive || isExiting)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-duo-cover-preview") {
                previewPaneWidth = DuoLibraryLayout.paneWidth(in: proxy.size)
            }
            if ProcessInfo.processInfo.arguments.contains("-duo-fold-sweep") {
                let full = proxy.size.width
                let cover = DuoLibraryLayout.paneWidth(in: proxy.size)
                previewPaneWidth = cover
                print("DUO_SWEEP_CLOSED width=\(cover) height=\(proxy.size.height)")
                fflush(stdout)
                for (delay, width, label) in [(4.0, (full + cover) / 2, "MID"),
                                              (8.0, full, "OPEN"), (12.0, cover, "CLOSED_AGAIN"),
                                              (16.0, full, "RESTORED")] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        previewPaneWidth = width
                        print("DUO_SWEEP_\(label) width=\(width)")
                        fflush(stdout)
                    }
                }
            }
            #endif
        }
      }
      .ignoresSafeArea()
      #if DEBUG
      .frame(width: previewPaneWidth)
      .frame(maxWidth: .infinity, alignment: .trailing)
      #endif
      .onAppear {
          #if DEBUG
          DuoLibraryLayout.check()
          if ProcessInfo.processInfo.arguments.contains("-mk64-cartridge-preview") {
              library.selectedID = library.games.first(where: {
                  $0.url.lastPathComponent == "MK64-3DS.3dsx"
              })?.id
          }
          #endif
      }
    }

}

/// ContentView observes the emulator session, so every emulated frame (`topImage` / `bottomImage`)
/// rebuilds it and, without this, the whole library view as well — hidden under the game but still
/// re-evaluated 60–120 times a second on the main thread, which starved frame presentation for
/// every core. The library only needs a new body when these inputs change; `library` publishes to
/// this view directly, and the callbacks reach ContentView's state through its property wrappers.
extension GameLibraryView: Equatable {
    static func == (lhs: GameLibraryView, rhs: GameLibraryView) -> Bool {
        lhs.library === rhs.library && lhs.isExiting == rhs.isExiting
            && lhs.highlightImport == rhs.highlightImport && lhs.isVisible == rhs.isVisible
    }
}

/// A low-contrast, segmented cue that communicates the next vertical gesture
/// without moving any of the library's layout or card content.
private struct SegmentedScrollCue: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let paused: Bool
    private let cycle: TimeInterval = 1.35

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || paused)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle)
            let progress = reduceMotion ? 0.5 : elapsed / cycle
            let sweepOffset = CGFloat(-50 + progress * 100)

            ZStack {
                chevrons(color: .white.opacity(0.18), lineWidth: 3.0)

                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.10), location: 0.16),
                                .init(color: .white.opacity(0.68), location: 0.50),
                                .init(color: .white.opacity(0.10), location: 0.84),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 36, height: 52)
                    .offset(y: sweepOffset)
                    .blur(radius: 0.35)
                    .mask {
                        chevrons(color: .white, lineWidth: 3.1)
                    }
            }
            .frame(width: 36, height: 57)
            .clipped()
            .accessibilityHidden(true)
        }
        .frame(width: 36, height: 57)
    }

    private func chevrons(color: Color, lineWidth: CGFloat) -> some View {
        VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                DownChevronShape()
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 30, height: 15)
                }
            }
        .frame(width: 36, height: 57)
    }
}

private struct DownChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 3))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 3))
        return path
    }
}

enum CartridgeSceneFactory {
    private static let detailedModels: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "Detailed-Cartridges", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url)
    }()
    private static let umdModel: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "PSP-UMD", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url)
    }()
    private static let umdShellModel: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "PSP-UMD-Shell", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url)
    }()
    /// The library's Cover Flow card for `game` (`cartridgeModel`): DS / 3DS / PSP games in their
    /// retail case holding the medium (`handheldCaseScene`), PS2 games in theirs; with
    /// `HandheldCaseSettings.casesHidden` the bare medium (a PS2 game shows its disc).
    static func scene(for game: GameLibraryItem) -> SCNScene {
        if let caseScene = handheldCaseScene(for: game) { return caseScene }
        if game.cartridgeKind == .ps2Case, HandheldCaseSettings.casesHidden,
           let disc = ps2DiscScene(for: game) { return disc }
        return mediumScene(for: game)
    }

    /// DS / 3DS / PSP retail case with the game's insert, holding a clone of the medium the library
    /// showed before (`mediumScene`) at `CASE_MEDIUM_ANCHOR`. nil: no case for this game.
    static func handheldCaseScene(for game: GameLibraryItem) -> SCNScene? {
        guard let kind = HandheldCaseKind(game: game) else { return nil }
        let medium = mediumScene(for: game).rootNode.childNode(withName: "cartridgeModel", recursively: true)
        medium?.removeFromParentNode()
        guard let caseNode = HandheldCaseAssets.makeCase(kind, insert: handheldInsertTexture(for: game),
                                                         medium: medium) else { return nil }
        let scene = SCNScene()
        scene.rootNode.name = game.id
        let model = SCNNode()
        model.name = "cartridgeModel"
        model.eulerAngles = SCNVector3(-0.05, -0.08, 0)
        model.addChildNode(caseNode)
        scene.rootNode.addChildNode(model)
        HandheldCaseAssets.addPreviewRig(to: scene)
        return scene
    }

    // Real DS/3DS cards are approximately 33 × 35 × 3.8 mm. SceneKit units
    // below are millimetres so the thickness and face proportions stay real.
    /// The bare medium (DS / 3DS card, UMD, or the PS2 case), as the library showed it before cases.
    static func mediumScene(for game: GameLibraryItem) -> SCNScene {
        if game.cartridgeKind == .umd { return umdScene(for: game) }
        if game.cartridgeKind == .ps2Case { return ps2CaseScene(for: game) }
        let scene = SCNScene()
        scene.rootNode.name = game.id

        let model = SCNNode()
        model.name = "cartridgeModel"
        model.eulerAngles = SCNVector3(-0.07, -0.10, 0)
        scene.rootNode.addChildNode(model)

        let detailed = detailedModels?.rootNode.childNode(withName: game.cartridgeKind.modelNodeName, recursively: true)?.clone()
        if let detailed {
            detailed.position = SCNVector3Zero
            NeutralBranding.hideTrademarkNodes(in: detailed)
            model.addChildNode(detailed)
        } else {
        let shellPath = silhouette(for: game.cartridgeKind)
        let shell = SCNShape(path: shellPath, extrusionDepth: 3.8)
        shell.chamferRadius = 0.55
        shell.chamferMode = .both
        shell.materials = shellMaterials(for: game.cartridgeKind)
        let shellNode = SCNNode(geometry: shell)
        shellNode.name = "cartridgeShell"
        shellNode.position.z = -1.9
        model.addChildNode(shellNode)
        addBackContacts(to: model, kind: game.cartridgeKind)
        }

        if let color = game.shellColor {
            model.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                let copy = geometry.copy() as! SCNGeometry
                copy.materials = geometry.materials.map { original in
                    let name = original.name ?? ""
                    guard node.name == "cartridgeShell" || name.contains("molded_plastic") || name.contains("inset_plastic") else { return original }
                    let material = original.copy() as! SCNMaterial
                    material.diffuse.contents = name.contains("inset") ? color.uiColor.darker(by: 0.15) : color.uiColor
                    return material
                }
                node.geometry = copy
            }
        }
        let label = SCNPlane(width: 26.2, height: 22.4)
        label.cornerRadius = 1.15
        let labelMaterial = SCNMaterial()
        let labelImage = labelTexture(for: game)
        labelMaterial.diffuse.contents = labelImage
        labelMaterial.emission.contents = UIColor.black
        labelMaterial.roughness.contents = 0.72
        labelMaterial.lightingModel = .physicallyBased
        labelMaterial.isDoubleSided = false
        label.materials = [labelMaterial]
        let labelNode = SCNNode(geometry: label)
        labelNode.position = SCNVector3(0, 1.1, detailed == nil ? 0.04 : -0.12)
        model.addChildNode(labelNode)
        addInsetGameTitle(to: model, game: game)

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = 1
        camera.zFar = 200
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 72)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .area
        key.intensity = 1_850
        key.color = UIColor(white: 1.0, alpha: 1)
        key.areaExtents = SIMD3<Float>(32, 32, 0)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-24, 30, 42)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 980
        rim.color = UIColor(white: 0.84, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(24, -12, 20)
        scene.rootNode.addChildNode(rimNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 620
        ambient.color = UIColor(white: 0.62, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let frontFill = SCNLight()
        frontFill.type = .omni
        frontFill.intensity = 1_450
        frontFill.color = UIColor(white: 0.92, alpha: 1)
        frontFill.attenuationStartDistance = 30
        frontFill.attenuationEndDistance = 110
        let frontFillNode = SCNNode()
        frontFillNode.light = frontFill
        frontFillNode.position = SCNVector3(0, 8, 48)
        scene.rootNode.addChildNode(frontFillNode)

        let warmFill = SCNLight()
        warmFill.type = .spot
        warmFill.intensity = 1_150
        warmFill.color = UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1)
        warmFill.spotInnerAngle = 24
        warmFill.spotOuterAngle = 66
        let warmNode = SCNNode()
        warmNode.light = warmFill
        warmNode.position = SCNVector3(26, 24, 36)
        warmNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(warmNode)

        return scene
    }

    // USD imports SVG glyphs as outlines. Fill their existing contours so the
    // original lettering stays legible instead of appearing as white wireframes.
    private static func filledUMDBadgeLetter(_ node: SCNNode) {
        guard let geometry = node.geometry,
              let source = geometry.sources(for: .vertex).first,
              source.bytesPerComponent == 4, source.componentsPerVector >= 2,
              geometry.elements.allSatisfy({ $0.primitiveType == .line }) else { return }
        func point(_ index: Int) -> CGPoint {
            source.data.withUnsafeBytes { data in
                let offset = source.dataOffset + index * source.dataStride
                return CGPoint(x: CGFloat(data.loadUnaligned(fromByteOffset: offset, as: Float.self)) * 1000,
                               y: CGFloat(data.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)) * 1000)
            }
        }
        let path = UIBezierPath()
        path.usesEvenOddFillRule = true
        for element in geometry.elements {
            let indices: [Int] = element.data.withUnsafeBytes { data in
                (0..<(element.primitiveCount * 2)).map { index in
                    let offset = index * element.bytesPerIndex
                    return element.bytesPerIndex == 2
                        ? Int(data.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        : Int(data.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                }
            }
            var previous: CGPoint?
            for index in stride(from: 0, to: indices.count, by: 2) {
                let a = point(indices[index]), b = point(indices[index + 1])
                if previous != a { path.move(to: a) }
                path.addLine(to: b)
                previous = b
            }
        }
        let shape = SCNShape(path: path, extrusionDepth: 0)
        let ink = SCNMaterial()
        ink.diffuse.contents = UIColor(red: 0.48, green: 0.50, blue: 0.67, alpha: 1)
        ink.lightingModel = .constant
        ink.isDoubleSided = true
        shape.materials = [ink]
        let fill = SCNNode(geometry: shape)
        fill.name = "UMD_original_letter_fill"
        fill.scale = SCNVector3(0.001, 0.001, 0.001)
        node.geometry = nil
        node.addChildNode(fill)
    }

    private static func umdScene(for game: GameLibraryItem) -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.name = game.id
        let model = SCNNode()
        // The carousel treats every physical medium as the currently selected
        // insertable object. Keep the shared node contract while retaining the
        // UMD geometry and circular label.
        model.name = "cartridgeModel"
        model.eulerAngles = SCNVector3(-0.05, -0.08, 0)
        // UMDs read much larger than cartridges in the shared carousel camera.
        // Keep the authored proportions but present the complete assembly 30% smaller.
        let artworkMaterial = SCNMaterial()
        artworkMaterial.diffuse.contents = umdLabelTexture(for: game)
        // The source label UVs were projected from +Z; the label is viewed from -Z.
        var labelTransform = SCNMatrix4MakeScale(-1, 1, 1)
        labelTransform.m41 = 1
        artworkMaterial.diffuse.contentsTransform = labelTransform
        artworkMaterial.roughness.contents = 0.44
        artworkMaterial.metalness.contents = 0.06
        artworkMaterial.lightingModel = .physicallyBased
        artworkMaterial.isDoubleSided = true
        artworkMaterial.transparencyMode = .dualLayer

        // The original USD shell has vertices but no SceneKit draw elements.
        // This export preserves its shape with explicit triangles and material binding.
        let shellMaterial = SCNMaterial()
        shellMaterial.diffuse.contents = UIColor(white: 0.94, alpha: 1)
        shellMaterial.roughness.contents = 0.31
        shellMaterial.metalness.contents = 0.01
        shellMaterial.lightingModel = .physicallyBased
        shellMaterial.isDoubleSided = true

        if let shellSource = umdShellModel?.rootNode.clone() {
            shellSource.name = "umdExactMouldedShell"
            shellSource.scale = SCNVector3(700, 700, 700)
            shellSource.eulerAngles.y = .pi
            shellSource.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry?.copy() as? SCNGeometry else { return }
                geometry.materials = [shellMaterial]
                node.geometry = geometry
            }
            model.addChildNode(shellSource)
        }

        if let source = umdModel?.rootNode.clone() {
            source.scale = SCNVector3(700, 700, 700)
            // The authored label face is -Z; +Z is the optical/read face.
            // Turn the complete assembly together, retaining the upright shell.
            source.eulerAngles.y = .pi
            source.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { $0.isDoubleSided = true }
                // Keep the original raised centre badge and its UMD lettering above
                // the printed cover, exactly as authored in the supplied model.
                if node.name?.hasPrefix("Fixed_UMD_white_centre_badge") == true ||
                    node.name?.hasPrefix("UMD_shell_vector") == true {
                    node.opacity = 1
                    node.isHidden = false
                }
                if node.name?.hasPrefix("White_shell___continuous_moulded_frame") == true {
                    node.isHidden = umdShellModel != nil
                    if umdShellModel == nil,
                       let geometry = node.geometry?.copy() as? SCNGeometry {
                        geometry.materials = [shellMaterial]
                        node.geometry = geometry
                    }
                }
                guard node.name?.hasPrefix("Printed_disc_reverse") == true,
                      let geometry = node.geometry?.copy() as? SCNGeometry else { return }
                geometry.materials = [artworkMaterial]
                node.geometry = geometry
            }
            var lettering: [SCNNode] = []
            source.enumerateChildNodes { node, _ in
                guard node.geometry != nil else { return }
                var parent = node.parent
                while let ancestor = parent {
                    if ancestor.name?.hasPrefix("UMD_shell_vector") == true {
                        lettering.append(node)
                        break
                    }
                    parent = ancestor.parent
                }
            }
            lettering.forEach { filledUMDBadgeLetter($0) }
            NeutralBranding.hideTrademarkNodes(in: source)
            model.addChildNode(source)
        } else {
            let shell = SCNCylinder(radius: 31.8, height: 4.2)
            shell.radialSegmentCount = 96
            shell.materials = shellMaterials(for: .umd)
            let node = SCNNode(geometry: shell)
            node.eulerAngles.x = .pi / 2
            model.addChildNode(node)
        }
        scene.rootNode.addChildNode(model)

        let camera = SCNCamera()
        camera.fieldOfView = 39
        camera.zNear = 1
        camera.zFar = 250
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 112)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .area
        key.intensity = 1_900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-30, 38, 72)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 950
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(32, -20, 50)
        scene.rootNode.addChildNode(fillNode)
        return scene
    }

    // MARK: PS2 case

    private static let ps2CaseModel: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "PS2-Case", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url)
    }()

    /// PS2-Case.usdz is in metres (Y-up, root at the bottom centre). The carousel works in DS-card
    /// millimetres (UMDs are shown at 0.7×, ≈45 units); 247 units/m makes the 190 mm case 47 units
    /// tall, which clears the platform and title text under the shelf. The DS / 3DS / PSP cases use
    /// the same scale, so the cases keep their real sizes relative to each other.
    static let ps2CaseUnitsPerMetre: Float = 247

    /// Closed PS2 case with the game's cover insert, wrapped as the shared `cartridgeModel` node.
    static func ps2CaseScene(for game: GameLibraryItem) -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.name = game.id
        let model = SCNNode()
        model.name = "cartridgeModel"
        model.eulerAngles = SCNVector3(-0.05, -0.08, 0)
        scene.rootNode.addChildNode(model)

        let scale = ps2CaseUnitsPerMetre
        if let caseNode = ps2CaseModel?.rootNode.childNode(withName: "PS2_CASE", recursively: false)?.clone() {
            caseNode.scale = SCNVector3(scale, scale, scale)
            caseNode.position = SCNVector3(0, -0.095 * scale, 0)  // centre the 190 mm height
            applyPS2CoverInsert(ps2InsertTexture(for: game), to: caseNode)
            let cover = game.icon?.cgImage
            PS2CaseStage.applyBannerRule(to: caseNode, hasCover: cover.map { !PS2CoverResolver.hasBlankBanner($0) } ?? false)
            model.addChildNode(caseNode)
        } else {
            let box = SCNBox(width: CGFloat(0.135 * scale), height: CGFloat(0.19 * scale),
                             length: CGFloat(0.014 * scale), chamferRadius: 0.6)
            let front = SCNMaterial()
            front.diffuse.contents = ps2InsertTexture(for: game)
            front.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(0.4744, 1, 1),
                                                             SCNMatrix4MakeTranslation(0.5256, 0, 0))
            let plastic = SCNMaterial()
            plastic.diffuse.contents = UIColor(white: 0.06, alpha: 1)
            box.materials = [front, plastic, plastic, plastic, plastic, plastic]
            model.addChildNode(SCNNode(geometry: box))
        }

        let camera = SCNCamera()
        camera.fieldOfView = 39
        camera.zNear = 1
        camera.zFar = 300
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 130)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .area
        key.intensity = 1_900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-34, 44, 84)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 950
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(36, -24, 60)
        scene.rootNode.addChildNode(fillNode)
        return scene
    }

    /// Puts one insert texture on `COVER_ART`, `COVER_ART_SPINE` and `COVER_ART_BACK` (each has its own
    /// material; their UVs pick back / spine / front out of the same 273 × 183 mm sheet).
    static func applyPS2CoverInsert(_ texture: UIImage, to caseNode: SCNNode) {
        for slot in ["COVER_ART", "COVER_ART_SPINE", "COVER_ART_BACK"] {
            guard let node = caseNode.childNode(withName: slot, recursively: true) else { continue }
            // USD import may put the geometry on a `NAME_mesh` child instead.
            let targets = [node] + node.childNodes.filter { $0.name == slot + "_mesh" }
            for target in targets {
                guard let geometry = target.geometry?.copy() as? SCNGeometry else { continue }
                geometry.materials = geometry.materials.map { original in
                    let material = original.copy() as! SCNMaterial
                    material.diffuse.contents = texture
                    return material
                }
                target.geometry = geometry
            }
        }
    }

    private static let ps2InsertCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    /// Insert sheet (273 × 183 mm, laid out back | spine | front as seen from outside): the cover,
    /// aspect-filled and centre-cropped to the 129.5 × 183 mm front, with its dominant colour extended
    /// over the spine (and the back, unless a back cover was found, which fills the back the same way).
    /// Without a cover, a generated `PS2PlaceholderInsert` carrying the title.
    static func ps2InsertTexture(for game: GameLibraryItem) -> UIImage {
        let key = "\(game.id)|\(game.appearanceRevision)" as NSString
        if let cached = ps2InsertCache.object(forKey: key) { return cached }
        // 0.6 px/0.1 mm keeps the front (777 px wide) above the 512 px source covers.
        let size = CGSize(width: 1638, height: 1098)
        let frontRect = CGRect(x: (size.width * 0.5256).rounded(), y: 0,
                               width: size.width - (size.width * 0.5256).rounded(), height: size.height)
        let cover = game.icon?.cgImage.flatMap { image -> (front: CGImage, color: UIColor)? in
            let crop = PS2CoverResolver.frontCropRect(imageSize: CGSize(width: image.width, height: image.height))
            guard let front = image.cropping(to: crop) else { return nil }
            let c = PS2CoverResolver.dominantColor(of: image)
            return (front, UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
        }
        // An explicit sRGB RGBA context: UIGraphicsImageRenderer may pick a one-channel backing store
        // for grey-only drawing (the blank insert), which SceneKit's Metal path rejects.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return UIImage() }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        (cover?.color ?? UIColor(white: 0.93, alpha: 1)).setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        if let cover {
            UIImage(cgImage: cover.front).draw(in: frontRect)
            if let back = game.backCover?.cgImage,
               let cropped = back.cropping(to: PS2CoverResolver.frontCropRect(imageSize: CGSize(width: back.width, height: back.height))) {
                ctx.interpolationQuality = .high
                UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: size.width - frontRect.minX, height: size.height))
            }
        } else if let placeholder = PS2PlaceholderInsert.render(
            title: game.title, subtitle: game.productID, width: Int(size.width), height: Int(size.height)) {
            UIImage(cgImage: placeholder).draw(in: CGRect(origin: .zero, size: size))
        }
        UIGraphicsPopContext()
        guard let rendered = ctx.makeImage() else { return UIImage() }
        let texture = UIImage(cgImage: rendered)
        ps2InsertCache.setObject(texture, forKey: key)
        return texture
    }

    private static let labelImageContext = CIContext(options: [.cacheIntermediates: false])

    private static func dominantArtworkColor(_ icon: UIImage) -> UIColor {
        // Count small clusters of similar colours, rather than averaging the whole
        // cover (which would let white logos wash out a mostly dark background).
        let side = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sample = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in icon.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
        guard let image = sample.cgImage else { return UIColor(white: 0.12, alpha: 1) }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return UIColor(white: 0.12, alpha: 1) }
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Double>](repeating: .zero, count: 4096)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha > 127 else { continue }
            let r = min(255, Int(pixels[offset]) * 255 / alpha)
            let g = min(255, Int(pixels[offset + 1]) * 255 / alpha)
            let b = min(255, Int(pixels[offset + 2]) * 255 / alpha)
            let bucket = (r >> 4) * 256 + (g >> 4) * 16 + (b >> 4)
            counts[bucket] += 1
            sums[bucket] += SIMD3(Double(r), Double(g), Double(b))
        }
        var bestCount = 0
        var bestSum = SIMD3<Double>.zero
        for bucket in counts.indices where counts[bucket] > 0 {
            let r = bucket / 256, g = (bucket / 16) % 16, b = bucket % 16
            var count = 0
            var sum = SIMD3<Double>.zero
            for red in max(0, r - 1)...min(15, r + 1) {
                for green in max(0, g - 1)...min(15, g + 1) {
                    for blue in max(0, b - 1)...min(15, b + 1) {
                        let key = red * 256 + green * 16 + blue
                        count += counts[key]
                        sum += sums[key]
                    }
                }
            }
            if count > bestCount { bestCount = count; bestSum = sum }
        }
        guard bestCount > 0 else { return UIColor(white: 0.12, alpha: 1) }
        let rgb = bestSum / Double(bestCount * 255)
        return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    private static func extendedUMDArtwork(_ icon: UIImage, size: CGSize) -> CGImage? {
        let diameter = size.width - 48
        let scale = diameter / hypot(icon.size.width, icon.size.height)
        let artRect = CGRect(x: (size.width - icon.size.width * scale) / 2,
                             y: (size.height - icon.size.height * scale) / 2,
                             width: icon.size.width * scale, height: icon.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in icon.draw(in: artRect) }
        guard let input = CIImage(image: image) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let background = CIImage(color: CIColor(color: dominantArtworkColor(icon)))
        let foreground = input.cropped(to: artRect.insetBy(dx: 2, dy: 2)).clampedToExtent()
        // Fade the cover edges into its dominant colour; the outer disc converges
        // to one stable colour instead of stretching or blurring the picture there.
        let featherRadius = min(30, min(artRect.width, artRect.height) * 0.055)
        let inset = featherRadius * 2
        let mask = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(bounds)
            UIColor.white.setFill(); context.fill(artRect.insetBy(dx: inset, dy: inset))
        }
        guard let maskImage = CIImage(image: mask) else { return nil }
        let feather = maskImage.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
        let output = foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: feather
        ]).cropped(to: bounds)
        return labelImageContext.createCGImage(output, from: bounds)
    }

    private static func umdLabelTexture(for game: GameLibraryItem) -> UIImage {
        let size = CGSize(width: 1024, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18)
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
            context.fill(rect)
            if let icon = game.icon {
                if let extended = extendedUMDArtwork(icon, size: size) {
                    UIImage(cgImage: extended).draw(in: CGRect(origin: .zero, size: size))
                } else {
                // Inscribe the entire source rectangle in the circle. Its diagonal,
                // not its shortest side, must fit to retain every corner of the art.
                let scale = (rect.width - 12) / hypot(icon.size.width, icon.size.height)
                icon.draw(in: CGRect(x: (size.width - icon.size.width * scale) / 2,
                                     y: (size.height - icon.size.height * scale) / 2,
                                     width: icon.size.width * scale, height: icon.size.height * scale))
                }
            } else {
                UIColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 1).setFill()
                context.fill(rect)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let title = game.title.uppercased()
                (title as NSString).draw(in: CGRect(x: 92, y: 390, width: 840, height: 240), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 68, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ])
            }
        }
    }

    private static func silhouette(for kind: GameCardKind) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -15.8, y: 17.5))
        if kind == .threeDS {
            path.addLine(to: CGPoint(x: 12.2, y: 17.5))
            path.addLine(to: CGPoint(x: 12.2, y: 14.7))
            path.addLine(to: CGPoint(x: 17.5, y: 14.7))
            path.addLine(to: CGPoint(x: 17.5, y: 12.0))
            path.addLine(to: CGPoint(x: 16.5, y: 11.0))
        } else {
            path.addLine(to: CGPoint(x: 15.8, y: 17.5))
            path.addLine(to: CGPoint(x: 16.5, y: 16.8))
        }
        path.addLine(to: CGPoint(x: 16.5, y: -16.5))
        path.addLine(to: CGPoint(x: 15.5, y: -17.5))
        path.addLine(to: CGPoint(x: -13.6, y: -17.5))
        path.addLine(to: CGPoint(x: -16.5, y: -14.6))
        path.addLine(to: CGPoint(x: -16.5, y: 16.8))
        path.close()
        return path
    }

    private static func shellMaterials(for kind: GameCardKind) -> [SCNMaterial] {
        let shellColor: UIColor
        switch kind {
        case .threeDS, .dsiExclusive, .umd: shellColor = UIColor(white: 0.84, alpha: 1)
        case .ndsInfrared: shellColor = UIColor(red: 0.085, green: 0.11, blue: 0.105, alpha: 0.94)
        case .ndsStandard, .dsiEnhanced, .ps2Case: shellColor = UIColor(white: 0.20, alpha: 1)
        }
        let front = SCNMaterial()
        front.diffuse.contents = shellColor
        front.emission.contents = UIColor.black
        front.roughness.contents = 0.68
        front.metalness.contents = 0.0
        front.lightingModel = .physicallyBased

        let side = SCNMaterial()
        side.diffuse.contents = shellColor.withAlphaComponent(1).darker(by: 0.30)
        side.emission.contents = UIColor.black
        side.roughness.contents = 0.8
        side.lightingModel = .physicallyBased
        return [front, side, front, side, side]
    }

    private static func addInsetGameTitle(to model: SCNNode, game: GameLibraryItem) {
        let titlePlate = SCNPlane(width: 25.8, height: 3.65)
        let material = SCNMaterial()
        material.diffuse.contents = insetTitleTexture(for: game)
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.writesToDepthBuffer = false
        material.transparencyMode = .dualLayer
        titlePlate.materials = [material]

        let titleNode = SCNNode(geometry: titlePlate)
        titleNode.name = "insetGameTitle"
        titleNode.position = SCNVector3(0, -13.25, 0.08)
        titleNode.renderingOrder = 20
        model.addChildNode(titleNode)
    }

    private static func insetTitleTexture(for game: GameLibraryItem) -> UIImage {
        let size = CGSize(width: 1_536, height: 192)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let title = (game.engraving ?? game.title)
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .uppercased()
            let maximumWidth = size.width - 72
            var pointSize: CGFloat = 124
            var font = cartridgeTitleFont(ofSize: pointSize, title: title)
            while (title as NSString).size(withAttributes: [
                .font: font,
                .kern: pointSize * 0.018
            ]).width > maximumWidth,
                  pointSize > 48 {
                pointSize -= 2
                font = cartridgeTitleFont(ofSize: pointSize, title: title)
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byClipping
            let kern = pointSize * 0.018
            let titleSize = (title as NSString).size(withAttributes: [.font: font, .kern: kern])
            let rect = CGRect(
                x: 36,
                y: (size.height - titleSize.height) / 2 - 4,
                width: maximumWidth,
                height: titleSize.height + 12
            )
        let isLightShell = game.shellColor.map { $0 == .threeDSWhite }
            ?? (game.cartridgeKind == .threeDS || game.cartridgeKind == .dsiExclusive || game.cartridgeKind == .umd)

            (title as NSString).draw(
                in: rect.offsetBy(dx: 2.4, dy: 2.2),
                withAttributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                    .foregroundColor: UIColor.white.withAlphaComponent(isLightShell ? 0.72 : 0.92),
                    .kern: kern
                ]
            )
            (title as NSString).draw(
                in: rect.offsetBy(dx: -1.8, dy: -1.6),
                withAttributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                    .foregroundColor: UIColor.black.withAlphaComponent(isLightShell ? 0.90 : 0.96),
                    .kern: kern
                ]
            )
            (title as NSString).draw(
                in: rect,
                withAttributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                    .foregroundColor: isLightShell
                        ? UIColor(white: 0.16, alpha: 0.92)
                        : UIColor(white: 0.72, alpha: 0.94),
                    .kern: kern
                ]
            )
        }
    }

    private static func cartridgeTitleFont(ofSize size: CGFloat, title: String) -> UIFont {
        let usesLatinGlyphs = title.unicodeScalars.allSatisfy(\.isASCII)
        if usesLatinGlyphs, let font = UIFont(name: "DINCondensed-Bold", size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static func addBackContacts(to model: SCNNode, kind: GameCardKind) {
        let isLightShell = kind == .threeDS || kind == .dsiExclusive || kind == .umd

        let contactBed = SCNBox(width: 27.2, height: 11.4, length: 0.12, chamferRadius: 0.65)
        let bedMaterial = SCNMaterial()
        bedMaterial.diffuse.contents = UIColor(white: isLightShell ? 0.24 : 0.075, alpha: 1)
        bedMaterial.roughness.contents = 0.88
        bedMaterial.lightingModel = .physicallyBased
        contactBed.materials = [bedMaterial]
        let contactBedNode = SCNNode(geometry: contactBed)
        contactBedNode.position = SCNVector3(0, -9.3, -3.86)
        model.addChildNode(contactBedNode)

        let contactCount = 17
        let spacing: Float = 1.35
        let start = -Float(contactCount - 1) * spacing / 2
        for index in 0..<contactCount {
            let contact = SCNBox(width: 0.72, height: 7.2, length: 0.08, chamferRadius: 0.08)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 0.78, green: 0.57, blue: 0.16, alpha: 1)
            material.metalness.contents = 0.72
            material.roughness.contents = 0.28
            material.lightingModel = .physicallyBased
            contact.materials = [material]
            let node = SCNNode(geometry: contact)
            node.position = SCNVector3(start + Float(index) * spacing, -9.8, -3.94)
            model.addChildNode(node)
        }

        for index in 0...contactCount {
            let rib = SCNBox(width: 0.16, height: 9.0, length: 0.11, chamferRadius: 0.04)
            let ribMaterial = SCNMaterial()
            ribMaterial.diffuse.contents = UIColor(white: isLightShell ? 0.46 : 0.13, alpha: 1)
            ribMaterial.roughness.contents = 0.90
            rib.materials = [ribMaterial]
            let ribNode = SCNNode(geometry: rib)
            ribNode.position = SCNVector3(start - spacing / 2 + Float(index) * spacing, -9.35, -4.01)
            model.addChildNode(ribNode)
        }
    }

    static func labelTexture(for game: GameLibraryItem) -> UIImage {
        let size = CGSize(width: 720, height: 616)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3 // 2160 by 1848 pixels, independent of simulator display scale.
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            if let icon = game.icon {
                cg.interpolationQuality = .none // ROM pixel art remains pixel art, not invented HD artwork.
                let scale = max(size.width / icon.size.width, size.height / icon.size.height)
                let scaledSize = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
                icon.draw(
                    in: CGRect(
                        x: (size.width - scaledSize.width) / 2,
                        y: (size.height - scaledSize.height) / 2,
                        width: scaledSize.width,
                        height: scaledSize.height
                    ),
                    blendMode: .normal,
                    alpha: 1
                )
            } else {
                UIColor(white: 0.86, alpha: 1).setFill()
                cg.fill(CGRect(origin: .zero, size: size))
                let symbolName = game.platform == .threeDS ? "cube.transparent" : game.platform == .psp ? "opticaldisc" : "square.grid.2x2"
                let symbol = UIImage(systemName: symbolName)?
                    .withTintColor(UIColor(white: 0.22, alpha: 0.38), renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: 260, y: 100, width: 200, height: 200))
            }
        }
    }
}

private extension UIColor {
    func darker(by amount: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
        return UIColor(
            red: max(0, red * (1 - amount)),
            green: max(0, green * (1 - amount)),
            blue: max(0, blue * (1 - amount)),
            alpha: alpha
        )
    }
}
