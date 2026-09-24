import Foundation
import UIKit
import WebKit
import CoreHaptics

/// Receives DualShock 2 input from `PS2ControllerView`: the libretro session of other cores or
/// the PS2 web core.
@MainActor
protocol PS2InputSink: AnyObject {
    func setPS2Button(_ id: Int, pressed: Bool)
    func setPS2Analog(stick: EmulatorSession.PS2Stick, x: Double, y: Double)
}

extension EmulatorSession: PS2InputSink {}

/// Runs the Play! PS2 core (WebAssembly) in a WKWebView, whose WebKit JIT compiles the
/// recompiled MIPS code. Owns the pad state, memory card mirror, rumble and lifecycle.
@MainActor
final class PS2WebCore: NSObject, ObservableObject, PS2InputSink {
    enum State: Equatable {
        case idle, booting, running, paused
        case failed(String)
    }

    struct Content {
        /// Disc image (ISO, CUE, CSO, CHD, ISZ); multi-file images read their tracks next to it.
        var disc: URL?
        /// QA: a folder holding a homebrew ELF plus its assets (mounted as `host:`).
        var elfFolder: URL?
        var elfName: String?
        var memoryCard: URL
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hasFrame = false
    @Published private(set) var fps = 0

    let webView: WKWebView
    private let content: Content
    private let schemeHandler: PS2WebSchemeHandler
    private var pad = PS2PadState()
    private var sentPad = PS2PadState()
    private var padScheduled = false
    private var userPaused = false
    private var observers: [NSObjectProtocol] = []
    private let rumble = PS2Rumble()

    init(content: Content) {
        self.content = content
        let bundleRoot = Bundle.main.url(forResource: "PS2Web", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("PS2Web")
        try? FileManager.default.createDirectory(at: content.memoryCard, withIntermediateDirectories: true)
        schemeHandler = PS2WebSchemeHandler(bundleRoot: bundleRoot, discDirectory: content.disc?.deletingLastPathComponent(),
                                            cardRoot: content.memoryCard, hostRoot: content.elfFolder)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PS2WebSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.suppressesIncrementalRendering = true
        let controller = WKUserContentController()
        var boot: [String: Any] = [:]
        if let disc = content.disc { boot["disc"] = disc.lastPathComponent }
        if let elf = content.elfName { boot["elf"] = elf }
        #if DEBUG
        boot["debug"] = true
        #endif
        let json = (try? JSONSerialization.data(withJSONObject: boot)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        controller.addUserScript(WKUserScript(source: "window.duoConfig = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        super.init()
        controller.add(WeakMessageHandler(self), name: "duo")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // No scroll edge effect: it dimmed a band under the status bar over the picture's
        // blurred surround, ending in a hard line.
        for effect in [webView.scrollView.topEdgeEffect, webView.scrollView.bottomEdgeEffect,
                       webView.scrollView.leftEdgeEffect, webView.scrollView.rightEdgeEffect] {
            effect.isHidden = true
        }
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Lifecycle

    func start() {
        guard state == .idle else { return }
        state = .booting
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        })
        webView.load(URLRequest(url: URL(string: "\(PS2WebSchemeHandler.origin)/index.html")!))
        log("start disc=\(content.disc?.lastPathComponent ?? "-") elf=\(content.elfName ?? "-")")
    }

    func pause() {
        userPaused = true
        suspend()
    }

    func resume() {
        userPaused = false
        guard state == .paused else { return }
        state = .running
        call("window.duo.resume()")
    }

    /// Pauses the VM and flushes the memory card, then calls `completion` (also when the page is gone).
    func stop(completion: @escaping () -> Void) {
        suspend()
        rumble.stop()
        webView.evaluateJavaScript("window.duo ? window.duo.syncCard() : 0") { _, _ in
            // Card messages posted by syncCard are delivered before this reply.
            completion()
        }
    }

    /// Releases the web content process; the core cannot be restarted afterwards.
    func tearDown() {
        rumble.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "duo")
        webView.loadHTMLString("", baseURL: nil)
        state = .idle
    }

    private func suspend() {
        guard state == .running || state == .booting else { return }
        state = .paused
        rumble.stop()
        call("window.duo && window.duo.pause()")
    }

    private func enterBackground() {
        guard state == .running else { return }
        log("background: pause")
        suspend()
    }

    private func enterForeground() {
        guard state == .paused, !userPaused else { return }
        log("foreground: resume")
        state = .running
        call("window.duo && window.duo.resume()")
    }

    #if DEBUG
    /// `-ps2-core-card-selftest`: a file written on the core's memory card must appear in the
    /// game's card folder, and disappear again after the core deletes it.
    private func runCardSelfTest() {
        let file = content.memoryCard.appendingPathComponent("DUOQA-SELFTEST/probe.bin")
        call("window.duo.debugCardWrite('DUOQA-SELFTEST/probe.bin', 'duo-card-probe')")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let data = try? Data(contentsOf: file)
            NSLog("DUO_PS2_CORE card-selftest write %@", data == Data("duo-card-probe".utf8) ? "PASS" : "FAIL")
            self.call("window.duo.debugCardDelete('DUOQA-SELFTEST/probe.bin')")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let gone = !FileManager.default.fileExists(atPath: file.path)
                let dirGone = !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
                NSLog("DUO_PS2_CORE card-selftest delete %@ (dir removed: %d)", gone ? "PASS" : "FAIL", dirGone ? 1 : 0)
            }
        }
    }
    #endif

