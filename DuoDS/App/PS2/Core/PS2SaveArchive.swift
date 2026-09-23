import Foundation

// PS2 single-save archive formats.
//
// References (all public):
// - mymc by Ross Ridge (public domain), https://github.com/ps2dev/mymc
//   `ps2mc_dir.py` (512-byte MCFS directory entry, ToD timestamps in JST),
//   `ps2save.py` (`load_ems`/`save_ems` = .psu, `load_max_drive` = .max),
//   `lzari.py` (LZARI port used by MAX Drive saves).
// - Haruhiko Okumura, LZARI.C (1989, public domain) — the original arithmetic-coded LZSS.
// - PCSX2 `pcsx2/SIO/Memcard/MemoryCardFolder.cpp` / `MemoryCardFile.cpp` (same MCFS
//   directory-entry layout, `mode` flags and the 8-byte `tod` struct).

/// Errors from reading/writing save archives and from the folder memory card.
/// `errorDescription` is user-presentable (Chinese via `String(localized:)`).
enum PS2SaveError: Error, LocalizedError, Equatable {
    /// Not a `.psu` or `.max` file.
    case unrecognizedFormat
    /// Structurally broken archive; the associated text is a developer detail (not shown).
    case corrupt(String)
    /// The save contains a sub-directory, which PS2 saves never do.
    case unsupportedSubdirectory(String)
    /// A directory/file name that is empty, `.`/`..`, hidden, contains separators or control
    /// characters, or is longer than the 32-byte MCFS name field.
    case invalidName(String)
    /// Two files in one archive share a name.
    case duplicateFileName(String)
    /// A save with this directory name is already on the card (retry with `overwrite: true`).
    case alreadyExists(String)
    /// The save is not (or no longer) on this card.
    case notFound(String)
    /// The archive declares more data than we are willing to allocate.
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return String(localized: "无法识别的存档文件，仅支持 .psu 与 .max")
        case .corrupt:
            return String(localized: "存档文件已损坏或不完整")
        case .unsupportedSubdirectory:
            return String(localized: "存档内含子文件夹，无法导入")
        case .invalidName(let name):
            return String(localized: "存档名称“\(name)”无效")
        case .duplicateFileName(let name):
            return String(localized: "存档内有重名文件“\(name)”")
        case .alreadyExists(let name):
            return String(localized: "记忆卡上已有存档“\(name)”")
        case .notFound(let name):
            return String(localized: "找不到存档“\(name)”")
        case .tooLarge:
            return String(localized: "存档文件过大")
        }
    }
}

/// One PS2 save held in memory: a directory name plus its flat list of files.
/// Read from `.psu` (EMS / uLaunchELF) or `.max` (Action Replay MAX / MAX Drive); written as `.psu`.
struct PS2SaveArchive: Equatable {
    struct File: Equatable {
        var name: String
        var data: Data
        var created: Date?
        var modified: Date?
    }

    enum Format: String { case psu, max }

    var directoryName: String
    var files: [File]
    var created: Date?
    var modified: Date?

    /// Upper bound for any single declared size (a real save is at most a few MB; the whole card is 8 MB).
    static let maxDeclaredSize = 64 * 1024 * 1024

    // MARK: Detection / reading

    /// Detects the format from content (extension is ignored).
    static func detectFormat(_ data: Data) -> Format? {
        if data.count >= 0x5C, data.prefix(12) == Data("Ps2PowerSave".utf8) { return .max }
        if data.count >= PS2MCDirEntry.size,
           let entry = try? PS2MCDirEntry(data, at: 0), entry.isDirectory { return .psu }
        return nil
    }

