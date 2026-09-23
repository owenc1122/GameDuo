import Foundation

/// Import and launch share the same content checks. Filename suffixes are hints only.
enum ROMFiles {
    static let archives: Set<String> = ["zip", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz"]
    static let nds: Set<String> = ["nds", "dsi", "ids", "srl"]
    static let threeDS: Set<String> = ["3ds", "cci", "cxi", "app", "3dsx", "elf", "axf", "zcci", "zcxi", "z3dsx"]
    static let n64: Set<String> = ["z64", "n64", "v64"]
    static let psp: Set<String> = ["iso", "cso", "chd", "pbp", "prx", "pspelf"]
    static let packages: Set<String> = ["cia", "zcia", "ciax"]
    static let saves: Set<String> = ["sav", "dsv", "srm", "ppst"]
    /// Disc images whose platform (PS2 or PSP) is decided by content; `.bin` / `.cue` are PS2-only.
    static let discImages: Set<String> = ["iso", "cso", "chd", "bin", "cue"]
    static let ps2Only: Set<String> = ["bin", "cue"]
    static let accepted = archives.union(nds).union(threeDS).union(n64).union(psp).union(packages).union(saves).union(["bin", "cue", "o2r"])

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return archives.contains(url.pathExtension.lowercased()) ||
            [".tar.gz", ".tar.bz2", ".tar.xz"].contains { name.hasSuffix($0) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func header(_ url: URL, count: Int = 512) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    static func little32(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return (0..<4).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }

    static func canonicalExtension(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw Failure(message: String(localized: "文件为空或不是普通文件"))
        }
        if let name = systemFilename(url) {
            let valid: Bool
            switch name {
            case "bios7.bin": valid = size == 16384
            case "bios9.bin": valid = size == 4096
            case "dsi_bios7.bin", "dsi_bios9.bin": valid = size == 65536
            case "firmware.bin": valid = [131072, 262144, 524288].contains(size)
            case "dsifirmware.bin": valid = [131072, 262144, 524288].contains(size)
            default:
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasFooter = false
                if size > 1024 * 1024 {
                    for offset in [UInt64(size - 64), UInt64(0xff800)] {
                        try handle.seek(toOffset: offset)
                        if try handle.read(upToCount: 16) == Data("DSi eMMC CID/CPU".utf8) + Data([0]) { hasFooter = true }
                    }
                }
                valid = hasFooter
            }
            guard valid else { throw Failure(message: String(localized: "系统文件 \(name) 的大小或标识不正确，请使用自己主机的完整导出")) }
            return "system"
        }
        let h = try header(url)
        let ext = url.pathExtension.lowercased()
        if ext == "ppst" {
            guard h.count >= 48 else { throw Failure(message: String(localized: "PSP 即时存档文件头不完整")) }
            let revision = little32(h, 0)
            let compression = little32(h, 4)
            let payloadSize = little32(h, 8)
            let headerSize: UInt64 = revision >= 5 ? 176 : 48
            guard revision >= 4, compression <= 2, UInt64(size) == headerSize + payloadSize else {
                throw Failure(message: String(localized: "PSP 即时存档结构无效或文件已截断"))
            }
            return "save"
        }
        if saves.contains(ext) {
            guard size <= 128 * 1024 * 1024 else { throw Failure(message: String(localized: "存档文件过大，可能不是有效的模拟器存档")) }
            return "save"
        }
        let magic = Array(h.prefix(4))
        if ext == "cso", magic == Array("CISO".utf8) {
            guard h.count >= 24, little32(h, 4) >= 24, little32(h, 16) > 0 else {
                throw Failure(message: String(localized: "PSP CSO 文件头不完整"))
            }
            return "cso"
        }
        if ext == "chd", h.prefix(8) == Data("MComprHD".utf8) {
            guard size >= 124 else { throw Failure(message: String(localized: "PSP CHD 文件已截断")) }
            return "chd"
        }
        if ext == "pbp", magic == [0x00, 0x50, 0x42, 0x50] {
            guard h.count >= 40 else { throw Failure(message: String(localized: "PSP PBP 文件头不完整")) }
            let offsets = stride(from: 8, through: 36, by: 4).map { little32(h, $0) }
            guard offsets.first == 40, zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
                  offsets.last.map({ $0 <= UInt64(size) }) == true,
                  offsets[6] < UInt64(size) else {
                throw Failure(message: String(localized: "PSP PBP 分区表无效"))
            }
            return "pbp"
        }
        // Signed/encrypted PSP executables use the ~PSP container instead of
        // a plain MIPS ELF header. PPSSPP performs the cryptographic and
        // module validation when it loads the file.
        if ext == "prx", magic == Array("~PSP".utf8) {
            guard size >= 0x150 else { throw Failure(message: String(localized: "PSP PRX 文件头不完整")) }
            return "prx"
        }
        if ext == "iso" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0x8001)
            let identifier = try handle.read(upToCount: 5) ?? Data()
            guard identifier == Data("CD001".utf8), size >= 0x9000 else {
                throw Failure(message: String(localized: "PSP ISO 缺少有效的 ISO 9660 卷标识"))
            }
            return "iso"
        }
        if ext == "cue" {
            guard case .ps2 = ps2DiscKind(url) else {
                throw Failure(message: String(localized: "CUE 文件引用的 BIN 缺失，或不是 PS2 游戏光盘"))
            }
            return "cue"
        }
        // Raw 2352-byte sectors start with the CD sync pattern; only those can be PS2 BIN images.
        if ext == "bin", h.count >= 12, h.prefix(12) == Data([0x00] + [UInt8](repeating: 0xff, count: 10) + [0x00]),
           case .ps2 = ps2DiscKind(url) {
            return "bin"
        }
        if [[0x80,0x37,0x12,0x40], [0x37,0x80,0x40,0x12], [0x40,0x12,0x37,0x80]].contains(magic) {
            guard size >= 4096, size <= 128 * 1024 * 1024, size % 4 == 0 else { throw Failure(message: String(localized: "N64 ROM 大小异常或文件已截断")) }
            return "z64"
        }
        if magic == Array("3DSX".utf8) {
            guard h.count >= 32, little32(h, 16) > 0 else { throw Failure(message: String(localized: "3DSX 文件头不完整")) }
            return "3dsx"
        }
        if magic == [0x7f,0x45,0x4c,0x46] {
            guard h.count >= 52, h[4] == 1, h[5] == 1 else { throw Failure(message: String(localized: "需要 32 位小端 ELF 文件")) }
            let machine = UInt16(h[18]) | UInt16(h[19]) << 8
            if machine == 8 { return ext == "prx" ? "prx" : "pspelf" }
            guard machine == 40 else { throw Failure(message: String(localized: "ELF 既不是 3DS ARM 程序，也不是 PSP MIPS 程序")) }
            return "elf"
        }
        if h.count >= 0x104 {
            let container = String(data: h[0x100..<0x104], encoding: .ascii)
            if container == "NCSD" { return "cci" }
            if container == "NCCH" { return "cxi" }
        }
        // Azahar Z3DS containers are validated by its seekable Zstandard reader at load/install.
        if ["zcci", "zcxi", "z3dsx", "zcia", "ciax"].contains(ext), magic == Array("Z3DS".utf8) {
            guard magic == Array("Z3DS".utf8), size >= 32, h[8] == 1,
                  h[10] == 32, h[11] == 0, little32(h, 12) <= 32 * 1024 * 1024,
                  UInt64(32) + little32(h, 12) < UInt64(size) else { throw Failure(message: String(localized: "3DS 压缩容器标识无效")) }
            return ext == "ciax" ? "zcia" : ext
        }
        if ["cia", "ciax"].contains(ext), h.count >= 32, little32(h, 0) == 0x2020, size >= 0x2020 {
            return "cia"
        }
        if h.count >= 0x160, [0, 2, 3].contains(h[0x12]) {
            let arm9 = little32(h, 0x20), arm9Size = little32(h, 0x2c)
            let arm7 = little32(h, 0x30), arm7Size = little32(h, 0x3c)
            if arm9 >= 0x200, arm7 >= 0x200, arm9Size > 0, arm7Size > 0,
               arm9 + arm9Size <= size, arm7 + arm7Size <= size { return "nds" }
        }
        if ext == "o2r", magic == [0x50, 0x4b, 0x03, 0x04] { return "o2r" }
        throw Failure(message: String(localized: "无法识别完整的 DS、3DS、N64、PSP 或 PS2 游戏内容（.\(ext)）；存档、补丁和 BIOS 不能当作游戏启动"))
    }

    // MARK: PS2 / PSP disc content

    private static let discKindCache = DiscKindCache()

    /// `PS2DiscProbe.identify`, memoised per path + size + modification date (probing reads a few hundred KB).
    static func ps2DiscKind(_ url: URL) -> PS2DiscKind {
        let ext = url.pathExtension.lowercased()
        guard discImages.contains(ext) else { return .unknown }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var key = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if ext == "cue" {
            // A cue's answer depends on its data track too.
            for file in cueReferencedFiles(url) {
                let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                key += "|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
        }
        if let cached = discKindCache.value(for: key) { return cached }
        let kind = PS2DiscProbe.identify(url: url)
        discKindCache.set(kind, for: key)
        return kind
    }

    static func isPS2Disc(_ url: URL) -> Bool {
        if case .ps2 = ps2DiscKind(url) { return true }
        return false
    }

    /// Files named by a cue sheet's `FILE` lines, resolved next to the cue (existing or not).
    static func cueReferencedFiles(_ cueURL: URL) -> [URL] {
        guard let data = try? Data(contentsOf: cueURL), data.count <= 256 * 1024 else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let directory = cueURL.deletingLastPathComponent()
        return text.components(separatedBy: .newlines).compactMap { raw -> URL? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("FILE ") else { return nil }
            var rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name: String
            if rest.hasPrefix("\"") {
                rest.removeFirst()
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                name = String(rest[..<end])
            } else {
                // Unquoted: drop the trailing file type (BINARY, MOTOROLA, …).
                var parts = rest.split(separator: " ")
                if parts.count > 1 { parts.removeLast() }
                name = parts.joined(separator: " ")
            }
            let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            return last.isEmpty ? nil : directory.appendingPathComponent(last, isDirectory: false)
        }
    }

    static func systemFilename(_ url: URL) -> String? {
        let names = ["bios7.bin": "bios7.bin", "bios9.bin": "bios9.bin",
                     "dsibios7.bin": "dsi_bios7.bin", "dsi_bios7.bin": "dsi_bios7.bin",
                     "dsibios9.bin": "dsi_bios9.bin", "dsi_bios9.bin": "dsi_bios9.bin",
                     "firmware.bin": "firmware.bin", "dsifirmware.bin": "dsifirmware.bin",
                     "dsi_firmware.bin": "dsifirmware.bin", "dsinand.bin": "dsi_nand.bin",
                     "dsi_nand.bin": "dsi_nand.bin"]
        return names[url.lastPathComponent.lowercased()]
    }

    static func normalizeN64(_ source: URL, to destination: URL) throws {
        var data = try Data(contentsOf: source)
        let magic = Array(data.prefix(4))
        if magic == [0x37,0x80,0x40,0x12] {
            for i in stride(from: 0, to: data.count, by: 2) { data.swapAt(i, i + 1) }
        } else if magic == [0x40,0x12,0x37,0x80] {
            for i in stride(from: 0, to: data.count, by: 4) { data.swapAt(i, i + 3); data.swapAt(i + 1, i + 2) }
        }
        try data.write(to: destination, options: .atomic)
    }

    static func isMarioKartUSA(_ url: URL) throws -> Bool {
        let h = try header(url)
        return h.count >= 64 && String(data: h[0x20..<0x34], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) == "MARIOKART64"
            && h[0x3e] == 0x45
    }

    static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static func azaharSaves(_ support: URL) -> URL { support.appendingPathComponent("Azahar/Saves", isDirectory: true) }
    static func mk64Directory(_ support: URL) -> URL { azaharSaves(support).appendingPathComponent("Azahar/sdmc/3ds/MK64", isDirectory: true) }

    /// Every archive is fully extracted and checked before any file is added to the library.
    static func prepare(_ source: URL, in staging: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if isArchive(source) {
            try ROMArchive.extractURL(source, toDirectory: staging)
            guard let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            let files = enumerator.allObjects.compactMap { $0 as? URL }.filter {
                !$0.pathComponents.contains("__MACOSX") && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            if files.contains(where: { isArchive($0) }) {
                throw Failure(message: String(localized: "包内还有压缩包，请先展开嵌套压缩包再导入"))
            }
            return files.filter {
                guard accepted.contains($0.pathExtension.lowercased()) else { return false }
                // .bin is also a common companion-data suffix; only dispatch recognized content.
                if $0.pathExtension.lowercased() == "bin", systemFilename($0) == nil {
                    return (try? canonicalExtension($0)) != nil
                }
                return true
            }.sorted { $0.path < $1.path }
        }
        let copy = staging.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        return [copy]
    }
}

private final class DiscKindCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PS2DiscKind] = [:]

    func value(for key: String) -> PS2DiscKind? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ kind: PS2DiscKind, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if storage.count > 512 { storage.removeAll() }
        storage[key] = kind
    }
}
