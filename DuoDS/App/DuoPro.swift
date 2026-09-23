import CloudKit
import CryptoKit
import StoreKit
import SwiftUI
import UIKit
import MelonDSDeltaCore

enum DuoScreenLayout: String, Codable, CaseIterable, Identifiable {
    case console, stacked, sideBySide, topOnly, bottomOnly, pictureInPicture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .console: String(localized: "原机外观")
        case .stacked: String(localized: "上下双屏")
        case .sideBySide: String(localized: "左右双屏")
        case .topOnly: String(localized: "主屏放大")
        case .bottomOnly: String(localized: "触摸屏放大")
        case .pictureInPicture: String(localized: "画中画")
        }
    }
}

enum DuoVideoPreset: String, Codable, CaseIterable, Identifiable {
    case original, smooth, sharp, vivid
    var id: String { rawValue }
    var title: String {
        switch self { case .original: String(localized: "原始"); case .smooth: String(localized: "平滑"); case .sharp: String(localized: "锐化"); case .vivid: String(localized: "鲜艳") }
    }
}

enum DuoPerformancePreset: String, Codable, CaseIterable, Identifiable {
    case compatible, balanced, performance
    var id: String { rawValue }
    var title: String {
        switch self { case .compatible: String(localized: "兼容"); case .balanced: String(localized: "平衡"); case .performance: String(localized: "性能") }
    }
}

enum DuoRenderMode: String, Codable, CaseIterable, Identifiable {
    case original, hd
    var id: String { rawValue }
    var title: String { self == .hd ? String(localized: "高清") : String(localized: "原版") }
}

enum DuoPSPFrameRateMode: String, Codable, CaseIterable, Identifiable {
    case original, high
    var id: String { rawValue }
    var title: String { self == .high ? String(localized: "高帧率") : String(localized: "原版帧率") }
}

struct DuoCheat: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = String(localized: "新金手指")
    var code = ""
    var enabled = true
}

struct DuoGamePreferences: Codable, Equatable {
    var favorite = false
    var category = "未分类"
    var customTitle = ""
    var completed = false
    var playSeconds: TimeInterval = 0
    var lastPlayed: Date?
    var resolutionScale = 4.0
    var antialiasing = false
    var videoPreset = DuoVideoPreset.original
    var layout = DuoScreenLayout.console
    var topScreenScale = 1.0
    var bottomScreenScale = 1.0
    var controlOpacity = 1.0
    var controlScale = 1.0
    var stickSensitivity = 1.0
    var buttonMapping: [String: String] = [:]
    var turboButtons: Set<String> = []
    var macros: [String: [String]] = [:]
    var skinFilename: String?
    var coverFilename: String?
    var cartridgeEngraving: String?
    var cartridgeColor: CartridgeShellColor?
    var cheats: [DuoCheat] = []
    var speed = 1.0
    var showFPS = false
    var performancePreset = DuoPerformancePreset.balanced
}

struct DuoRuntimeConfiguration: Equatable {
    var preferences = DuoGamePreferences()
    var isPro = false
    var renderMode = DuoRenderMode.hd
    var pspRenderMode = DuoRenderMode.hd
    var pspFrameRateMode = DuoPSPFrameRateMode.high
}

struct DuoSnapshot: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    let isAutomatic: Bool
    let stateFilename: String
    let previewFilename: String?
}

@MainActor
final class DuoProEntitlement: ObservableObject {
    static let productID = "com.duods.pro.lifetime"
    @Published private(set) var isUnlocked = false
    @Published private(set) var product: Product?
    @Published var purchaseError: String?
    private var updates: Task<Void, Never>?

    init() {
        #if DEBUG
        isUnlocked = ProcessInfo.processInfo.arguments.contains("-duo-pro-unlocked") || UserDefaults.standard.bool(forKey: "duoProDebugUnlocked")
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self?.refresh()
                }
            }
        }
        Task { await load() }
    }

    deinit { updates?.cancel() }

    func load() async {
        product = try? await Product.products(for: [Self.productID]).first
        await refresh()
    }

    func purchase() async {
        guard let product else { purchaseError = String(localized: "购买项目暂时不可用，请稍后再试"); return }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish(); await refresh()
            case .success(.unverified): purchaseError = String(localized: "购买凭证未通过验证")
            case .pending: purchaseError = String(localized: "购买正在等待确认")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { purchaseError = error.localizedDescription }
    }

    func restore() async {
        do { try await AppStore.sync(); await refresh() }
        catch { purchaseError = error.localizedDescription }
    }

    func refresh() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil { entitled = true }
        }
        #if DEBUG
        entitled = entitled || ProcessInfo.processInfo.arguments.contains("-duo-pro-unlocked") || UserDefaults.standard.bool(forKey: "duoProDebugUnlocked")
        #endif
        isUnlocked = entitled
    }
}