    static func read(from url: URL) throws -> PS2SaveArchive {
        try read(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func read(_ data: Data) throws -> PS2SaveArchive {
        switch detectFormat(data) {
        case .psu: return try readPSU(data)
        case .max: return try readMAX(data)
        case nil: throw PS2SaveError.unrecognizedFormat
        }
    }

    /// Checks names and uniqueness; call before touching the file system.
    func validate() throws {
        try PS2SaveName.validate(directoryName)
        var seen = Set<String>()
        for file in files {
            try PS2SaveName.validate(file.name)
            guard seen.insert(file.name).inserted else { throw PS2SaveError.duplicateFileName(file.name) }
        }
    }

    // MARK: .psu (EMS)

    /// `.psu` layout (mymc `load_ems`/`save_ems`): a directory entry for the save (its `length` =
    /// number of entries incl. `.` and `..`), then `.` and `..` entries, then for each file a
    /// 512-byte entry (`length` = byte size) followed by the data zero-padded to 1024 bytes.
    static func readPSU(_ data: Data) throws -> PS2SaveArchive {
        let bytes = [UInt8](data)
        let dir = try PS2MCDirEntry(bytes, at: 0)
        guard dir.isDirectory else { throw PS2SaveError.corrupt("psu: first entry is not a directory") }
        let entryCount = Int(dir.length)
        guard entryCount <= 4096 else { throw PS2SaveError.tooLarge }

        var files: [File] = []
        var offset = PS2MCDirEntry.size
        var entriesRead = 0
        // `entryCount` entries follow the directory entry. Lenient: stop cleanly at EOF (some
        // writers omit `.`/`..` but still count them).
        while entriesRead < entryCount, offset + PS2MCDirEntry.size <= bytes.count {
            let entry = try PS2MCDirEntry(bytes, at: offset)
            offset += PS2MCDirEntry.size
            entriesRead += 1
            if entry.isDirectory {
                if entry.name == "." || entry.name == ".." { continue }
                throw PS2SaveError.unsupportedSubdirectory(entry.name)
            }
            guard entry.isFile else { throw PS2SaveError.corrupt("psu: bad mode \(entry.mode)") }
            let length = Int(entry.length)
            guard length <= maxDeclaredSize else { throw PS2SaveError.tooLarge }
            guard offset + length <= bytes.count else { throw PS2SaveError.corrupt("psu: truncated file data") }
            files.append(File(name: entry.name, data: Data(bytes[offset..<offset + length]),
                              created: entry.created, modified: entry.modified))
            offset += roundUp(length, 1024)
        }
        guard !files.isEmpty else { throw PS2SaveError.corrupt("psu: no files") }
        let archive = PS2SaveArchive(directoryName: dir.name, files: files,
                                     created: dir.created, modified: dir.modified)
        try archive.validate()
        return archive
    }

    /// Serializes as `.psu` (mirrors mymc `save_ems`). Missing timestamps are written as "now".
    func psuData() throws -> Data {
        try validate()
        let now = Date()
        let dirCreated = created ?? now, dirModified = modified ?? dirCreated
        var out = Data()
        out.reserveCapacity(PS2MCDirEntry.size * (files.count + 3)
                            + files.reduce(0) { $0 + Self.roundUp($1.data.count, 1024) })
        out += try PS2MCDirEntry(mode: PS2MCDirEntry.dirMode, length: UInt32(files.count + 2),
                                 created: dirCreated, modified: dirModified, name: directoryName).encoded()
        for dot in [".", ".."] {
            out += try PS2MCDirEntry(mode: PS2MCDirEntry.dirMode, length: 0,
                                     created: dirCreated, modified: dirModified, name: dot).encoded()
        }
        for file in files {
            guard file.data.count <= UInt32.max else { throw PS2SaveError.tooLarge }
            let fileCreated = file.created ?? dirCreated
            out += try PS2MCDirEntry(mode: PS2MCDirEntry.fileMode, length: UInt32(file.data.count),
                                     created: fileCreated, modified: file.modified ?? fileCreated,
                                     name: file.name).encoded()
            out += file.data
            out += Data(count: Self.roundUp(file.data.count, 1024) - file.data.count)
        }
        return out
    }

    // MARK: .max (Action Replay MAX)

    /// `.max` layout (mymc `load_max_drive`): 0x5C-byte header
    /// `magic "Ps2PowerSave"[12], crc u32, dirName[32], iconSysTitle[32], compressedSize u32 (incl. the
    /// following u32), fileCount u32, uncompressedSize u32`, then an LZARI stream. The decompressed
    /// payload is, per file, `size u32, name[32]`, data, then zero padding so that `(offset + 8) % 16 == 0`.
    /// MAX files carry no timestamps. The CRC is not verified (mymc does not either).
    static func readMAX(_ data: Data) throws -> PS2SaveArchive {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x5C, bytes[0..<12].elementsEqual("Ps2PowerSave".utf8) else {
            throw PS2SaveError.unrecognizedFormat
        }
        let dirName = PS2SaveName.decode(bytes[16..<48])
        let compressedSize = Int(readU32(bytes, 0x50))
        let fileCount = Int(readU32(bytes, 0x54))
        let length = Int(readU32(bytes, 0x58))
        guard length <= maxDeclaredSize, fileCount <= 4096 else { throw PS2SaveError.tooLarge }

        let start = 0x5C
        let end: Int
        if compressedSize == length || compressedSize < 4 {
            // Some saves store the uncompressed size here instead (mymc): read to EOF.
            end = bytes.count
        } else {
            end = start + compressedSize - 4
            guard end <= bytes.count else { throw PS2SaveError.corrupt("max: truncated stream") }
        }
        let payload = try PS2LZARI.decode(bytes[start..<end], outputLength: length)

        var files: [File] = []
        var offset = 0
        for _ in 0..<fileCount {
            guard offset + 36 <= payload.count else { throw PS2SaveError.corrupt("max: truncated file header") }
            let size = Int(readU32(payload, offset))
            let name = PS2SaveName.decode(payload[offset + 4..<offset + 36])
            offset += 36
            guard size <= payload.count - offset else { throw PS2SaveError.corrupt("max: truncated file data") }
            files.append(File(name: name, data: Data(payload[offset..<offset + size])))
            offset = roundUp(offset + size + 8, 16) - 8
        }
        guard !files.isEmpty else { throw PS2SaveError.corrupt("max: no files") }
        let archive = PS2SaveArchive(directoryName: dirName, files: files)
        try archive.validate()
        return archive
    }

    // MARK: Helpers

    static func roundUp(_ value: Int, _ multiple: Int) -> Int { (value + multiple - 1) / multiple * multiple }

    static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

// MARK: - MCFS directory entry

/// The 512-byte PS2 memory card (MCFS) directory entry, as used verbatim in `.psu`
/// (mymc `_dirent_fmt = "<HHL8sLL8sL28x448s"`):
/// 0x00 mode u16, 0x02 unused u16, 0x04 length u32 (bytes for files, entry count for dirs),
/// 0x08 created tod[8], 0x10 cluster u32, 0x14 dir entry u32, 0x18 modified tod[8], 0x20 attr u32,
/// 0x24 padding[28], 0x40 name[32] (NUL-terminated unless all 32 bytes used), rest zero.
struct PS2MCDirEntry {
    static let size = 512
    // Mode flags (mymc ps2mc_dir.py): DF_READ 0x1, DF_WRITE 0x2, DF_EXECUTE 0x4, DF_FILE 0x10,
    // DF_DIR 0x20, DF_0400 0x400, DF_EXISTS 0x8000.
    static let dfFile: UInt16 = 0x0010, dfDir: UInt16 = 0x0020, dfExists: UInt16 = 0x8000
    /// DF_RWX | DF_DIR | DF_0400 | DF_EXISTS (what mymc writes for save directories).
    static let dirMode: UInt16 = 0x8427
    /// DF_RWX | DF_FILE | DF_0400 | DF_EXISTS (what mymc writes for files).
    static let fileMode: UInt16 = 0x8417

    var mode: UInt16
    var length: UInt32
    var created: Date?
    var modified: Date?
    var name: String

    var isDirectory: Bool { mode & (Self.dfFile | Self.dfDir | Self.dfExists) == Self.dfDir | Self.dfExists }
    var isFile: Bool { mode & (Self.dfFile | Self.dfDir | Self.dfExists) == Self.dfFile | Self.dfExists }

    init(mode: UInt16, length: UInt32, created: Date?, modified: Date?, name: String) {
        self.mode = mode; self.length = length; self.created = created; self.modified = modified; self.name = name
    }

    init(_ data: Data, at offset: Int) throws { try self.init([UInt8](data), at: offset) }

    init(_ b: [UInt8], at o: Int) throws {
        guard o + Self.size <= b.count else { throw PS2SaveError.corrupt("dirent: truncated") }
        mode = UInt16(b[o]) | UInt16(b[o + 1]) << 8
        length = PS2SaveArchive.readU32(b, o + 4)
        created = PS2Timestamp.decode(b[(o + 0x08)..<(o + 0x10)])
        modified = PS2Timestamp.decode(b[(o + 0x18)..<(o + 0x20)])
        name = PS2SaveName.decode(b[(o + 0x40)..<(o + 0x60)])
    }

    func encoded() throws -> Data {
        var b = [UInt8](repeating: 0, count: Self.size)
        b[0] = UInt8(mode & 0xFF); b[1] = UInt8(mode >> 8)
        for i in 0..<4 { b[4 + i] = UInt8((length >> (8 * UInt32(i))) & 0xFF) }
        b.replaceSubrange(0x08..<0x10, with: PS2Timestamp.encode(created ?? Date()))
        b.replaceSubrange(0x18..<0x20, with: PS2Timestamp.encode(modified ?? created ?? Date()))
        let nameBytes = try PS2SaveName.encode(name)
        b.replaceSubrange(0x40..<(0x40 + nameBytes.count), with: nameBytes)
        return Data(b)
    }
}

// MARK: - Timestamps

/// PS2 "tod" (sceMcStDateTime): `unused u8, sec u8, min u8, hour u8, day u8, month u8, year u16 LE`.
/// The PS2 RTC keeps Japan Standard Time (UTC+9) regardless of region; mymc `time_to_tod` /
/// `tod_to_time` apply the fixed +9 h offset, and so do we. All-zero or invalid fields decode to nil.
enum PS2Timestamp {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return c
    }()

    static func decode<C: Collection>(_ bytes: C) -> Date? where C.Element == UInt8 {
        let b = Array(bytes)
        guard b.count >= 8 else { return nil }
        let year = Int(b[6]) | Int(b[7]) << 8
        let month = b[5] == 0 ? 1 : Int(b[5])  // mymc treats month 0 as January
        let day = Int(b[4]), hour = Int(b[3]), minute = Int(b[2]), second = Int(b[1])
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    static func encode(_ date: Date) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(0, min(Int(UInt16.max), c.year ?? 2000))
        return [0, UInt8(c.second ?? 0), UInt8(c.minute ?? 0), UInt8(c.hour ?? 0),
                UInt8(c.day ?? 1), UInt8(c.month ?? 1), UInt8(year & 0xFF), UInt8(year >> 8)]
    }
}

// MARK: - Names

/// MCFS names: at most 32 bytes (the name field), stored without a path. We encode as UTF-8
/// (PS2 saves use ASCII) and decode UTF-8 → Shift-JIS → Latin-1.
enum PS2SaveName {
    static let maxBytes = 32

    static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let raw = Array(bytes.prefix { $0 != 0 })
        return String(bytes: raw, encoding: .utf8)
            ?? String(bytes: raw, encoding: .shiftJIS)
            ?? String(bytes: raw, encoding: .isoLatin1)
            ?? String(decoding: raw, as: UTF8.self)
    }

    static func encode(_ name: String) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        guard bytes.count <= maxBytes else { throw PS2SaveError.invalidName(name) }
        return bytes
    }

