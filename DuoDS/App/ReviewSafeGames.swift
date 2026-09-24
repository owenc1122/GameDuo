import CryptoKit
import Foundation
import SceneKit

// MARK: - Detection

/// The open-source test games handed to App Review. While one of them is the game on screen, the
/// app shows no Sony / Nintendo marks: no brand prints on the cartridge / UMD, the retail case, the
/// case insert or the console models, and a neutral platform line in the library
/// (Handheld_Cases/REVIEW_SAFE_AUDIT.md). Every other game keeps its normal presentation.
///
/// A game is identified by the SHA-256 of its ROM file (the file `GameLibraryItem.url` points at),
/// never by its title or file name. Hashing only happens for files whose byte count equals one of
/// the entries below, off the main thread, and the result is cached by path + size + modification
/// date (in memory and in `UserDefaults`), so the library never waits on it.
enum ReviewSafeGames {
    struct Entry: Sendable {
        let name: String
        /// Exact file size: files of any other size are never hashed.
        let byteCount: Int64
        /// Lowercase hex SHA-256 of the whole file.
        let sha256: String
    }

    /// One line per ROM file that can end up as a library game's `url`.
    static let entries: [Entry] = [
        // TestFixtures/TrailMix.nds (TrailMix-LICENSE.md; bundled in Debug builds).
        Entry(name: "Trail Mix 3.1.1 (NDS, MIT)", byteCount: 4_640_768,
              sha256: "f1977761145771a06270a6fb0650aac65ab008d3a8be05f2655782b606009d3f"),
        // The older release that GameLibraryStore.upgradeKnownBuggyTrailMix replaces in place.
        Entry(name: "Trail Mix 3.0.0 (NDS, MIT)", byteCount: 4_715_520,
              sha256: "f83cdf6ef9f63d6c7d665e980b0c77e818f0d82a24bd2c5eee3a6d5aff4f5e1f"),
        // TestFixtures/3DS/Mars3D.3dsx (bundled in Debug builds as Mars3D.3dsx).
        Entry(name: "Mars3DS (3DS homebrew, MIT)", byteCount: 713_384,
              sha256: "00fb87d97ecb866a99902740ab67e38e05f81d74295e0c3774eb62b90b0a335b"),
        // TestFixtures/PSP/2048/EBOOT.PBP (SOURCE.md). Importing the release zip keeps this EBOOT.PBP.
        Entry(name: "2048 for PSP 1.0.0 (EBOOT.PBP, MIT)", byteCount: 168_079,
              sha256: "d981baac8a8e7e5662f9ffaaf99de806f5e4c814c3def8b1caa7faae743ea2a2"),
    ]

    private static let knownSizes = Set(entries.map(\.byteCount))
    private static let knownHashes = Set(entries.map(\.sha256))

    /// True while `game` is one of the review test games. Never blocks: a file whose size matches
    /// an entry but whose hash is not known yet counts as review-safe until `warmUp` has hashed it.
    static func isReviewSafe(_ game: GameLibraryItem) -> Bool {
        isReviewSafe(url: game.url)
    }

    static func isReviewSafe(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return Cache.shared.status(path: url.standardizedFileURL.path).safe
    }

