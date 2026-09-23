import Foundation

/// One file inside a save directory on a folder memory card.
struct PS2SaveFile: Hashable, Sendable {
    var name: String
    var url: URL
    var size: Int64
    var created: Date?
    var modified: Date?
}

/// A save on a folder memory card: one sub-directory such as `BASLUS-20312GAME`.
struct PS2SaveEntry: Identifiable, Hashable, Sendable {
    /// Directory name (the PS2 save name, e.g. `BASLUS-20312GAME`).
    var name: String
    var url: URL
    /// Sum of file sizes in bytes.
    var totalSize: Int64
    /// Newest file mtime (imported files carry the PS2 timestamps from the archive).
    var modificationDate: Date?
    /// Regular files, sorted by name (hidden files skipped).
    var files: [PS2SaveFile]

    var id: String { name }
    var iconSysURL: URL { url.appendingPathComponent("icon.sys") }
    var hasIconSys: Bool { files.contains { $0.name == "icon.sys" } }
    /// Title to show until `icon.sys` has been parsed (or when it is missing).
    var fallbackTitle: String { name }

    /// Raw `icon.sys` bytes for the icon/title parser, or nil when the save has none.
    func iconSysData() -> Data? {
        hasIconSys ? try? Data(contentsOf: iconSysURL) : nil
    }
}

/// Folder-backed PS2 memory card, one per game:
/// `Application Support/PS2/MemoryCards/<SERIAL or sanitized title>/<save dir>/<files>`.
///
/// The card is shown as 8 MB (`nominalCapacity`) to match the real accessory, but there is no
/// capacity limit: nothing here checks free space or refuses a save for being too large.
struct PS2MemoryCard: Sendable {
    /// Card root; created on first import. A missing root is an empty card.
    let root: URL

    /// Size printed on the card face; not enforced.
    static let nominalCapacity: Int64 = 8 * 1024 * 1024

    init(root: URL) { self.root = root.standardizedFileURL }

    /// Folder name for a game's card: the serial when known (`SLUS-20312`), else the title with
    /// path-hostile characters replaced.
    static func folderName(serial: String?, title: String) -> String {
        if let serial, !serial.trimmingCharacters(in: .whitespaces).isEmpty { return sanitize(serial) }
        return sanitize(title)
    }

    /// `base/<folderName>` — pass e.g. `Application Support/PS2/MemoryCards` as `base`.
    static func root(in base: URL, serial: String?, title: String) -> URL {
        base.appendingPathComponent(folderName(serial: serial, title: title), isDirectory: true)
    }

