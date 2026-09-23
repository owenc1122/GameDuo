import Compression
import Foundation

/// What a disc image contains, decided by content rather than file extension.
enum PS2DiscKind: Equatable {
    /// `SYSTEM.CNF` with a `BOOT2` line. `serial` is e.g. `SLUS-20312` (nil for discs like demos that boot a plain ELF).
    case ps2(serial: String?, bootPath: String)
    /// `PSP_GAME/PARAM.SFO` present; `discID` is the raw `DISC_ID` value (e.g. `ULUS10041`).
    case psp(discID: String?)
    /// Anything else, including PS1 discs (`BOOT =`), unreadable files and CHD images.
    case unknown
}

/// Identifies PS2 / PSP disc images.
///
/// Supported containers: plain ISO (2048-byte sectors), raw 2352-byte images (`.bin`, MODE1 or MODE2 form 1,
/// detected by the CD sync pattern), `.cue` (first data track's FILE), and CSO v1 (raw-deflate blocks; v2
/// deflate blocks work too, LZ4 blocks do not). CHD (`MComprHD`) is only recognised and reported as `.unknown`:
/// its hunks are zlib/LZMA/FLAC-compressed behind a compressed hunk map, which is not worth implementing
/// just to read `SYSTEM.CNF`.
///
/// I/O is bounded: only the volume descriptors, the root (and `PSP_GAME`) directory and two small files are read.
enum PS2DiscProbe {
    static func identify(url: URL) -> PS2DiscKind {
        identify(url: url, depth: 0)
    }

