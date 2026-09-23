#if DEBUG
import UIKit
import WebKit
import Network

/// `-webcore-spike`: feasibility probe for running the PS2 core as WebAssembly inside WKWebView.
/// Checks cross-origin isolation (SharedArrayBuffer for pthreads), Worker + Atomics, WebGL2 and
/// how fast a tight wasm loop runs (JIT vs interpreter). Results are logged as `DUO_SPIKE`.
enum PS2WebSpike {
    static let scheme = "duops2"

    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-webcore-spike") || ProcessInfo.processInfo.arguments.contains("-webcore-play") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow), let root = window.rootViewController?.view else { return }
            let config = WKWebViewConfiguration()
            let args = ProcessInfo.processInfo.arguments
            func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
            if let dir = value("-webcore-play") {
                config.setURLSchemeHandler(PlayHandler(dir: URL(fileURLWithPath: dir), disc: value("-webcore-play-disc").map(URL.init(fileURLWithPath:)),
                                                      host: value("-webcore-play-host").map(URL.init(fileURLWithPath:))), forURLScheme: scheme)
            } else {
                config.setURLSchemeHandler(Handler(), forURLScheme: scheme)
            }
            config.userContentController.add(Sink(), name: "spike")
            let view = WKWebView(frame: root.bounds, configuration: config)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isInspectable = true
            root.addSubview(view)
            if ProcessInfo.processInfo.arguments.contains("-webcore-spike-localhost") {
                let server = LocalServer()
                objc_setAssociatedObject(view, "server", server, .OBJC_ASSOCIATION_RETAIN)
                server.start { port in view.load(URLRequest(url: URL(string: "http://localhost:\(port)/index.html")!)) }
            } else {
                view.load(URLRequest(url: URL(string: "\(scheme)://app/index.html")!))
            }
            objc_setAssociatedObject(root, "spike", view, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// Minimal HTTP/1.1 server on localhost that serves `page` with COOP/COEP headers.
    private final class LocalServer {
        private var listener: NWListener?
        func start(_ ready: @escaping (UInt16) -> Void) {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            guard let listener = try? NWListener(using: params) else { return }
            self.listener = listener
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { DispatchQueue.main.async { ready(port) } }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let body = Data(PS2WebSpike.page.utf8)
                    var head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
                    head += "Cross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            listener.start(queue: .global())
        }
    }

    private final class Sink: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            NSLog("DUO_SPIKE %@", String(describing: message.body))
        }
    }

    /// Serves the Play! web build (`Play.js` / `Play.wasm`) from `dir`, a host page, and the
    /// disc image with HTTP range support, all cross-origin isolated.
    private final class PlayHandler: NSObject, WKURLSchemeHandler {
        let dir: URL
        let disc: URL?
        let host: URL?
        init(dir: URL, disc: URL?, host: URL?) { self.dir = dir; self.disc = disc; self.host = host }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let url = task.request.url!
            var headers = ["Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp",
                           "Cross-Origin-Resource-Policy": "same-origin", "Cache-Control": "no-store"]
            var status = 200
            var body = Data()
            switch url.path {
            case "/", "/index.html":
                let size = disc.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.int64Value ?? 0
                let args = ProcessInfo.processInfo.arguments
                let keys = args.firstIndex(of: "-webcore-play-keys").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? ""
                body = Data(PS2WebSpike.playPage.replacingOccurrences(of: "__DISC_SIZE__", with: "\(size)")
                    .replacingOccurrences(of: "__KEYS__", with: keys)
                    .replacingOccurrences(of: "__UNLIMITED__", with: args.contains("-webcore-play-unlimited") ? "1" : "0").utf8)
                headers["Content-Type"] = "text/html; charset=utf-8"
            case "/Play.js":
                let polyfill = "globalThis.SharedArrayBuffer ||= new WebAssembly.Memory({initial: 0, maximum: 0, shared: true}).buffer.constructor;\n"
                body = Data(polyfill.utf8) + ((try? Data(contentsOf: dir.appendingPathComponent("Play.js"))) ?? Data())
                headers["Content-Type"] = "text/javascript"
            case "/Play.wasm":
                body = (try? Data(contentsOf: dir.appendingPathComponent("Play.wasm"))) ?? Data()
                headers["Content-Type"] = "application/wasm"
            case "/disc":
                guard let disc, let handle = try? FileHandle(forReadingFrom: disc) else { status = 404; break }
                defer { try? handle.close() }
                if let range = task.request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                    let parts = range.dropFirst(6).split(separator: "-").compactMap { UInt64($0) }
                    if parts.count == 2 {
                        try? handle.seek(toOffset: parts[0])
                        body = (try? handle.read(upToCount: Int(parts[1] - parts[0] + 1))) ?? Data()
                        status = 206
                    }
                }
                headers["Content-Type"] = "application/octet-stream"
            case "/host-manifest":
                var files: [String] = []
                if let host, let e = FileManager.default.enumerator(at: host, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.append(String(f.path.dropFirst(host.path.count + 1)))
                    }
                }
                body = (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
                headers["Content-Type"] = "application/json"
            case let path where path.hasPrefix("/host/"):
                if let host { body = (try? Data(contentsOf: host.appendingPathComponent(String(path.dropFirst(6))))) ?? Data() }
                headers["Content-Type"] = "application/octet-stream"
            default:
                status = 404
            }
            headers["Content-Length"] = "\(body.count)"
            task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(body)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    static let playPage = """
    <!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;background:#000;color:#8f8;font:12px ui-monospace}canvas{width:100vw;height:75vw;display:block}#o{white-space:pre-wrap;padding:8px}</style></head>
    <body><canvas id=outputCanvas width=640 height=480 tabindex=0></canvas><div id=o></div>
    <script>
    globalThis.SharedArrayBuffer ||= new WebAssembly.Memory({initial: 0, maximum: 0, shared: true}).buffer.constructor;
    window.log = (k, v) => { document.getElementById('o').textContent += `${k}: ${v}\\n`; webkit.messageHandlers.spike.postMessage(`${k}=${v}`); };
    window.onerror = (m, s, l) => log('onerror', `${m} @${l}`);
    </script>
    <script type=module>
    import Play from './Play.js';
    const t0 = performance.now();
    try {
      const M = await Play({
        locateFile: p => location.origin + '/' + p,
        mainScriptUrlOrBlob: location.origin + '/Play.js',
        print: t => log('out', t), printErr: t => log('err', t),
      });
      log('moduleReady', `${(performance.now() - t0).toFixed(0)} ms`);
      M.FS.mkdir('/work');
      M.discImageDevice = {
        done: false,
        read(dst, off, size) {
          this.done = false;
          fetch('/disc', { headers: { Range: `bytes=${off}-${off + size - 1}` } })
            .then(r => r.arrayBuffer()).then(b => { M.HEAPU8.set(new Uint8Array(b), dst); this.done = true; });
        },
        getFileSize() { return __DISC_SIZE__; },
        isDone() { return this.done; },
      };
      if ('__UNLIMITED__' === '1') {
        const dir = '/home/web_user/.local/share/Play Data Files';
        M.FS.mkdirTree(dir);
        M.FS.writeFile(dir + '/config.xml', '<?xml version="1.0"?><Config><Preference Name="ps2.limitframerate" Type="boolean" Value="false"/></Config>');
        log('limit', 'off');
      }
      M.ccall('initVm', '', [], []);
      log('initVm', 'ok');
      const files = await (await fetch('/host-manifest')).json();
      if (files.length) {
        const t1 = performance.now(); let bytes = 0;
        await Promise.all(files.map(async f => {
          const data = new Uint8Array(await (await fetch('/host/' + f.split('/').map(encodeURIComponent).join('/'))).arrayBuffer());
          const full = '/vfs/host/' + f; M.FS.mkdirTree(full.substring(0, full.lastIndexOf('/'))); M.FS.writeFile(full, data); bytes += data.length;
        }));
        log('hostLoaded', `${files.length} files ${(bytes / 1e6).toFixed(1)} MB in ${(performance.now() - t1).toFixed(0)} ms`);
        const findHost = (dir) => {
          for (const n of M.FS.readdir(dir)) {
            if (n === '.' || n === '..' || dir === '/' && ['proc', 'dev', 'vfs'].includes(n)) continue;
            const full = (dir === '/' ? '' : dir) + '/' + n;
            if (!M.FS.isDir(M.FS.lstat(full).mode)) continue;
            if (full.endsWith('vfs/host')) return full;
            const r = findHost(full); if (r) return r;
          }
        };
        const hostDir = findHost('/');
        log('hostDir', hostDir);
        if (hostDir) { M.FS.rmdir(hostDir); M.FS.symlink('/vfs/host', hostDir); }
        const elf = files.find(f => /\\.elf$/i.test(f));
        M.bootElf('/vfs/host/' + elf); log('boot', elf);
      } else if (__DISC_SIZE__ > 0) { M.bootDiscImage('disc.iso'); log('boot', 'disc'); }
      window.press = (code, ms = 150) => {
        const c = document.getElementById('outputCanvas');
        c.dispatchEvent(new KeyboardEvent('keydown', { code, key: code, bubbles: true }));
        setTimeout(() => c.dispatchEvent(new KeyboardEvent('keyup', { code, key: code, bubbles: true })), ms);
      };
      const start = performance.now();
      setInterval(() => { log('fps', `${((performance.now() - start) / 1000).toFixed(0)}s ${M.getFrames() / 2}`); M.clearStats(); }, 2000);
      for (const step of '__KEYS__'.split(',').filter(Boolean)) {
        const [at, code, hold] = step.split(':');
        setTimeout(() => { press(code, Number(hold || 150)); log('key', `${code}@${at}`); }, Number(at));
      }
    } catch (e) { log('error', e + ' ' + (e.stack || '')); }
    </script></body></html>
    """

    private final class Handler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let body = Data(PS2WebSpike.page.utf8)
            let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": "\(body.count)",
                "Cross-Origin-Opener-Policy": "same-origin",
                "Cross-Origin-Embedder-Policy": "require-corp",
            ])!
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    static let page = """
    <!doctype html><html><body style="background:#111;color:#eee;font:16px -apple-system;padding:40px">
    <pre id=o>running…</pre>
    <script>
    const log = (k, v) => { document.getElementById('o').textContent += `\\n${k}: ${v}`; webkit.messageHandlers.spike.postMessage(`${k}=${v}`); };
    (async () => {
      log('crossOriginIsolated', self.crossOriginIsolated);
      log('SharedArrayBuffer', typeof SharedArrayBuffer);
      log('WebGL2', !!document.createElement('canvas').getContext('webgl2'));
      log('wasmSIMD', WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,123,3,2,1,0,10,10,1,8,0,65,0,253,15,253,98,11])));
      try {
        const mem = new WebAssembly.Memory({initial: 1, maximum: 16, shared: true});
        const buf = mem.buffer;
        log('sharedMemory', Object.prototype.toString.call(buf) + ' ctor=' + buf.constructor.name);
        const a = new Int32Array(buf);
        const src = 'onmessage = e => { const a = new Int32Array(e.data.buffer); for (let i = 0; i < 1000; i++) Atomics.add(a, 0, 1); postMessage(0); }';
        const w = new Worker(URL.createObjectURL(new Blob([src], {type: 'text/javascript'})));
        await new Promise(r => { w.onmessage = r; w.postMessage(mem); });
        log('wasmMemWorker', Atomics.load(a, 0));
      } catch (e) { log('wasmMemWorker', 'ERR ' + e); }
      log('isSecureContext', self.isSecureContext);
      log('origin', location.origin);
      try {
        const sab = new SharedArrayBuffer(16); const a = new Int32Array(sab);
        const src = 'onmessage = e => { const a = new Int32Array(e.data); for (let i = 0; i < 1000; i++) Atomics.add(a, 0, 1); postMessage(0); }';
        const w = new Worker(URL.createObjectURL(new Blob([src], {type: 'text/javascript'})));
        await new Promise(r => { w.onmessage = r; w.postMessage(sab); });
        log('workerAtomics', Atomics.load(a, 0));
      } catch (e) { log('workerAtomics', 'ERR ' + e); }
      const bytes = new Uint8Array([0,97,115,109,1,0,0,0, 1,6,1,96,1,127,1,127, 3,2,1,0, 7,5,1,1,102,0,0,
        10,50,1,48, 1,2,127, 2,64, 3,64, 32,1,32,0,79,13,1, 32,2,65,141,204,229,0,108, 32,1,65,223,230,187,227,3,106,106,33,2,
        32,1,65,1,106,33,1, 12,0, 11,11, 32,2,11]);
      const { instance } = await WebAssembly.instantiate(bytes);
      const n = 300000000;
      instance.exports.f(1000000);
      const t0 = performance.now(); const r = instance.exports.f(n); const t1 = performance.now();
      log('wasmLoop', `${((t1 - t0) * 1e6 / n).toFixed(3)} ns/iter (${(t1 - t0).toFixed(0)} ms, r=${r})`);
      log('done', 1);
    })().catch(e => log('error', e));
    </script></body></html>
    """
}
#endif
