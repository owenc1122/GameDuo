import Foundation
import WebKit

/// Serves the PS2 core page over `duops2://core/…`, cross-origin isolated so Play!'s threads get
/// shared memory:
/// - `/`, `/index.html`, `/duo.js`, `/Play.js`, `/Play.wasm` from the app bundle (`PS2Web`);
/// - `/disc/<file>` (HTTP range reads) and `/disc-size/<file>`, only for files next to the image;
/// - `/card-manifest` and `/card/<save>/<file>` from the game's memory card folder;
/// - `/host-manifest` and `/host/<path>` from a folder with a homebrew ELF (QA only).
/// File I/O runs off the main thread; a stopped task is never answered.
final class PS2WebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "duops2"
    static let origin = "\(scheme)://core"

    private let bundleRoot: URL
    private let discDirectory: URL?
    private let cardRoot: URL
    private let hostRoot: URL?
    private let queue = DispatchQueue(label: "duo.ps2.scheme", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()

    init(bundleRoot: URL, discDirectory: URL?, cardRoot: URL, hostRoot: URL?) {
        self.bundleRoot = bundleRoot
        self.discDirectory = discDirectory
        self.cardRoot = cardRoot
        self.hostRoot = hostRoot
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let request = task.request
        queue.async { [weak self] in
            guard let self else { return }
            let response = self.respond(to: request)
            DispatchQueue.main.async { self.finish(task, with: response) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task)); lock.unlock()
    }

    private struct Response {
        var status = 200
        var body = Data()
        var type = "application/octet-stream"
        var extra: [String: String] = [:]
    }

    private func finish(_ task: WKURLSchemeTask, with response: Response) {
        lock.lock()
        let wasStopped = stopped.remove(ObjectIdentifier(task)) != nil
        lock.unlock()
        guard !wasStopped, let url = task.request.url else { return }
        var headers = response.extra
        headers["Content-Type"] = response.type
        headers["Content-Length"] = "\(response.body.count)"
        headers["Cross-Origin-Opener-Policy"] = "same-origin"
        headers["Cross-Origin-Embedder-Policy"] = "require-corp"
        headers["Cross-Origin-Resource-Policy"] = "same-origin"
        headers["Cache-Control"] = "no-store"
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(http)
        task.didReceive(response.body)
        task.didFinish()
    }

    private func respond(to request: URLRequest) -> Response {
        guard let url = request.url else { return Response(status: 400) }
        let path = url.path.removingPercentEncoding ?? url.path
        switch path {
        case "/", "/index.html":
            return bundleFile("index.html", type: "text/html; charset=utf-8")
        case "/duo.js", "/duo_audio.js", "/Play.js":
            return bundleFile(String(path.dropFirst()), type: "text/javascript; charset=utf-8")
        case "/Play.wasm":
            return bundleFile("Play.wasm", type: "application/wasm")
        case "/card-manifest":
            return json(PS2CardPath.manifest(of: cardRoot))
        case "/host-manifest":
            guard let hostRoot else { return json([String]()) }
            return json(Self.hostManifest(hostRoot))
        default:
            break
        }
        if path.hasPrefix("/disc-size/") {
            guard let file = discFile(String(path.dropFirst("/disc-size/".count))),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return Response(status: 404) }
            return Response(body: Data("\(size)".utf8), type: "text/plain")
        }
        if path.hasPrefix("/disc/") {
            guard let file = discFile(String(path.dropFirst("/disc/".count))) else { return Response(status: 404) }
            return rangeRead(file, header: request.value(forHTTPHeaderField: "Range"))
        }
        if path.hasPrefix("/card/") {
            guard let file = PS2CardPath.resolve(String(path.dropFirst("/card/".count)), in: cardRoot),
                  let data = try? Data(contentsOf: file) else { return Response(status: 404) }
            return Response(body: data)
        }
        if path.hasPrefix("/host/"), let hostRoot {
            let relative = String(path.dropFirst("/host/".count))
            guard !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  let data = try? Data(contentsOf: hostRoot.appendingPathComponent(relative)) else { return Response(status: 404) }
            return Response(body: data)
        }
        return Response(status: 404)
    }

    private func bundleFile(_ name: String, type: String) -> Response {
        guard let data = try? Data(contentsOf: bundleRoot.appendingPathComponent(name)) else { return Response(status: 404) }
        return Response(body: data, type: type)
    }

    private func json(_ value: [String]) -> Response {
        Response(body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8), type: "application/json")
    }

    /// A file directly inside the disc image's folder (BIN/CUE tracks live next to the sheet).
    private func discFile(_ name: String) -> URL? {
        guard let discDirectory, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = discDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func rangeRead(_ file: URL, header: String?) -> Response {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Response(status: 404) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard let range = PS2ByteRange.parse(header, size: size) else {
            return Response(status: 416, extra: ["Content-Range": "bytes */\(size)"])
        }
        do {
            try handle.seek(toOffset: range.offset)
            let data = try handle.read(upToCount: Int(range.length)) ?? Data()
            return Response(status: 206, body: data, extra: ["Content-Range": range.contentRange(size: size), "Accept-Ranges": "bytes"])
        } catch {
            return Response(status: 500)
        }
    }

    private static func hostManifest(_ root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path
        var files: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            files.append(String(full.dropFirst(base.count + 1)))
        }
        return files.sorted()
    }
}