    /// Parses `SYSTEM.CNF`. Returns nil unless there is a non-empty `BOOT2` entry (PS1 discs use `BOOT`).
    static func parseSystemCnf(_ text: String) -> (serial: String?, bootPath: String)? {
        for rawLine in text.components(separatedBy: .newlines) {
            guard let eq = rawLine.firstIndex(of: "=") else { continue }
            let key = rawLine[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            guard key == "BOOT2" else { continue }
            let value = rawLine[rawLine.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
            guard !value.isEmpty else { return nil }
            return (normalizedSerial(fromBootPath: value), value)
        }
        return nil
    }

    /// `cdrom0:\SLUS_203.12;1` → `SLUS-20312`. Returns nil when the boot file is not a `XXXX_DDD.DD` serial.
    static func normalizedSerial(fromBootPath path: String) -> String? {
        let last = path.split(whereSeparator: { $0 == "\\" || $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let name = String(last.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .filter { !$0.isWhitespace && $0 != "\0" }
            .uppercased()
        let chars = Array(name)
        guard chars.count >= 9, chars.prefix(4).allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var rest = chars.dropFirst(4)
        if rest.first == "_" || rest.first == "-" { rest = rest.dropFirst() }
        let body = String(rest)
        let isDigits: (Substring) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let digits: String
        if parts.count == 2, parts[0].count == 3, parts[1].count == 2, isDigits(parts[0]), isDigits(parts[1]) {
            digits = String(parts[0] + parts[1])
        } else if parts.count == 1, body.count == 5, isDigits(Substring(body)) {
            digits = body
        } else {
            return nil
        }
        return String(chars.prefix(4)) + "-" + digits
    }

    // MARK: - Container detection

    private static let maxDirectoryBytes = 256 * 1024
    private static let maxSmallFileBytes = 64 * 1024

    private static func identify(url: URL, depth: Int) -> PS2DiscKind {
        if url.pathExtension.lowercased() == "cue" {
            guard depth == 0, let track = CueSheet.firstDataTrack(cueURL: url) else { return .unknown }
            guard let file = FileReader(url: track.url) else { return .unknown }
            let raw = RawSectorSource(file: file, base: track.byteOffset, sectorSize: track.sectorSize)
            return probeISO(raw ?? PlainSectorSource(file: file, base: track.byteOffset))
        }
        guard let file = FileReader(url: url), let head = file.read(at: 0, count: 16), head.count == 16 else { return .unknown }
        if head.starts(with: Array("MComprHD".utf8)) { return .unknown }
        if head.starts(with: Array("CISO".utf8)) {
            guard let cso = CSOSectorSource(file: file) else { return .unknown }
            return probeISO(cso)
        }
        if let raw = RawSectorSource(file: file, base: 0, sectorSize: 2352) { return probeISO(raw) }
        return probeISO(PlainSectorSource(file: file, base: 0))
    }

    // MARK: - ISO9660

    private struct DirEntry {
        let name: String  // uppercased, version (";1") and trailing "." stripped
        let lba: Int
        let size: Int
        let isDirectory: Bool
    }

    private static func probeISO(_ source: SectorSource) -> PS2DiscKind {
        guard let root = rootDirectory(source), let entries = readDirectory(source, root) else { return .unknown }
        if let cnf = entries.first(where: { !$0.isDirectory && $0.name == "SYSTEM.CNF" }),
           let data = readFile(source, cnf, limit: maxSmallFileBytes),
           let parsed = parseSystemCnf(String(decoding: data, as: UTF8.self)) {
            return .ps2(serial: parsed.serial, bootPath: parsed.bootPath)
        }
        if let pspDir = entries.first(where: { $0.isDirectory && $0.name == "PSP_GAME" }),
           let pspEntries = readDirectory(source, pspDir),
           let sfo = pspEntries.first(where: { !$0.isDirectory && $0.name == "PARAM.SFO" }) {
            let discID = readFile(source, sfo, limit: maxSmallFileBytes)
                .flatMap { paramSFOString($0, key: "DISC_ID") }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .psp(discID: discID?.isEmpty == false ? discID : nil)
        }
        return .unknown
    }

    /// Scans volume descriptors from sector 16 for the primary one and returns its root directory record.
    private static func rootDirectory(_ source: SectorSource) -> DirEntry? {
        for lba in 16..<32 {
            guard let s = source.sector(lba), s.count == 2048 else { return nil }
            guard s[s.startIndex + 1..<s.startIndex + 6].elementsEqual("CD001".utf8) else { return nil }
            switch s[s.startIndex] {
            case 1: return parseRecord(s, at: 156).flatMap { $0.isDirectory ? $0 : nil }
            case 255: return nil
            default: continue
            }
        }
        return nil
    }

    private static func parseRecord(_ sector: Data, at offset: Int) -> DirEntry? {
        let b = sector.startIndex + offset
        guard offset + 33 <= sector.count else { return nil }
        let length = Int(sector[b])
        let nameLength = Int(sector[b + 32])
        guard length >= 33 + nameLength, offset + length <= sector.count else { return nil }
        var name = String(decoding: sector[(b + 33)..<(b + 33 + nameLength)], as: UTF8.self).uppercased()
        if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
        if name.hasSuffix(".") { name.removeLast() }
        return DirEntry(name: name, lba: Int(sector.le32(at: offset + 2)), size: Int(sector.le32(at: offset + 10)),
                        isDirectory: sector[b + 25] & 0x02 != 0)
    }

    private static func readDirectory(_ source: SectorSource, _ dir: DirEntry) -> [DirEntry]? {
        let sectors = (min(dir.size, maxDirectoryBytes) + 2047) / 2048
        guard sectors > 0 else { return nil }
        var entries: [DirEntry] = []
        for i in 0..<sectors {
            guard let s = source.sector(dir.lba + i), s.count == 2048 else { return i == 0 ? nil : entries }
            var offset = 0
            while offset < 2048 {
                let length = Int(s[s.startIndex + offset])
                if length == 0 { break }  // rest of this sector is padding
                guard let e = parseRecord(s, at: offset) else { break }
                let nameByte = s[s.startIndex + offset + 33]
                if !(s[s.startIndex + offset + 32] == 1 && nameByte <= 1) { entries.append(e) }  // skip "." / ".."
                offset += length
            }
        }
        return entries
    }

    private static func readFile(_ source: SectorSource, _ entry: DirEntry, limit: Int) -> Data? {
        let size = min(entry.size, limit)
        var out = Data(capacity: size)
        var lba = entry.lba
        while out.count < size {
            guard let s = source.sector(lba), s.count == 2048 else { return nil }
            out.append(s.prefix(size - out.count))
            lba += 1
        }
        return out
    }

    // MARK: - PARAM.SFO

    static func paramSFOString(_ data: Data, key wanted: String) -> String? {
        let d = Data(data)  // rebase indices to 0
        guard d.count >= 20, d.prefix(4).elementsEqual([0, 0x50, 0x53, 0x46]) else { return nil }
        let keyTable = Int(d.le32(at: 8)), dataTable = Int(d.le32(at: 12)), count = Int(d.le32(at: 16))
        guard count < 1024 else { return nil }
        for i in 0..<count {
            let e = 20 + i * 16
            guard e + 16 <= d.count else { return nil }
            let keyStart = keyTable + Int(d.le16(at: e))
            guard keyStart < d.count else { continue }
            let keyEnd = d[keyStart...].firstIndex(of: 0) ?? d.count
            guard String(decoding: d[keyStart..<keyEnd], as: UTF8.self) == wanted else { continue }
            guard d.le16(at: e + 2) != 0x0404 else { return nil }  // integer, not a string
            let start = dataTable + Int(d.le32(at: e + 12)), len = Int(d.le32(at: e + 4))
            guard start >= 0, len >= 0, start + len <= d.count else { return nil }
            let bytes = d[start..<(start + len)]
            return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return nil
    }
}

// MARK: - Sector sources

/// Yields 2048-byte ISO9660 logical sectors.
private protocol SectorSource {
    func sector(_ lba: Int) -> Data?
}

private final class FileReader {
    private let handle: FileHandle
    let size: UInt64

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url), let end = try? h.seekToEnd() else { return nil }
        handle = h
        size = end
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) -> Data? {
        guard count > 0, offset < size else { return nil }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }
}

private struct PlainSectorSource: SectorSource {
    let file: FileReader
    let base: UInt64

    func sector(_ lba: Int) -> Data? {
        file.read(at: base + UInt64(lba) * 2048, count: 2048)
    }
}

/// Raw CD sectors: 12-byte sync, 4-byte header (mode at byte 15), then user data at 16 (MODE1) or 24 (MODE2 form 1).
private struct RawSectorSource: SectorSource {
    static let sync: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]

    let file: FileReader
    let base: UInt64
    let dataOffset: UInt64

    /// Checks the sync pattern at sector 16 (the PVD, always a data sector); nil if this is not a raw image.
    init?(file: FileReader, base: UInt64, sectorSize: Int) {
        guard sectorSize == 2352,
              let header = file.read(at: base + 16 * 2352, count: 16), header.count == 16,
              header.prefix(12).elementsEqual(Self.sync) else { return nil }
        switch header[header.startIndex + 15] {
        case 1: dataOffset = 16
        case 2: dataOffset = 24
        default: return nil
        }
        self.file = file
        self.base = base
    }

    func sector(_ lba: Int) -> Data? {
        file.read(at: base + UInt64(lba) * 2352 + dataOffset, count: 2048)
    }
}

/// CSO (compressed ISO): header `CISO`, u32 header size, u64 total bytes, u32 block size, u8 version, u8 index shift;
/// u32 index at 0x18 with one entry per block plus a terminator. High bit set = block stored uncompressed.
private final class CSOSectorSource: SectorSource {
    private let file: FileReader
    private let totalBytes: UInt64
    private let blockSize: Int
    private let version: UInt8
    private let align: UInt64
    private var cachedIndex = -1
    private var cachedBlock = Data()

    init?(file: FileReader) {
        guard let h = file.read(at: 0, count: 24), h.count == 24 else { return nil }
        let d = Data(h)
        totalBytes = d.le64(at: 8)
        blockSize = Int(d.le32(at: 16))
        version = d[20]
        align = UInt64(d[21])
        guard version <= 2, blockSize >= 2048, blockSize <= 1 << 20, blockSize % 2048 == 0, align < 32,
              totalBytes > 0 else { return nil }
        self.file = file
    }

    func sector(_ lba: Int) -> Data? {
        let offset = UInt64(lba) * 2048
        guard offset + 2048 <= totalBytes else { return nil }
        let index = Int(offset / UInt64(blockSize))
        guard let block = block(index) else { return nil }
        let start = Int(offset % UInt64(blockSize))
        return block.subdata(in: start..<(start + 2048))
    }

    private func block(_ index: Int) -> Data? {
        if index == cachedIndex { return cachedBlock }
        guard let raw = file.read(at: 24 + UInt64(index) * 4, count: 8), raw.count == 8 else { return nil }
        let entries = Data(raw)
        let first = entries.le32(at: 0), second = entries.le32(at: 4)
        let stored = first & 0x8000_0000 != 0
        let pos = UInt64(first & 0x7FFF_FFFF) << align
        let end = UInt64(second & 0x7FFF_FFFF) << align
        guard end > pos, end - pos <= UInt64(blockSize) * 2 + 1024 else { return nil }
        let readSize = Int(end - pos)
        let data: Data
        if readSize >= blockSize && (stored || version >= 2) {
            guard let d = file.read(at: pos, count: blockSize), d.count == blockSize else { return nil }
            data = d
        } else if stored {
            // v1: stored block shorter than blockSize means a truncated file; v2: LZ4 block (unsupported).
            guard version < 2, let d = file.read(at: pos, count: blockSize), d.count == blockSize else { return nil }
            data = d
        } else {
            guard let compressed = file.read(at: pos, count: readSize), !compressed.isEmpty,
                  let d = Self.inflate(compressed, expected: blockSize) else { return nil }
            data = d
        }
        cachedIndex = index
        cachedBlock = data
        return data
    }

    /// Raw DEFLATE (RFC 1951) — what Compression's COMPRESSION_ZLIB decodes.
    private static func inflate(_ input: Data, expected: Int) -> Data? {
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        // The final block of an image may legitimately decode short; pad it.
        guard written > 0 else { return nil }
        if written < expected { out.resetBytes(in: written..<expected) }
        return out
    }
}

// MARK: - Cue sheets

private enum CueSheet {
    struct Track {
        let url: URL
        let sectorSize: Int
        let byteOffset: UInt64
    }

    static func firstDataTrack(cueURL: URL) -> Track? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cueURL.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 256 * 1024,
              let data = try? Data(contentsOf: cueURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var currentFile: String?
        var dataTrack: (file: String, sectorSize: Int)?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("FILE ") {
                if dataTrack != nil { break }  // data track had no INDEX 01; assume offset 0
                currentFile = fileName(fromFileLine: String(line.dropFirst(5)))
            } else if upper.hasPrefix("TRACK ") {
                if let track = dataTrack { return resolve(track.file, cueURL: cueURL, sectorSize: track.sectorSize, frames: 0) }
                let type = upper.split(separator: " ").last.map(String.init) ?? ""
                guard type.hasPrefix("MODE"), let file = currentFile else { continue }
                let sectorSize = Int(type.split(separator: "/").last ?? "") ?? 2352
                dataTrack = (file, sectorSize)
            } else if upper.hasPrefix("INDEX "), let track = dataTrack {
                let parts = upper.split(separator: " ")
                guard parts.count >= 3, parts[1] == "01" || parts[1] == "1" else { continue }
                let msf = parts[2].split(separator: ":").compactMap { Int($0) }
                guard msf.count == 3 else { return nil }
                return resolve(track.file, cueURL: cueURL, sectorSize: track.sectorSize,
                               frames: (msf[0] * 60 + msf[1]) * 75 + msf[2])
            }
        }
        if let track = dataTrack { return resolve(track.file, cueURL: cueURL, sectorSize: track.sectorSize, frames: 0) }
        return nil
    }

    /// `"My Game (USA).bin" BINARY` → `My Game (USA).bin`; unquoted names end at the last space.
    private static func fileName(fromFileLine rest: String) -> String? {
        let s = rest.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") {
            let body = s.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<close])
        }
        if let space = s.lastIndex(of: " ") { return String(s[..<space]) }
        return s.isEmpty ? nil : s
    }

    private static func resolve(_ name: String, cueURL: URL, sectorSize: Int, frames: Int) -> Track? {
        guard sectorSize == 2352 || sectorSize == 2048 else { return nil }
        let relative = name.replacingOccurrences(of: "\\", with: "/")
        let base = cueURL.deletingLastPathComponent()
        var url = base.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Case-insensitive fallback for images copied from case-insensitive file systems.
            let parent = url.deletingLastPathComponent()
            let wanted = url.lastPathComponent.lowercased()
            guard let match = (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?
                .first(where: { $0.lowercased() == wanted }) else { return nil }
            url = parent.appendingPathComponent(match)
        }
        return Track(url: url, sectorSize: sectorSize, byteOffset: UInt64(frames) * UInt64(sectorSize))
    }
}

// MARK: - Little-endian helpers

private extension Data {
    func le16(at i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func le32(at i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    func le64(at i: Int) -> UInt64 {
        UInt64(le32(at: i)) | UInt64(le32(at: i + 4)) << 32
    }
}