    /// Rejects anything that could escape the save directory or that the card listing would hide.
    static func validate(_ name: String) throws {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maxBytes,
              name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw PS2SaveError.invalidName(name) }
    }
}

// MARK: - LZARI

/// Haruhiko Okumura's LZARI decoder (LZARI.C, 1989): LZSS with a 4096-byte ring buffer
/// (initially spaces), match length 3...60, and adaptive arithmetic coding (15-bit precision) of
/// 314 symbols (256 literals + 58 lengths) plus a static distribution over the 4096 positions.
/// Bits are read MSB-first; the stream has no size prefix (MAX stores it in its header).
/// Cross-checked against mymc `lzari.py` (`decode`, `decode_char`, `decode_position`).
enum PS2LZARI {
    static let n = 4096            // ring buffer size
    static let f = 60              // max match length
    static let threshold = 2       // matches longer than this are coded as (length, position)
    static let nChar = 256 - threshold + f
    static let m = 15
    static let q1 = 1 << m, q2 = 2 << m, q3 = 3 << m, q4 = 4 << m
    static let maxCum = q1 - 1

    /// Static position model (identical for encoder/decoder): `position_cum[i-1] = position_cum[i] + 10000/(i+200)`.
    static let positionCum: [Int] = {
        var cum = [Int](repeating: 0, count: n + 1)
        for i in stride(from: n, through: 1, by: -1) { cum[i - 1] = cum[i] + 10000 / (i + 200) }
        return cum
    }()

