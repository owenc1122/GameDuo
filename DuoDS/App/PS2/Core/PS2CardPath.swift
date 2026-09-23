import Foundation

/// Validates relative paths inside a folder memory card that come from the PS2 core
/// (`BESLES-12345/icon.sys`). Rejects anything that could leave the card root.
enum PS2CardPath {
    /// The URL for `path` inside `root`, or nil when the path is empty, absolute, hidden, or
    /// contains `.`/`..` components, backslashes or NUL.
    static func resolve(_ path: String, in root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 2 else { return nil }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.hasPrefix("."),
                  component.utf8.count <= 64 else { return nil }
        }
        var url = root
        for component in components { url.appendPathComponent(String(component)) }
        return url
    }

    /// Every file on the card as a relative path ("SAVE/file"), skipping hidden entries.
    static func manifest(of root: URL) -> [String] {
        let fm = FileManager.default
        guard let saves = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [String] = []
        for save in saves.sorted() where !save.hasPrefix(".") {
            var isDir: ObjCBool = false
            let dir = root.appendingPathComponent(save)
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files.sorted() where !file.hasPrefix(".") {
                var fileIsDir: ObjCBool = false
                if fm.fileExists(atPath: dir.appendingPathComponent(file).path, isDirectory: &fileIsDir), !fileIsDir.boolValue {
                    result.append("\(save)/\(file)")
                }
            }
        }
        return result
    }
}