    // MARK: Picture

    private var pictureRect: CGRect?

    /// Where the page draws the picture (web view points); the rest of the view gets the blurred
    /// surround.
    func setPicture(_ rect: CGRect) {
        guard rect != pictureRect, rect.width > 0, rect.height > 0 else { return }
        pictureRect = rect
        sendPicture()
    }

    private func sendPicture() {
        guard let rect = pictureRect else { return }
        call("window.duo && window.duo.setPicture(\(rect.minX), \(rect.minY), \(rect.width), \(rect.height))")
    }

    // MARK: Input

    func setPS2Button(_ id: Int, pressed: Bool) {
        pad.setButton(libretroID: id, pressed: pressed)
        schedulePad()
    }

    func setPS2Analog(stick: EmulatorSession.PS2Stick, x: Double, y: Double) {
        pad.setStick(stick == .left ? .left : .right, x: x, y: y)
        schedulePad()
    }

    /// Coalesces bursts of touch events into one message per run-loop turn.
    private func schedulePad() {
        guard !padScheduled else { return }
        padScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.padScheduled = false
            guard self.pad != self.sentPad, self.state == .running || self.state == .booting else { return }
            self.sentPad = self.pad
            self.call("window.duo && window.duo.setPad(\(self.pad.javaScriptArguments))")
        }
    }