@MainActor
final class DuoProStore: ObservableObject {
    static let shared = DuoProStore()
    @Published private(set) var games: [String: DuoGamePreferences] = [:]
    @Published private(set) var syncStatus = String(localized: "尚未同步")
    private let fm = FileManager.default

    private var root: URL { ROMFiles.supportDirectory().appendingPathComponent("DuoPro", isDirectory: true) }
    private var settingsURL: URL { root.appendingPathComponent("GamePreferences.json") }

    init() {
        if let data = try? Data(contentsOf: settingsURL),
           let value = try? JSONDecoder().decode([String: DuoGamePreferences].self, from: data) { games = value }
    }

    func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func preferences(for url: URL) -> DuoGamePreferences {
        var value = games[key(for: url)] ?? DuoGamePreferences()
        // Migrate older 1×/1.5×/2× settings to the new HD baseline. Keeping the
        // value normalized also makes the segmented control reflect what the
        // renderer actually uses.
        value.resolutionScale = max(4.0, value.resolutionScale)
        return value
    }

    func update(_ url: URL, _ change: (inout DuoGamePreferences) -> Void) {
        let key = key(for: url)
        var value = games[key] ?? DuoGamePreferences()
        change(&value)
        games[key] = value
        persist()
    }

    func recordPlay(_ url: URL, seconds: TimeInterval) {
        update(url) { $0.playSeconds += max(0, seconds); $0.lastPlayed = Date() }
    }

    func snapshotDirectory(for url: URL) -> URL { root.appendingPathComponent("Snapshots/" + key(for: url), isDirectory: true) }