    /// Adaptive symbol model shared by encoder and decoder (Okumura `StartModel`/`UpdateModel`).
    struct Model {
        var charToSym = [Int](repeating: 0, count: PS2LZARI.nChar)
        var symToChar = [Int](repeating: 0, count: PS2LZARI.nChar + 1)
        var symFreq = [Int](repeating: 0, count: PS2LZARI.nChar + 1)
        var symCum = [Int](repeating: 0, count: PS2LZARI.nChar + 1)

        init() {
            let nChar = PS2LZARI.nChar
            symCum[nChar] = 0
            for sym in stride(from: nChar, through: 1, by: -1) {
                let ch = sym - 1
                charToSym[ch] = sym; symToChar[sym] = ch
                symFreq[sym] = 1
                symCum[sym - 1] = symCum[sym] + symFreq[sym]
            }
            symFreq[0] = 0  // sentinel
        }

        mutating func update(_ sym: Int) {
            if symCum[0] >= PS2LZARI.maxCum {
                var c = 0
                for i in stride(from: PS2LZARI.nChar, to: 0, by: -1) {
                    symCum[i] = c
                    symFreq[i] = (symFreq[i] + 1) >> 1
                    c += symFreq[i]
                }
                symCum[0] = c
            }
            var i = sym
            while symFreq[i] == symFreq[i - 1] { i -= 1 }
            if i < sym {
                let chI = symToChar[i], chSym = symToChar[sym]
                symToChar[i] = chSym; symToChar[sym] = chI
                charToSym[chI] = sym; charToSym[chSym] = i
            }
            symFreq[i] += 1
            while i > 0 { i -= 1; symCum[i] += 1 }
        }
    }