    // MARK: Page messages

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "booted":
            log("booted in \(message["ms"] ?? "?") ms, card files \(message["cardFiles"] ?? 0)")
            if state == .booting { state = .running }
            sendPicture()
            call("window.duo.resize()")
            if pad != PS2PadState() { sentPad = PS2PadState(); schedulePad() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ps2-core-card-selftest") { runCardSelfTest() }
            // `-ps2-core-audio-capture [delay]` records 10 s of output, 20 s (or `delay` s) after boot.
            let arguments = ProcessInfo.processInfo.arguments
            if let i = arguments.firstIndex(of: "-ps2-core-audio-capture") {
                let delay = arguments.indices.contains(i + 1) ? Double(arguments[i + 1]) ?? 20 : 20
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.call("window.duo.debugCaptureAudio(10)") }
            }
            // `-ps2-core-press 8:0,11:0` taps libretro button id 0 (✕) 8 s and 11 s after boot.
            if let i = arguments.firstIndex(of: "-ps2-core-press"), arguments.indices.contains(i + 1) {
                for step in arguments[i + 1].split(separator: ",") {
                    let parts = step.split(separator: ":")
                    guard parts.count == 2, let at = Double(parts[0]), let id = Int(parts[1]) else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                        self?.setPS2Button(id, pressed: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.setPS2Button(id, pressed: false) }
                    }
                }
            }
            #endif
        case "firstFrame":
            hasFrame = true
        case "stats":
            fps = message["fps"] as? Int ?? 0
            #if DEBUG
            NSLog("DUO_PS2_CORE fps=%d audio=%@ buffered=%@ written=%@", fps, String(describing: message["audioState"] ?? "-"),
                  String(describing: message["audioBuffered"] ?? "-"), String(describing: message["audioWritten"] ?? "-"))
            if let a = message["audioStats"] as? [String: Any] {
                NSLog("DUO_PS2_AUDIO quanta=%@ underruns=%@ skips=%@ min=%@ step=%@ rate=%@ base=%@", "\(a["quanta"] ?? "-")", "\(a["underruns"] ?? "-")",
                      "\(a["skips"] ?? "-")", "\(a["minAvailable"] ?? "-")", "\(a["step"] ?? "-")", "\(message["audioRate"] ?? "-")", "\(message["baseLatency"] ?? "-")")
            }
            #endif
        case "rumble":
            let large = message["large"] as? Int ?? 0, small = message["small"] as? Int ?? 0
            rumble.set(large: UInt8(clamping: large), small: UInt8(clamping: small))
        case "card":
            applyCard(message)
        #if DEBUG
        case "audioCapture":
            if let base64 = message["data"] as? String, let pcm = Data(base64Encoded: base64) {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("duo_audio_capture.pcm")
                try? pcm.write(to: url)
                NSLog("DUO_PS2_AUDIO capture saved %d bytes", pcm.count)
            }
        #endif
        case "error":
            let text = message["message"] as? String ?? "unknown"
            log("error \(text)")
            if text.hasPrefix("boot") {
                state = .failed(String(localized: "无法启动：光盘里没有可运行的 PS2 程序"))
            } else if text.hasPrefix("abort") {
                state = .failed(String(localized: "PS2 内核已停止"))
            }
        case "log":
            #if DEBUG
            if let text = message["message"] as? String { NSLog("DUO_PS2_CORE log %@", String(text.prefix(300))) }
            #endif
        default:
            break
        }
    }

    /// Mirrors a memory card change from the core into the game's card folder.
    private func applyCard(_ message: [String: Any]) {
        guard let op = message["op"] as? String, let path = message["path"] as? String,
              let url = PS2CardPath.resolve(path, in: content.memoryCard) else { return }
        let fm = FileManager.default
        switch op {
        case "mkdir":
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        case "put":
            guard let base64 = message["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        case "delete":
            try? fm.removeItem(at: url)
        default:
            return
        }
        #if DEBUG
        NSLog("DUO_PS2_CORE card %@ %@", op, path)
        #endif
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func log(_ text: String) {
        #if DEBUG
        NSLog("DUO_PS2_CORE %@", text)
        #endif
    }
}

extension PS2WebCore: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("web content process terminated")
        rumble.stop()
        state = .failed(String(localized: "PS2 内核已停止"))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state = .failed(error.localizedDescription)
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var core: PS2WebCore?
    init(_ core: PS2WebCore) { self.core = core }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { core?.receive(message.body) }
    }
}

/// DualShock 2 motors on the iPhone Taptic Engine: the large motor as a continuous rumble whose
/// intensity follows its level, the small (on/off) motor as a sharp buzz.
@MainActor
final class PS2Rumble {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var level: (large: UInt8, small: UInt8) = (0, 0)

    func set(large: UInt8, small: UInt8) {
        guard (large, small) != level else { return }
        level = (large, small)
        guard large > 0 || small > 0 else { stopPlayer(); return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try ensureEngine()
            if player == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ], relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                try player.start(atTime: CHHapticTimeImmediate)
                self.player = player
            }
            let intensity = max(Float(large) / 255, small > 0 ? 0.45 : 0)
            let sharpness: Float = small > 0 ? 0.8 : 0.25
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        } catch {
            stop()
        }
        #if DEBUG
        NSLog("DUO_PS2_CORE rumble large=%d small=%d", large, small)
        #endif
    }

    func stop() {
        level = (0, 0)
        stopPlayer()
        engine?.stop()
        engine = nil
    }

    private func stopPlayer() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private func ensureEngine() throws -> CHHapticEngine {
        if let engine { return engine }
        let engine = try CHHapticEngine()
        engine.playsHapticsOnly = true
        engine.isAutoShutdownEnabled = true
        // Called on CoreHaptics' own queue.
        engine.resetHandler = { [weak self] in
            DispatchQueue.main.async { self?.player = nil }
        }
        engine.stoppedHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.player = nil; self?.engine = nil }
        }
        try engine.start()
        self.engine = engine
        return engine
    }
}