    func snapshots(for url: URL) -> [DuoSnapshot] {
        let metadata = snapshotDirectory(for: url).appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: metadata), let result = try? JSONDecoder().decode([DuoSnapshot].self, from: data) else { return [] }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func saveSnapshot(data: Data, preview: CGImage?, gameURL: URL, name: String, automatic: Bool) throws -> DuoSnapshot {
        let directory = snapshotDirectory(for: gameURL)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), stateName = id.uuidString + ".state"
        try data.write(to: directory.appendingPathComponent(stateName), options: .atomic)
        var previewName: String?
        if let preview, let png = UIImage(cgImage: preview).pngData() {
            previewName = id.uuidString + ".png"
            try png.write(to: directory.appendingPathComponent(previewName!), options: .atomic)
        }
        var all = snapshots(for: gameURL)
        let snapshot = DuoSnapshot(id: id, name: name, createdAt: Date(), isAutomatic: automatic, stateFilename: stateName, previewFilename: previewName)
        all.insert(snapshot, at: 0)
        if automatic {
            let automaticItems = all.filter(\.isAutomatic).sorted { $0.createdAt > $1.createdAt }
            for stale in automaticItems.dropFirst(20) { try? deleteSnapshot(stale, gameURL: gameURL, updating: &all) }
        }
        try writeSnapshotIndex(all, gameURL: gameURL)
        return snapshot
    }

    func stateData(for snapshot: DuoSnapshot, gameURL: URL) throws -> Data {
        try Data(contentsOf: snapshotDirectory(for: gameURL).appendingPathComponent(snapshot.stateFilename))
    }

    func preview(for snapshot: DuoSnapshot, gameURL: URL) -> UIImage? {
        guard let filename = snapshot.previewFilename else { return nil }
        return UIImage(contentsOfFile: snapshotDirectory(for: gameURL).appendingPathComponent(filename).path)
    }

    func renameSnapshot(_ snapshot: DuoSnapshot, gameURL: URL, name: String) throws {
        var all = snapshots(for: gameURL)
        guard let index = all.firstIndex(where: { $0.id == snapshot.id }) else { return }
        all[index].name = name
        try writeSnapshotIndex(all, gameURL: gameURL)
    }

    func deleteSnapshot(_ snapshot: DuoSnapshot, gameURL: URL) throws {
        var all = snapshots(for: gameURL)
        try deleteSnapshot(snapshot, gameURL: gameURL, updating: &all)
        try writeSnapshotIndex(all, gameURL: gameURL)
    }

    private func deleteSnapshot(_ snapshot: DuoSnapshot, gameURL: URL, updating all: inout [DuoSnapshot]) throws {
        let directory = snapshotDirectory(for: gameURL)
        try? fm.removeItem(at: directory.appendingPathComponent(snapshot.stateFilename))
        if let preview = snapshot.previewFilename { try? fm.removeItem(at: directory.appendingPathComponent(preview)) }
        all.removeAll { $0.id == snapshot.id }
    }

    private func writeSnapshotIndex(_ snapshots: [DuoSnapshot], gameURL: URL) throws {
        let directory = snapshotDirectory(for: gameURL)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshots).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    func importSkin(from source: URL, gameURL: URL) throws {
        let didAccess = source.startAccessingSecurityScopedResource(); defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        guard UIImage(contentsOfFile: source.path) != nil else { throw ROMFiles.Failure(message: String(localized: "控制器皮肤需要 PNG、JPG 或 HEIC 图片")) }
        let directory = root.appendingPathComponent("Skins", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = key(for: gameURL) + "." + source.pathExtension.lowercased()
        let target = directory.appendingPathComponent(name)
        try? fm.removeItem(at: target); try fm.copyItem(at: source, to: target)
        update(gameURL) { $0.skinFilename = name }
    }

    func skin(for url: URL) -> UIImage? {
        guard let name = preferences(for: url).skinFilename else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent("Skins/" + name).path)
    }

    func importCover(from source: URL, gameURL: URL) throws {
        let didAccess = source.startAccessingSecurityScopedResource(); defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        guard UIImage(contentsOfFile: source.path) != nil else { throw ROMFiles.Failure(message: String(localized: "卡带封面需要 PNG、JPG 或 HEIC 图片")) }
        let directory = root.appendingPathComponent("Covers", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = key(for: gameURL) + "." + source.pathExtension.lowercased()
        let target = directory.appendingPathComponent(name)
        try? fm.removeItem(at: target); try fm.copyItem(at: source, to: target)
        update(gameURL) { $0.coverFilename = name }
    }

    func saveCartridgeAppearance(for url: URL, cover: UIImage?, replaceCover: Bool,
                                 engraving: String?, color: CartridgeShellColor?) throws {
        let gameKey = key(for: url)
        var preferences = games[gameKey] ?? DuoGamePreferences()
        let oldCover = preferences.coverFilename
        var writtenCover: URL?
        if replaceCover {
            if let cover {
                let scale = min(1, 2048 / max(cover.size.width, cover.size.height))
                let size = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    cover.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let data = resized.pngData() else { throw ROMFiles.Failure(message: String(localized: "无法读取这张封面图片")) }
                let directory = root.appendingPathComponent("Covers", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = gameKey + "-" + UUID().uuidString + ".png"
                let target = directory.appendingPathComponent(name)
                try data.write(to: target, options: .atomic)
                writtenCover = target
                preferences.coverFilename = name
            } else { preferences.coverFilename = nil }
        }
        preferences.cartridgeEngraving = engraving
        preferences.cartridgeColor = color
        var updated = games
        updated[gameKey] = preferences
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: settingsURL, options: .atomic)
        } catch {
            if let writtenCover { try? fm.removeItem(at: writtenCover) }
            throw error
        }
        games = updated
        if replaceCover, let oldCover, oldCover != preferences.coverFilename,
           oldCover.hasPrefix(gameKey), URL(fileURLWithPath: oldCover).lastPathComponent == oldCover {
            try? fm.removeItem(at: root.appendingPathComponent("Covers/" + oldCover))
        }
    }

    #if DEBUG
    func verifyAppearancePersistence() throws {
        let originalGames = games
        let originalData = try? Data(contentsOf: settingsURL)
        let url = root.appendingPathComponent("appearance-validation-" + UUID().uuidString + ".nds")
        let testKey = key(for: url)
        defer {
            games = originalGames
            if let originalData { try? originalData.write(to: settingsURL, options: .atomic) }
            else { try? fm.removeItem(at: settingsURL) }
            let covers = root.appendingPathComponent("Covers")
            for file in (try? fm.contentsOfDirectory(at: covers, includingPropertiesForKeys: nil)) ?? []
                where file.lastPathComponent.hasPrefix(testKey) { try? fm.removeItem(at: file) }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        try saveCartridgeAppearance(for: url, cover: image, replaceCover: true,
                                    engraving: "我的卡带 TEST", color: .threeDSWhite)
        let reloaded = DuoProStore()
        precondition(reloaded.preferences(for: url).cartridgeEngraving == "我的卡带 TEST")
        precondition(reloaded.preferences(for: url).cartridgeColor == .threeDSWhite)
        precondition(reloaded.cover(for: url)?.size == image.size)
        precondition(originalGames.allSatisfy { reloaded.games[$0.key] == $0.value })
        try saveCartridgeAppearance(for: url, cover: nil, replaceCover: true, engraving: nil, color: nil)
        let restored = DuoProStore()
        precondition(restored.preferences(for: url).coverFilename == nil && restored.cover(for: url) == nil)
        precondition(restored.preferences(for: url).cartridgeEngraving == nil && restored.preferences(for: url).cartridgeColor == nil)
        print("DUO_APPEARANCE_PASS: cover, engraving and shell colour survive reload; originals restore; other games preserved")
        fflush(stdout)
    }
    #endif

    func cover(for url: URL) -> UIImage? {
        guard let name = preferences(for: url).coverFilename else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent("Covers/" + name).path)
    }

    func syncWithICloud() async {
        syncStatus = String(localized: "正在同步…")
        guard let cloud = fm.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents/Duo", isDirectory: true) else {
            syncStatus = String(localized: "iCloud Drive 不可用"); return
        }
        do {
            try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
            try merge(root, cloud)
            try merge(ROMFiles.supportDirectory().appendingPathComponent("Saves"), cloud.appendingPathComponent("Saves"))
            try merge(ROMFiles.supportDirectory().appendingPathComponent("N64/Saves"), cloud.appendingPathComponent("N64Saves"))
            try merge(ROMFiles.azaharSaves(ROMFiles.supportDirectory()), cloud.appendingPathComponent("3DSSaves"))
            games = (try? JSONDecoder().decode([String: DuoGamePreferences].self, from: Data(contentsOf: settingsURL))) ?? games
            syncStatus = String(localized: "已同步 · \(Date().formatted(date: .omitted, time: .shortened))")
        } catch { syncStatus = String(localized: "同步失败：\(error.localizedDescription)") }
    }

    private func merge(_ local: URL, _ cloud: URL) throws {
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let localFiles = (fm.enumerator(at: local, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
        let cloudFiles = (fm.enumerator(at: cloud, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
        var relatives = Set(localFiles.map { $0.path.replacingOccurrences(of: local.path + "/", with: "") })
        relatives.formUnion(cloudFiles.map { $0.path.replacingOccurrences(of: cloud.path + "/", with: "") })
        for relative in relatives {
            let lhs = local.appendingPathComponent(relative), rhs = cloud.appendingPathComponent(relative)
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let source = lDate >= rDate ? lhs : rhs, destination = lDate >= rDate ? rhs : lhs
            guard fm.fileExists(atPath: source.path), (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
    }

    func createBackup() throws -> URL {
        let destination = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duo-Backup-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for component in ["Saves", "N64", "DuoPro"] {
            let source = ROMFiles.supportDirectory().appendingPathComponent(component)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: destination.appendingPathComponent(component)) }
        }
        return destination
    }

    private func persist() {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(games).write(to: settingsURL, options: .atomic)
    }
}

struct DuoPaywallView: View {
    @EnvironmentObject private var entitlement: DuoProEntitlement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 58)).foregroundStyle(.yellow)
                Text(String(localized: "Duo 进阶版")).font(.largeTitle.bold())
                Text(String(localized: "高清画质 · 无限存档 · iCloud 同步")).font(.title3.bold()).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) {
                    benefit("square.stack.3d.up.fill", String(localized: "无限即时存档与自动时间线"))
                    benefit("icloud.fill", String(localized: "跨设备同步与备份"))
                    benefit("sparkles.tv.fill", String(localized: "高清画质和高级双屏布局"))
                    benefit("gamecontroller.fill", String(localized: "高级控制、游戏库和实验工具"))
                }.frame(maxWidth: 420)
                Button {
                    Task { await entitlement.purchase() }
                } label: {
                    Text(entitlement.product.map { String(localized: "Lifetime unlock · \($0.displayPrice)") } ?? String(localized: "Loading Price…"))
                        .font(.headline).frame(maxWidth: .infinity).padding()
                }.buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                .disabled(entitlement.product == nil)
                Button(String(localized: "恢复购买")) { Task { await entitlement.restore() } }
                Text(String(localized: "购买后可在使用同一 Apple 账户的设备上恢复。游戏、系统文件与 ROM 不包含在购买中。"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28)
        }
        .navigationTitle(String(localized: "永久解锁"))
        .onChange(of: entitlement.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
        .alert(String(localized: "无法完成购买"), isPresented: Binding(get: { entitlement.purchaseError != nil }, set: { if !$0 { entitlement.purchaseError = nil } })) {
            Button(String(localized: "好")) { entitlement.purchaseError = nil }
        } message: { Text(entitlement.purchaseError ?? "") }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.headline)
    }
}