    static func decode<C: Collection>(_ input: C, outputLength: Int) throws -> [UInt8] where C.Element == UInt8 {
        guard outputLength > 0 else { return [] }
        let src = Array(input)
        let srcBits = src.count * 8
        var bitPos = 0
        // Past the end we feed zeros (like mymc); a valid stream never needs more than a few.
        func getBit() throws -> Int {
            defer { bitPos += 1 }
            if bitPos < srcBits { return Int(src[bitPos >> 3] >> (7 - UInt8(bitPos & 7))) & 1 }
            if bitPos > srcBits + 64 { throw PS2SaveError.corrupt("lzari: stream exhausted") }
            return 0
        }

        var model = Model()
        let posCum = positionCum
        var low = 0, high = q4, value = 0
        for _ in 0..<(m + 2) { value = 2 * value + (try getBit()) }

        func normalize() throws {
            while true {
                if low >= q2 {
                    value -= q2; low -= q2; high -= q2
                } else if low >= q1 && high <= q3 {
                    value -= q1; low -= q1; high -= q1
                } else if high > q2 {
                    break
                }
                low += low; high += high
                value = 2 * value + (try getBit())
            }
        }

        func decodeChar() throws -> Int {
            let range = high - low
            let x = ((value - low + 1) * model.symCum[0] - 1) / range
            // Binary search: i such that symCum[i-1] > x >= symCum[i].
            var i = 1, j = nChar
            while i < j {
                let k = (i + j) / 2
                if model.symCum[k] > x { i = k + 1 } else { j = k }
            }
            let sym = i
            high = low + range * model.symCum[sym - 1] / model.symCum[0]
            low += range * model.symCum[sym] / model.symCum[0]
            try normalize()
            let ch = model.symToChar[sym]
            model.update(sym)
            return ch
        }

        func decodePosition() throws -> Int {
            let range = high - low
            let x = ((value - low + 1) * posCum[0] - 1) / range
            var i = 1, j = n
            while i < j {
                let k = (i + j) / 2
                if posCum[k] > x { i = k + 1 } else { j = k }
            }
            let position = i - 1
            high = low + range * posCum[position] / posCum[0]
            low += range * posCum[position + 1] / posCum[0]
            try normalize()
            return position
        }

        var out = [UInt8]()
        out.reserveCapacity(outputLength)
        // Ring buffer: spaces, except the F lookahead slots (zero, as in mymc; never referenced).
        var text = [UInt8](repeating: 0x20, count: n - f) + [UInt8](repeating: 0, count: f)
        var r = n - f
        while out.count < outputLength {
            let c = try decodeChar()
            if c < 256 {
                out.append(UInt8(c)); text[r] = UInt8(c); r = (r + 1) & (n - 1)
            } else {
                let start = (r - (try decodePosition()) - 1) & (n - 1)
                let count = c - 255 + threshold
                for k in 0..<count where out.count < outputLength {
                    let byte = text[(start + k) & (n - 1)]
                    out.append(byte); text[r] = byte; r = (r + 1) & (n - 1)
                }
            }
        }
        return out
    }
}