    /// Hashes the files that need it (off the calling thread) and returns the standardized paths
    /// whose `isReviewSafe` answer changed, so their cards can be rebuilt.
    static func warmUp(_ urls: [URL]) async -> Set<String> {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            var changed = Set<String>()
            for path in paths {
                let before = Cache.shared.status(path: path).safe
                Cache.shared.resolve(path: path)
                if Cache.shared.status(path: path).safe != before { changed.insert(path) }
            }
            Cache.shared.persist()
            return changed
        }.value
    }

    /// Streams the file through SHA-256 (1 MiB at a time).
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20) else { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func isKnown(size: Int64) -> Bool { knownSizes.contains(size) }
    fileprivate static func isKnown(sha256: String) -> Bool { knownHashes.contains(sha256) }

    /// Path → (size, modification date, hash) memo shared by the main thread and `warmUp`.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()

        struct Record: Codable {
            var size: Int64
            var modified: Double
            /// nil: not hashed (size is not a test-game size, or hashing is pending / failed).
            var sha256: String?
        }

        struct Status {
            /// Review-safe presentation: a known hash, or a known size still waiting for its hash.
            var safe: Bool
        }

        private static let defaultsKey = "reviewSafeGames.hashes.v1"
        private let lock = NSLock()
        private var records: [String: Record]

        private init() {
            if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
               let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
                records = decoded
            } else {
                records = [:]
            }
        }

        private static func stat(_ path: String) -> (size: Int64, modified: Double)? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return (size, modified)
        }

        /// The cached answer; a path seen for the first time is sized (one `stat`) but not hashed.
        func status(path: String) -> Status {
            lock.lock()
            let record = records[path]
            lock.unlock()
            if let record { return Self.status(of: record) }
            guard let info = Self.stat(path) else { return Status(safe: false) }
            let fresh = Record(size: info.size, modified: info.modified, sha256: nil)
            lock.lock()
            if records[path] == nil { records[path] = fresh }
            let stored = records[path] ?? fresh
            lock.unlock()
            return Self.status(of: stored)
        }

        private static func status(of record: Record) -> Status {
            guard ReviewSafeGames.isKnown(size: record.size) else { return Status(safe: false) }
            guard let hash = record.sha256 else { return Status(safe: true) }  // pending
            return Status(safe: ReviewSafeGames.isKnown(sha256: hash))
        }

        /// Re-checks size and date, and hashes the file when its size is a test-game size and no
        /// hash is cached for this size and date. Call off the main thread.
        func resolve(path: String) {
            guard let info = Self.stat(path) else {
                lock.lock(); records[path] = nil; lock.unlock()
                return
            }
            lock.lock()
            let cached = records[path]
            lock.unlock()
            if let cached, cached.size == info.size, cached.modified == info.modified,
               cached.sha256 != nil || !ReviewSafeGames.isKnown(size: info.size) { return }
            var record = Record(size: info.size, modified: info.modified, sha256: nil)
            if ReviewSafeGames.isKnown(size: info.size) {
                // A failed read keeps the record pending (review-safe) rather than exposing marks.
                record.sha256 = ReviewSafeGames.sha256(of: URL(fileURLWithPath: path))
            }
            lock.lock(); records[path] = record; lock.unlock()
        }

        /// Only hashed records are worth keeping across launches.
        func persist() {
            lock.lock()
            let hashed = records.filter { $0.value.sha256 != nil }
            lock.unlock()
            if let data = try? JSONEncoder().encode(hashed) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }
}

// MARK: - Scene neutralisation

/// Node and material rules for the review-safe presentation (Handheld_Cases/REVIEW_SAFE_AUDIT.md).
enum ReviewSafeScene {
    /// Library media and retail cases, which are built per game: nodes whose names start with one
    /// of these are hidden in the review-safe build of the scene.
    static let mediumAndCasePrefixes = [
        // Detailed-Cartridges.usdz (every card kind): front "NINTENDO DS" / "NINTENDO 3DS" moulding,
        // back "Nintendo" maker mark, back "NTR-005" / "CTR-005" model number.
        "Front_platform", "Back_maker_mark", "Molded_model_number",
        // PSP-UMD.usdz: "PSP" logo and gamepad mark on the shell, "UMD" lettering on the centre badge.
        "PSP_shell_vector", "Gamepad___photo_traced_shell_mark", "UMD_shell_vector",
        // NDS-Case / 3DS-Case / PSP-UMD-Case.usdz moulded "NINTENDO DS", "Nintendo", "Nintendo 3DS", "UMD".
        "TRADEMARK_PRINTS",
    ]