struct DuoProSettingsView: View {
    @ObservedObject var library: GameLibraryStore
    @EnvironmentObject private var store: DuoProStore
    @State private var backupMessage: String?
    @State private var query = ""
    @State private var filter = 0

    private var filteredGames: [GameLibraryItem] {
        library.games.filter { game in
            let preferences = store.preferences(for: game.url)
            let matchesFilter = filter == 0 || (filter == 1 && preferences.favorite) || (filter == 2 && preferences.completed) || (filter == 3 && !preferences.category.isEmpty && preferences.category != "未分类")
            return matchesFilter && (query.isEmpty || game.title.localizedCaseInsensitiveContains(query) || preferences.category.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section(String(localized: "同步与备份")) {
                Button { Task { await store.syncWithICloud() } } label: { Label(String(localized: "立即同步 iCloud"), systemImage: "icloud.and.arrow.up") }
                Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
                Button {
                    do { backupMessage = String(localized: "备份已保存到文件：\((try store.createBackup()).lastPathComponent)") }
                    catch { backupMessage = error.localizedDescription }
                } label: { Label(String(localized: "创建完整备份"), systemImage: "archivebox") }
            }
            Section(String(localized: "逐游戏设置")) {
                Picker(String(localized: "智能筛选"), selection: $filter) {
                    Text(String(localized: "全部")).tag(0); Text(String(localized: "收藏")).tag(1); Text(String(localized: "已完成")).tag(2); Text(String(localized: "分类")).tag(3)
                }.pickerStyle(.segmented)
                ForEach(filteredGames) { game in
                    NavigationLink { DuoGameProSettingsView(game: game) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.preferences(for: game.url).customTitle.isEmpty ? game.title : store.preferences(for: game.url).customTitle)
                            Text(String(localized: "画质、布局、控制、分类与实验功能")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Menu(String(localized: "批量整理当前结果")) {
                    Button(String(localized: "加入“正在玩”")) { for game in filteredGames { store.update(game.url) { $0.category = "正在玩" } } }
                    Button(String(localized: "加入“稍后游玩”")) { for game in filteredGames { store.update(game.url) { $0.category = "稍后游玩" } } }
                }
            }
        }
        .navigationTitle(String(localized: "Duo 进阶版"))
        .searchable(text: $query, prompt: String(localized: "搜索游戏或分类"))
        .alert(String(localized: "备份"), isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button(String(localized: "好")) { backupMessage = nil }
        } message: { Text(backupMessage ?? "") }
    }
}

struct DuoGameProSettingsView: View {
    let game: GameLibraryItem
    @EnvironmentObject private var store: DuoProStore
    @State private var preferences = DuoGamePreferences()
    @State private var importingSkin = false
    @State private var importingCover = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section(String(localized: "游戏库")) {
                TextField(String(localized: "自定义卡带名称"), text: binding(\.customTitle))
                TextField(String(localized: "分类"), text: binding(\.category))
                Toggle(String(localized: "收藏"), isOn: binding(\.favorite))
                Toggle(String(localized: "标记为已完成"), isOn: binding(\.completed))
                Button(String(localized: "导入自定义卡带封面")) { importingCover = true }
                LabeledContent(String(localized: "游玩时间"), value: duration(preferences.playSeconds))
            }
            Section(String(localized: "高清画质")) {
                Picker(String(localized: "内部画质"), selection: binding(\.resolutionScale)) {
                    Text(String(localized: "高清 4×")).tag(4.0); Text(String(localized: "超清 5×")).tag(5.0); Text(String(localized: "极清 6×")).tag(6.0)
                }.pickerStyle(.segmented)
                Toggle(String(localized: "抗锯齿"), isOn: binding(\.antialiasing))
                Picker(String(localized: "色彩与过滤"), selection: binding(\.videoPreset)) {
                    ForEach(DuoVideoPreset.allCases) { Text($0.title).tag($0) }
                }
            }
            Section(String(localized: "双屏布局")) {
                Picker(String(localized: "布局"), selection: binding(\.layout)) {
                    ForEach(DuoScreenLayout.allCases) { Text($0.title).tag($0) }
                }
                HStack { Text(String(localized: "主屏大小")); Slider(value: binding(\.topScreenScale), in: 0.6...1.4) }
                HStack { Text(String(localized: "触摸屏大小")); Slider(value: binding(\.bottomScreenScale), in: 0.6...1.4) }
            }
            Section(String(localized: "高级控制")) {
                HStack { Text(String(localized: "按键透明度")); Slider(value: binding(\.controlOpacity), in: 0.25...1) }
                HStack { Text(String(localized: "按键大小")); Slider(value: binding(\.controlScale), in: 0.75...1.3) }
                HStack { Text(String(localized: "摇杆灵敏度")); Slider(value: binding(\.stickSensitivity), in: 0.5...1.8) }
                Button(String(localized: "导入控制器皮肤")) { importingSkin = true }
                NavigationLink(String(localized: "按键映射、连发与组合")) { DuoControlMappingView(game: game, preferences: $preferences) }
            }
            Section(String(localized: "金手指")) {
                ForEach($preferences.cheats) { $cheat in
                    VStack(alignment: .leading) {
                        Toggle(isOn: $cheat.enabled) { TextField(String(localized: "名称"), text: $cheat.name) }
                        TextField(String(localized: "代码"), text: $cheat.code, axis: .vertical).font(.system(.caption, design: .monospaced))
                    }
                }.onDelete { preferences.cheats.remove(atOffsets: $0); save() }
                Button(String(localized: "添加金手指")) { preferences.cheats.append(DuoCheat()); save() }
            }
            Section(String(localized: "实验功能")) {
                Picker(String(localized: "CPU/GPU 预设"), selection: binding(\.performancePreset)) {
                    ForEach(DuoPerformancePreset.allCases) { Text($0.title).tag($0) }
                }
                Picker(String(localized: "游戏速度"), selection: binding(\.speed)) {
                    Text("1×").tag(1.0); Text("2×").tag(2.0); Text("3×").tag(3.0)
                }
                Toggle(String(localized: "显示帧率"), isOn: binding(\.showFPS))
                Text(String(localized: "画质、性能和速度设置会在下次启动游戏时完整生效。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(game.title)
        .onAppear { preferences = store.preferences(for: game.url) }
        .onDisappear(perform: save)
        .fileImporter(isPresented: $importingSkin, allowedContentTypes: [.png, .jpeg, .heic]) { result in
            do { try store.importSkin(from: result.get(), gameURL: game.url); preferences = store.preferences(for: game.url) }
            catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingCover, allowedContentTypes: [.png, .jpeg, .heic]) { result in
            do { try store.importCover(from: result.get(), gameURL: game.url); preferences = store.preferences(for: game.url) }
            catch { errorMessage = error.localizedDescription }
        }
        .alert(String(localized: "无法导入皮肤"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好")) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func binding<T>(_ path: WritableKeyPath<DuoGamePreferences, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: path] }, set: { preferences[keyPath: path] = $0; save() })
    }
    private func save() { store.update(game.url) { $0 = preferences } }
    private func duration(_ seconds: TimeInterval) -> String { String(localized: "\(Int(seconds) / 3600) 小时 \((Int(seconds) % 3600) / 60) 分钟") }
}

private struct DuoControlMappingView: View {
    let game: GameLibraryItem
    @Binding var preferences: DuoGamePreferences
    private let buttons: [(String, Int)] = [("A", 1), ("B", 2), ("X", 1024), ("Y", 2048), ("L", 512), ("R", 256), (String(localized: "开始"), 8), (String(localized: "选择"), 4)]

    var body: some View {
        Form {
            Section(String(localized: "连发")) {
                ForEach(buttons, id: \.1) { name, raw in
                    Toggle(name, isOn: Binding(
                        get: { preferences.turboButtons.contains(String(raw)) },
                        set: { if $0 { preferences.turboButtons.insert(String(raw)) } else { preferences.turboButtons.remove(String(raw)) } }
                    ))
                }
            }
            Section(String(localized: "按键组合")) {
                Text(String(localized: "组合键按顺序执行，每个按键间隔 80 毫秒。"))
                Button(String(localized: "添加 A → B 组合")) { preferences.macros["A → B"] = ["1", "2"] }
                ForEach(preferences.macros.keys.sorted(), id: \.self) { Text($0) }
            }
            Section(String(localized: "映射")) {
                Text(String(localized: "选择交换 A/B 或 X/Y，设置仅作用于当前游戏。"))
                Toggle(String(localized: "交换 A / B"), isOn: swapBinding("1", "2"))
                Toggle(String(localized: "交换 X / Y"), isOn: swapBinding("1024", "2048"))
            }
        }.navigationTitle(String(localized: "高级控制"))
    }

    private func swapBinding(_ first: String, _ second: String) -> Binding<Bool> {
        Binding(get: { preferences.buttonMapping[first] == second }, set: {
            if $0 { preferences.buttonMapping[first] = second; preferences.buttonMapping[second] = first }
            else { preferences.buttonMapping[first] = nil; preferences.buttonMapping[second] = nil }
        })
    }
}

struct DuoProGameOverlay: View {
    @ObservedObject var session: EmulatorSession
    let game: GameLibraryItem
    let onExit: () -> Void
    @State private var showingTimeline = false
    @State private var showingSettings = false

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                if session.runtimeConfiguration.preferences.showFPS {
                    Text("\(session.currentFPS, specifier: "%.0f") FPS").font(.caption.monospaced()).padding(8).background(.black.opacity(0.65), in: Capsule())
                }
                Spacer()
                Button { session.saveSnapshot(name: String(localized: "即时存档")) } label: { Image(systemName: "square.and.arrow.down") }
                Button { showingTimeline = true } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                Button(role: .destructive, action: onExit) { Image(systemName: "power") }
            }
            .font(.title3).buttonStyle(.bordered).tint(.white).padding()
            Spacer()
            if !session.runtimeConfiguration.preferences.macros.isEmpty {
                HStack {
                    ForEach(session.runtimeConfiguration.preferences.macros.keys.sorted(), id: \.self) { name in
                        Button(name) { session.playMacro(session.runtimeConfiguration.preferences.macros[name] ?? []) }
                    }
                }.buttonStyle(.borderedProminent).padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showingTimeline) { NavigationStack { DuoSnapshotTimelineView(session: session, game: game) } }
        .sheet(isPresented: $showingSettings) { NavigationStack { DuoRuntimeSettingsView(session: session, game: game) } }
    }
}

private struct DuoRuntimeSettingsView: View {
    @ObservedObject var session: EmulatorSession
    let game: GameLibraryItem
    @EnvironmentObject private var store: DuoProStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Picker(String(localized: "双屏布局"), selection: runtimeBinding(\.layout)) { ForEach(DuoScreenLayout.allCases) { Text($0.title).tag($0) } }
            Picker(String(localized: "画面"), selection: runtimeBinding(\.videoPreset)) { ForEach(DuoVideoPreset.allCases) { Text($0.title).tag($0) } }
            Picker(String(localized: "速度"), selection: runtimeBinding(\.speed)) { Text("1×").tag(1.0); Text("2×").tag(2.0); Text("3×").tag(3.0) }
            Toggle(String(localized: "显示帧率"), isOn: runtimeBinding(\.showFPS))
            Button(String(localized: "应用金手指")) { session.applyCheats() }
        }
        .navigationTitle(String(localized: "游戏设置"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
    }

    private func runtimeBinding<T>(_ path: WritableKeyPath<DuoGamePreferences, T>) -> Binding<T> {
        Binding(get: { session.runtimeConfiguration.preferences[keyPath: path] }, set: { value in
            session.runtimeConfiguration.preferences[keyPath: path] = value
            store.update(game.url) { $0[keyPath: path] = value }
        })
    }
}

private struct DuoSnapshotTimelineView: View {
    @ObservedObject var session: EmulatorSession
    let game: GameLibraryItem
    @EnvironmentObject private var store: DuoProStore
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [DuoSnapshot] = []
    @State private var newName = ""
    @State private var snapshotToRename: DuoSnapshot?
    @State private var renameText = ""

    var body: some View {
        List {
            Section {
                TextField(String(localized: "存档名称"), text: $newName)
                Button(String(localized: "创建即时存档")) {
                    session.saveSnapshot(name: newName.isEmpty ? String(localized: "即时存档") : newName)
                    newName = ""; reload()
                }
            }
            Section(String(localized: "最近游玩时间线")) {
                ForEach(snapshots) { snapshot in
                    Button {
                        session.loadSnapshot(snapshot); dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            if let preview = store.preview(for: snapshot, gameURL: game.url) {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                Image(systemName: "gamecontroller.fill")
                                    .frame(width: 72, height: 48)
                                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.name)
                                Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened) + (snapshot.isAutomatic ? String(localized: " · 自动") : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "重命名"), systemImage: "pencil") {
                            snapshotToRename = snapshot
                            renameText = snapshot.name
                        }
                        Button(String(localized: "删除"), systemImage: "trash", role: .destructive) {
                            try? store.deleteSnapshot(snapshot, gameURL: game.url)
                            reload()
                        }
                    }
                }.onDelete { offsets in
                    for index in offsets { try? store.deleteSnapshot(snapshots[index], gameURL: game.url) }
                    reload()
                }
            }
        }
        .navigationTitle(String(localized: "即时存档"))
        .onAppear(perform: reload)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
        .alert(String(localized: "重命名即时存档"), isPresented: Binding(get: { snapshotToRename != nil }, set: { if !$0 { snapshotToRename = nil } })) {
            TextField(String(localized: "存档名称"), text: $renameText)
            Button(String(localized: "取消"), role: .cancel) { snapshotToRename = nil }
            Button(String(localized: "保存")) {
                if let snapshot = snapshotToRename, !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? store.renameSnapshot(snapshot, gameURL: game.url, name: renameText)
                    reload()
                }
                snapshotToRename = nil
            }
        }
    }
    private func reload() { snapshots = store.snapshots(for: game.url) }
}

struct DuoFlexibleGameLayout: View {
    let topImage: CGImage
    let bottomImage: CGImage
    @ObservedObject var session: EmulatorSession

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                switch session.runtimeConfiguration.preferences.layout {
                case .stacked:
                    VStack(spacing: 8) {
                        screen(topImage, touch: false).scaleEffect(session.runtimeConfiguration.preferences.topScreenScale)
                        screen(bottomImage, touch: true).scaleEffect(session.runtimeConfiguration.preferences.bottomScreenScale)
                    }
                case .sideBySide:
                    HStack(spacing: 8) {
                        screen(topImage, touch: false).scaleEffect(session.runtimeConfiguration.preferences.topScreenScale)
                        screen(bottomImage, touch: true).scaleEffect(session.runtimeConfiguration.preferences.bottomScreenScale)
                    }
                case .topOnly:
                    screen(topImage, touch: false).scaleEffect(session.runtimeConfiguration.preferences.topScreenScale)
                case .bottomOnly:
                    screen(bottomImage, touch: true).scaleEffect(session.runtimeConfiguration.preferences.bottomScreenScale)
                case .pictureInPicture:
                    screen(topImage, touch: false).scaleEffect(session.runtimeConfiguration.preferences.topScreenScale)
                    screen(bottomImage, touch: true).frame(width: proxy.size.width * 0.38).scaleEffect(session.runtimeConfiguration.preferences.bottomScreenScale).position(x: proxy.size.width * 0.77, y: proxy.size.height * 0.75)
                        .shadow(radius: 8)
                case .console: EmptyView()
                }
                if let skin = session.currentROMURL.flatMap({ DuoProStore.shared.skin(for: $0) }) {
                    Image(uiImage: skin).resizable().scaledToFill().opacity(session.runtimeConfiguration.preferences.controlOpacity).allowsHitTesting(false)
                }
                DuoCompactControls(session: session)
                    .opacity(session.runtimeConfiguration.preferences.controlOpacity)
                    .scaleEffect(session.runtimeConfiguration.preferences.controlScale)
            }
        }
    }

    @ViewBuilder private func screen(_ image: CGImage, touch: Bool) -> some View {
        GeometryReader { proxy in
            let content = Image(image, scale: 1, orientation: .up, label: Text(String(localized: "游戏画面")))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .saturation(session.runtimeConfiguration.preferences.videoPreset == .vivid ? 1.28 : 1)
                .contrast(session.runtimeConfiguration.preferences.videoPreset == .sharp ? 1.16 : 1)
                .contentShape(Rectangle())
            if touch {
                content.gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    session.touch(at: value.location, in: proxy.size)
                }.onEnded { _ in session.releaseTouch() })
            } else { content }
        }
    }
}