    private static func sanitize(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var s = String(raw.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Untitled" }
        return String(s.prefix(96))
    }

    // MARK: Listing

    /// All saves on the card, sorted by directory name. Hidden entries (our temp dirs) are skipped.
    func saves() throws -> [PS2SaveEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
        return try children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { try entry(at: $0) }
            .sorted { $0.name < $1.name }
    }

    /// The save named `name`, or nil.
    func save(named name: String) throws -> PS2SaveEntry? {
        try PS2SaveName.validate(name)
        let url = root.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return try entry(at: url)
    }

    private func entry(at found: URL) throws -> PS2SaveEntry {
        // Rebuild URLs from `root` so entries compare equal however they were found
        // (directory enumeration resolves /var → /private/var on Apple platforms).
        let dir = root.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        var files: [PS2SaveFile] = []
        for url in urls {
            let v = try url.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            files.append(PS2SaveFile(name: name, url: dir.appendingPathComponent(name, isDirectory: false), size: Int64(v.fileSize ?? 0),
                                     created: v.creationDate, modified: v.contentModificationDate))
        }
        files.sort { $0.name < $1.name }
        return PS2SaveEntry(name: dir.lastPathComponent, url: dir,
                            totalSize: files.reduce(0) { $0 + $1.size },
                            modificationDate: files.compactMap(\.modified).max(),
                            files: files)
    }

    // MARK: Delete

    func delete(_ entry: PS2SaveEntry) throws {
        // Loose check so that odd folders a user dropped in (e.g. names > 32 bytes) can still be removed.
        let url = try directoryURL(for: entry.name, strict: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PS2SaveError.notFound(entry.name) }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Export

    /// Reads a save into memory (files sorted by name, with their file-system dates).
    func archive(for entry: PS2SaveEntry) throws -> PS2SaveArchive {
        let current = try save(named: entry.name)
        guard let current else { throw PS2SaveError.notFound(entry.name) }
        let files = try current.files.map {
            PS2SaveArchive.File(name: $0.name, data: try Data(contentsOf: $0.url),
                                created: $0.created, modified: $0.modified)
        }
        let dirValues = try? current.url.resourceValues(forKeys: [.creationDateKey])
        return PS2SaveArchive(directoryName: current.name, files: files,
                              created: dirValues?.creationDate ?? files.compactMap(\.created).min(),
                              modified: current.modificationDate)
    }

    /// Writes `<save name>.psu` into `directory` (replacing an existing file) and returns its URL.
    @discardableResult
    func exportPSU(_ entry: PS2SaveEntry, to directory: URL) throws -> URL {
        let data = try archive(for: entry).psuData()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(entry.name).appendingPathExtension("psu")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Import

    /// Imports a `.psu` or `.max` file (format detected from content).
    /// Throws `PS2SaveError.alreadyExists` when a save with the same directory name exists and
    /// `overwrite` is false; the caller can ask the user and retry with `overwrite: true`.
    @discardableResult
    func importArchive(at url: URL, overwrite: Bool = false) throws -> PS2SaveEntry {
        try importSave(PS2SaveArchive.read(from: url), overwrite: overwrite)
    }

    /// Writes a save atomically: files go into a hidden temp directory inside the card root, which
    /// is then renamed into place (replacing the old save only after the new one is complete).
    @discardableResult
    func importSave(_ archive: PS2SaveArchive, overwrite: Bool = false) throws -> PS2SaveEntry {
        try archive.validate()
        let fm = FileManager.default
        let destination = try directoryURL(for: archive.directoryName)
        let exists = fm.fileExists(atPath: destination.path)
        if exists && !overwrite { throw PS2SaveError.alreadyExists(archive.directoryName) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }

        let now = Date()
        for file in archive.files {
            let url = temp.appendingPathComponent(file.name, isDirectory: false)
            // Belt and braces on top of name validation: the file must land directly in `temp`.
            guard url.deletingLastPathComponent().standardizedFileURL.path == temp.standardizedFileURL.path else {
                throw PS2SaveError.invalidName(file.name)
            }
            try file.data.write(to: url)
            let modified = file.modified ?? archive.modified ?? now
            try? fm.setAttributes([.modificationDate: modified,
                                   .creationDate: file.created ?? archive.created ?? modified],
                                  ofItemAtPath: url.path)
        }
        if let created = archive.created {
            try? fm.setAttributes([.creationDate: created], ofItemAtPath: temp.path)
        }

        if exists {
            let trash = root.appendingPathComponent(".replaced-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: destination, to: trash)
            do {
                try fm.moveItem(at: temp, to: destination)
            } catch {
                try? fm.moveItem(at: trash, to: destination)
                throw error
            }
            try? fm.removeItem(at: trash)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        guard let entry = try save(named: archive.directoryName) else {
            throw PS2SaveError.notFound(archive.directoryName)
        }
        return entry
    }

    /// Validated `root/<name>`; never resolves outside the card.
    private func directoryURL(for name: String, strict: Bool = true) throws -> URL {
        if strict {
            try PS2SaveName.validate(name)
        } else if name.isEmpty || name == "." || name == ".." || name.contains("/") {
            throw PS2SaveError.invalidName(name)
        }
        let url = root.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.path else { throw PS2SaveError.invalidName(name) }
        return url
    }
}