    static func hideTrademarkNodes(in root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let name = node.name, mediumAndCasePrefixes.contains(where: name.hasPrefix) else { return }
            node.isHidden = true
        }
    }

    // Consoles: one scene serves every game, so these rules are applied and undone per selection.

    /// 3DSXL-Cartridge-Open-Transition.usdz underside legends: "Nintendo", "NINTENDO 3DS XL",
    /// "SPR-001", battery "SPR-003", ratings.
    private static let consoleHiddenNodes: Set<String> = [
        "Underside_·_Manufacturer", "Underside_·_Model_name", "Underside_·_Model_number",
        "Underside_·_Battery_type", "Underside_·_Power_rating",
    ]

    private struct MaterialSwap {
        /// Materials whose names start with one of these are replaced …
        let from: [String]
        /// … by the material of the same geometry whose name starts with this (skipped when absent),
        /// or, when nil, by an invisible material.
        let to: String?
        /// Only below nodes with these names (nil: anywhere).
        let under: Set<String>?
    }

    private static let consoleSwaps = [
        // PSP2000-UMD-Open-Transition.usdz housing and UMD door: "SONY" (front and back), the
        // PlayStation logo, the "PSP" logo (front and door), "UMD", and the printed small legends
        // (VOL, POWER, HOLD, WLAN / memory icons) that share the same print material.
        MaterialSwap(from: ["Logo___", "Print___"], to: "Shell___Ice_Silver", under: nil),
        // PSP face buttons: the triangle / circle / cross / square glyphs (separate flat shapes inside
        // the clear caps; left out, the caps read as plain buttons).
        MaterialSwap(from: ["Controls___charcoal_original_glyphs"], to: nil,
                     under: ["BUTTON_CROSS", "BUTTON_CIRCLE", "BUTTON_SQUARE", "BUTTON_TRIANGLE"]),
    ]

    private static let invisible: SCNMaterial = {
        let material = SCNMaterial()
        material.name = "DUO_REVIEW_SAFE_INVISIBLE"
        material.transparency = 0
        material.writesToDepthBuffer = false
        material.colorBufferWriteMask = []
        return material
    }()

    private static let stateKey = "duoReviewSafeState"
    private static let hiddenKey = "duoReviewSafeOriginalHidden"
    private static let geometryKey = "duoReviewSafeOriginalGeometry"

    /// Shows (`safe`) or undoes the review-safe console: hides the underside legends and repaints
    /// the brand prints with the surrounding material. Cheap when nothing changes.
    static func applyConsole(_ safe: Bool, to root: SCNNode) {
        if (root.value(forKey: stateKey) as? Bool) == safe { return }
        root.setValue(safe, forKey: stateKey)
        root.enumerateHierarchy { node, _ in
            if let name = node.name, consoleHiddenNodes.contains(name) {
                if safe {
                    if node.value(forKey: hiddenKey) == nil { node.setValue(node.isHidden, forKey: hiddenKey) }
                    node.isHidden = true
                } else if let original = node.value(forKey: hiddenKey) as? Bool {
                    node.isHidden = original
                    node.setValue(nil, forKey: hiddenKey)
                }
            }
            if safe {
                guard node.value(forKey: geometryKey) == nil, let geometry = node.geometry,
                      let neutral = neutralMaterials(for: node, geometry: geometry) else { return }
                let copy = geometry.copy() as! SCNGeometry
                copy.materials = neutral
                node.setValue(geometry, forKey: geometryKey)
                node.geometry = copy
            } else if let original = node.value(forKey: geometryKey) as? SCNGeometry {
                node.geometry = original
                node.setValue(nil, forKey: geometryKey)
            }
        }
    }

    /// Forget the cached state of `root` (its children were replaced), so the next
    /// `applyConsole` walks the hierarchy again.
    static func invalidate(_ root: SCNNode) {
        root.setValue(nil, forKey: stateKey)
    }

    private static func neutralMaterials(for node: SCNNode, geometry: SCNGeometry) -> [SCNMaterial]? {
        var materials = geometry.materials
        var changed = false
        for swap in consoleSwaps {
            if let under = swap.under, !hasAncestor(node, named: under) { continue }
            let replacement: SCNMaterial
            if let to = swap.to {
                guard let sibling = materials.first(where: { $0.name?.hasPrefix(to) == true }) else { continue }
                replacement = sibling
            } else {
                replacement = invisible
            }
            for index in materials.indices {
                guard let name = materials[index].name, swap.from.contains(where: name.hasPrefix) else { continue }
                materials[index] = replacement
                changed = true
            }
        }
        return changed ? materials : nil
    }

    private static func hasAncestor(_ node: SCNNode, named names: Set<String>) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, names.contains(name) { return true }
            current = candidate.parent
        }
        return false
    }
}