private struct DuoCompactControls: View {
    @ObservedObject var session: EmulatorSession
    var body: some View {
        VStack {
            Spacer()
            HStack {
                VStack(spacing: 2) {
                    button("▲", .up)
                    HStack(spacing: 16) { button("◀", .left); button("▶", .right) }
                    button("▼", .down)
                }
                Spacer()
                HStack(spacing: 14) { button("Y", .y); button("X", .x); button("B", .b); button("A", .a) }
            }.padding(24)
        }
    }
    private func button(_ title: String, _ input: MelonDSGameInput) -> some View {
        Text(title).font(.headline).frame(width: 44, height: 44).background(.black.opacity(0.55), in: Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in session.press(input) }.onEnded { _ in session.release(input) })
    }
}

@MainActor
final class DuoExternalDisplayCoordinator {
    static let shared = DuoExternalDisplayCoordinator()
    private weak var session: EmulatorSession?
    private var window: UIWindow?

    private init() {
        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let screen = note.object as? UIScreen else { return }
            Task { @MainActor in self?.show(on: screen) }
        }
        NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }
    }

    func attach(_ session: EmulatorSession, enabled: Bool) {
        self.session = enabled ? session : nil
        guard enabled, let screen = UIScreen.screens.dropFirst().first else { window?.isHidden = true; window = nil; return }
        show(on: screen)
    }

    private func show(on screen: UIScreen) {
        guard let session else { return }
        let externalWindow = UIWindow(frame: screen.bounds)
        externalWindow.screen = screen
        externalWindow.rootViewController = UIHostingController(rootView: DuoExternalTopScreen(session: session))
        externalWindow.isHidden = false
        window = externalWindow
    }
}

private struct DuoExternalTopScreen: View {
    @ObservedObject var session: EmulatorSession
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = session.topImage {
                Image(image, scale: 1, orientation: .up, label: Text(String(localized: "主游戏画面")))
                    .resizable().interpolation(.high).scaledToFit()
            } else { ProgressView() }
        }
    }
}
