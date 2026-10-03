import SwiftUI
import UIKit
import SceneKit
import UniformTypeIdentifiers
import PhotosUI
import MediaPlayer
import AVFAudio

struct ContentView: View {
    @ObservedObject var session: EmulatorSession
    @EnvironmentObject private var proEntitlement: DuoProEntitlement
    @EnvironmentObject private var proStore: DuoProStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = GameLibraryStore()
    @State private var showingImporter = false
    @State private var activeGame: GameLibraryItem?
    @State private var libraryHidden = false
    @State private var isExiting = false
    @State private var libraryGeneration = UUID()
    @State private var showingSettings = false
    @State private var showingPaywallPreview = false
    @State private var appearancePreviewGame: GameLibraryItem?
    @State private var replayGuide = false
    @State private var playStartedAt: Date?
    @AppStorage("interactiveTutorialCompleted.v2") private var tutorialCompleted = false
    @AppStorage("scrollCueEnabled") private var scrollCueEnabled = true
    @AppStorage("ndsRenderMode") private var ndsRenderMode = DuoRenderMode.hd
    @AppStorage("pspRenderMode") private var pspRenderMode = DuoRenderMode.hd
    @AppStorage("pspFrameRateMode") private var pspFrameRateMode = DuoPSPFrameRateMode.high

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !tutorialCompleted || replayGuide {
                CartridgeTutorialView {
                    tutorialCompleted = true
                    replayGuide = false
                }
            } else {
                if activeGame != nil {
                    EmulatorView(session: session, game: activeGame!, isExiting: isExiting, onExit: exitGame)
                }
                GameLibraryView(
                    library: library, isExiting: isExiting,
                    onImport: { showingImporter = true },
                    onLaunch: beginEmulation, onFinished: finishInsertion,
                    onReturned: finishExit, onSettings: { showingSettings = true },
                    isVisible: !libraryHidden
                )
                .equatable()
                .id(libraryGeneration)
                .opacity(libraryHidden ? 0 : 1)
                .allowsHitTesting(!libraryHidden && !isExiting)
                .accessibilityHidden(libraryHidden || isExiting)
                .zIndex(100)
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-psp-model-preview") {
                PSPGameView(session: session, onExit: {}).zIndex(200)
            }
            #endif
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "pspHDDefault.v2") {
                // Adopt HD once; later manual choices survive app launches.
                pspRenderMode = .hd
                UserDefaults.standard.set(true, forKey: "pspHDDefault.v2")
            }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-appearance-test") {
                do { try DuoProStore.shared.verifyAppearancePersistence() }
                catch { print("DUO_APPEARANCE_TEST_FAILED: \(error)"); exit(8) }
            }
            if arguments.contains("-appearance-preview") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    appearancePreviewGame = library.games.first(where: {
                        arguments.contains("-appearance-preview-psp") ? $0.platform == .psp : $0.platform == .nds
                    })
                }
            }
            if arguments.contains("-psp-model-preview") { DuoOrientation.setPSPGameplay(true) }
            if arguments.contains("-psp-orientation-test") {
                Task { @MainActor in
                    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { exit(9) }
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                    try? await Task.sleep(for: .milliseconds(800))
                    precondition(scene.interfaceOrientation == .portrait)
                    if DuoOrientation.isDuoDevice {
                        DuoOrientation.setPSPGameplay(true)
                        try? await Task.sleep(for: .milliseconds(500))
                        precondition(scene.interfaceOrientation == .portrait && DuoOrientation.allowed == .allButUpsideDown)
                        print("DUO_PSP_ORIENTATION_PASS: Duo retains portrait and unrestricted orientations")
                        fflush(stdout)
                        exit(0)
                    }
                    DuoOrientation.setPSPGameplay(true)
                    try? await Task.sleep(for: .milliseconds(800))
                    precondition(scene.interfaceOrientation.isLandscape && DuoOrientation.allowed == .landscape)
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in
                        print("DUO_PSP_PORTRAIT_BLOCKED: system rejected portrait during PSP gameplay")
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    precondition(scene.interfaceOrientation.isLandscape)
                    DuoOrientation.setPSPGameplay(false)
                    try? await Task.sleep(for: .milliseconds(800))
                    precondition(scene.interfaceOrientation == .portrait && DuoOrientation.allowed == .allButUpsideDown)
                    print("DUO_PSP_ORIENTATION_PASS: portrait launch rotates; portrait blocked; exit restores portrait")
                    fflush(stdout)
                    exit(0)
                }
            }
            if arguments.contains("-psp-landscape-preview"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            let cleanupMarker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(".cleanup-psp-controller-fixture")
            if FileManager.default.fileExists(atPath: cleanupMarker.path) {
                let fixture = ROMFiles.supportDirectory().appendingPathComponent("ROMs/controller.pbp")
                try? FileManager.default.removeItem(at: fixture)
                try? FileManager.default.removeItem(at: cleanupMarker)
                library.reload()
            }
            if let index = arguments.firstIndex(of: "-format-test-root"), index + 1 < arguments.count {
                Task { await ROMValidation.run(root: URL(fileURLWithPath: arguments[index + 1]), session: session) }
            }
            if arguments.contains("-tutorial-preview") || arguments.contains("-tutorial-test") {
                replayGuide = true
            }
            if arguments.contains("-settings-test") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showingSettings = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard let window = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
                            .first(where: \.isKeyWindow) else { exit(2) }
                        if arguments.contains("-frame-rate-settings-test") {
                            func scrollSettings(_ view: UIView) {
                                if let scroll = view as? UIScrollView,
                                   scroll.contentSize.height > scroll.bounds.height + 300 {
                                    scroll.setContentOffset(CGPoint(x: 0, y: min(420, scroll.contentSize.height - scroll.bounds.height)), animated: false)
                                    scroll.layoutIfNeeded()
                                }
                                view.subviews.forEach(scrollSettings)
                            }
                            scrollSettings(window)
                            window.layoutIfNeeded()
                        }
                        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                        let image = renderer.image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("settings-test.png")
                        try? image.pngData()?.write(to: target, options: .atomic)
                        print("DUO_SETTINGS_TEST_SCREENSHOT: \(target.path)")
                        fflush(stdout)
                        exit(FileManager.default.fileExists(atPath: target.path) ? 0 : 3)
                    }
                }
            }
            if arguments.contains("-paywall-preview") { showingPaywallPreview = true }
            if arguments.contains("-library-ui-screenshot") {
                DispatchQueue.main.asyncAfter(deadline: .now() + (arguments.contains("-psp-controls-test") ? 10.0 : 2.0)) {
                    guard let window = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
                        .first(where: \.isKeyWindow) else { exit(5) }
                    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                    let image = renderer.image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("library-ui.png")
                    try? image.pngData()?.write(to: target, options: .atomic)
                    print("DUO_LIBRARY_UI_SCREENSHOT: \(target.path)")
                    fflush(stdout)
                    exit(FileManager.default.fileExists(atPath: target.path) ? 0 : 6)
                }
            }
            if arguments.contains("-emulator-test") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard activeGame == nil,
                          let game = library.games.first(where: { $0.url.lastPathComponent == "TrailMix.nds" }) else { return }
                    activeGame = game
                    session.start(romURL: game.url)
                    if session.isRunning { finishInsertion() }
                    try? await Task.sleep(for: .seconds(5))
                    session.saveGame()
                    session.stop()
                    if (session.topImage?.dataProvider?.data).map { Set(($0 as Data)).count > 8 } == true {
                        print("DUO_EMULATOR_TEST_PASS: TrailMix ran for 5 seconds with video pixels")
                    } else {
                        print("DUO_EMULATOR_TEST_FAIL: TrailMix ran but video stayed white")
                    }
                    fflush(stdout)
                    exit(0)
                }
            }
            if let index = arguments.firstIndex(of: "-game-frame-test"), index + 1 < arguments.count {
                let filename = arguments[index + 1]
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("PSPValidation")
                        .appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
                    let fixtureGame: GameLibraryItem? = FileManager.default.fileExists(atPath: fixture.path)
                        ? GameLibraryItem(url: fixture, title: filename, detail: "验证样例", platform: .psp,
                                          cartridgeKind: .umd, icon: nil, isBundledTest: true,
                                          programID: nil, productID: nil) : nil
                    guard activeGame == nil,
                          let game = library.games.first(where: { $0.url.lastPathComponent == filename }) ?? fixtureGame else {
                        print("DUO_GAME_FRAME_TEST_FAIL: game not found: \(filename)")
                        fflush(stdout)
                        exit(4)
                    }
                    activeGame = game
                    if filename == "TrailMix.nds" && !arguments.contains("-store-review") {
                        var configuration = session.runtimeConfiguration
                        configuration.preferences.speed = 4
                        session.runtimeConfiguration = configuration
                    }
                    session.runtimeConfiguration.renderMode = ndsRenderMode
                    session.runtimeConfiguration.pspRenderMode = pspRenderMode
                    session.runtimeConfiguration.pspFrameRateMode = pspFrameRateMode
                    session.start(romURL: game.url)
                    if session.isRunning { finishInsertion() }
                    if arguments.contains("-menu-button-test") {
                        // Deliberately release in the same UI turn. The
                        // momentary-button latch must keep both inputs visible
                        // to at least one following core poll.
                        session.pressMomentary(.select)
                        session.releaseMomentary(.select)
                        try? await Task.sleep(for: .milliseconds(180))
                        session.pressMomentary(.start)
                        session.releaseMomentary(.start)
                        try? await Task.sleep(for: .milliseconds(180))
                        session.togglePause()
                        let paused = session.isPaused
                        try? await Task.sleep(for: .milliseconds(120))
                        session.togglePause()
                        print("DUO_HOME_BUTTON_PASS: paused=\(paused) resumed=\(!session.isPaused)")
                        fflush(stdout)
                    }
                    if arguments.contains("-face-button-test") {
                        // Exercise the exact short-tap path used by the
                        // on-screen controls. Each input must survive long
                        // enough for the NDS core to observe it.
                        for input in [DuoInput.a, .b, .x, .y] {
                            session.pressMomentary(input)
                            session.releaseMomentary(input)
                            try? await Task.sleep(for: .milliseconds(180))
                        }
                        print("DUO_FACE_BUTTON_TEST_SENT: A B X Y")
                        fflush(stdout)
                    }
                    try? await Task.sleep(for: .seconds(5))
                    if filename.localizedCaseInsensitiveContains("Mario Kart DS") {
                        session.touch(at: CGPoint(x: 0.5, y: 0.5), in: CGSize(width: 1, height: 1))
                        try? await Task.sleep(for: .milliseconds(150))
                        session.releaseTouch()
                        try? await Task.sleep(for: .seconds(2))
                        session.press(.start)
                        try? await Task.sleep(for: .milliseconds(150))
                        session.release(.start)
                        try? await Task.sleep(for: .seconds(2))
                        for _ in 0..<8 {
                            session.press(.a)
                            try? await Task.sleep(for: .milliseconds(150))
                            session.release(.a)
                            try? await Task.sleep(for: .milliseconds(1500))
                        }
                        try? await Task.sleep(for: .seconds(8))
                    } else if filename.localizedCaseInsensitiveContains("Call of Duty") {
                        // Let the intro finish, then advance through the title and
                        // resume screens so the frame test reaches 3D gameplay.
                        try? await Task.sleep(for: .seconds(14))
                        for _ in 0..<12 {
                            session.press(.a)
                            try? await Task.sleep(for: .milliseconds(140))
                            session.release(.a)
                            try? await Task.sleep(for: .seconds(2))
                        }
                        session.press(.start)
                        try? await Task.sleep(for: .milliseconds(140))
                        session.release(.start)
                        try? await Task.sleep(for: .seconds(5))
                    } else if filename == "TrailMix.nds" {
                        // Confirm language, start a run, then leave the player still until Game Over.
                        for _ in 0..<2 {
                            session.press(.a)
                            try? await Task.sleep(for: .milliseconds(150))
                            session.release(.a)
                            try? await Task.sleep(for: .seconds(2))
                        }
                        try? await Task.sleep(for: .seconds(arguments.contains("-store-review") ? 0.2 : 35))
                    } else if game.platform == .psp {
                        if filename == "controller.pbp" {
                            session.setCirclePad(x: 0.75, y: -0.5)
                            session.setPSPButton(0, pressed: true)
                            try? await Task.sleep(for: .milliseconds(250))
                            session.setPSPButton(0, pressed: false)
                            session.setCirclePad(x: 0, y: 0)
                        }
                        try? await Task.sleep(for: .seconds(2))
                    } else {
                        try? await Task.sleep(for: .seconds(3))
                    }
                    if let index = arguments.firstIndex(of: "-psp-sample-seconds"), arguments.indices.contains(index + 1),
                       let seconds = Double(arguments[index + 1]), seconds > 0, seconds <= 300 {
                        try? await Task.sleep(for: .seconds(seconds))
                    }
                    if arguments.contains("-sustained-game-test") {
                        try? await Task.sleep(for: .seconds(75))
                    }
                    if game.platform == .psp, arguments.contains("-psp-drive-test") {
                        print("DUO_PSP_DRIVE_READY: manual driving probe active")
                        return
                    }
                    if game.platform == .psp, arguments.contains("-psp-performance-test") {
                        // Performance capture must never drive the user's controls.
                        try? await Task.sleep(for: .seconds(240))
                    }
                    if game.platform == .psp, arguments.contains("-psp-lifecycle-test") {
                        session.togglePause()
                        session.verifyPSPStateRoundTrip()
                        session.togglePause()
                        try? await Task.sleep(for: .seconds(2))
                        session.stop()
                        session.start(romURL: game.url)
                        try? await Task.sleep(for: .seconds(4))
                        precondition(session.isRunning && session.topImage?.width == (pspRenderMode == .hd ? 960 : 480))
                        print("DUO_PSP_LIFECYCLE_PASS: pause, state round trip, resume, shutdown, second GPU launch at selected resolution")
                    }
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    if let top = session.topImage.flatMap({ UIImage(cgImage: $0).pngData() }) {
                        try? top.write(to: directory.appendingPathComponent("game-frame-top.png"), options: .atomic)
                    }
                    if let bottom = session.bottomImage.flatMap({ UIImage(cgImage: $0).pngData() }) {
                        try? bottom.write(to: directory.appendingPathComponent("game-frame-bottom.png"), options: .atomic)
                    }
                    if arguments.contains("-game-ui-screenshot"),
                       let window = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
                        .first(where: \.isKeyWindow) {
                        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                        try? image.pngData()?.write(
                            to: directory.appendingPathComponent("game-ui.png"), options: .atomic
                        )
                    }
                    print("DUO_GAME_FRAME_TEST_RESULT: running=\(session.isRunning) top=\(session.topImage?.width ?? 0)x\(session.topImage?.height ?? 0) bottom=\(session.bottomImage?.width ?? 0)x\(session.bottomImage?.height ?? 0)")
                    fflush(stdout)
                    if game.platform == .psp, arguments.contains("-psp-performance-test") {
                        print("DUO_PSP_PERFORMANCE_CAPTURE_FINISHED: leaving game running for manual play")
                        return
                    }
                    session.stop()
                    if arguments.contains("-delete-test-rom-on-exit") {
                        try? FileManager.default.removeItem(at: game.url)
                    }
                    exit(0)
                }
            }
            if arguments.contains("-mk64-test") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard activeGame == nil,
                          let game = library.games.first(where: { $0.url.lastPathComponent == "MK64-3DS.3dsx" }) else { return }
                    activeGame = game
                    session.start(romURL: game.url)
                    if session.isRunning { finishInsertion() }
                    try? await Task.sleep(for: .seconds(5))
                    let audioStarted = session.isAudioRunning
                    session.touch(at: CGPoint(x: 0.5, y: 0.5), in: CGSize(width: 1, height: 1))
                    try? await Task.sleep(for: .milliseconds(250))
                    session.releaseTouch()
                    try? await Task.sleep(for: .seconds(2))
                    session.stop()
                    print("DUO_MK64_TEST_RESULT audio=\(audioStarted) touch=sent save=stop-triggered")
                    fflush(stdout)
                    exit(0)
                }
            }
            if arguments.contains("-duopro-test") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    let requestedPlatform = arguments.first(where: { $0.hasPrefix("-duopro-test-platform=") })?.split(separator: "=", maxSplits: 1).last.map(String.init)
                    let selectedPlatform: GamePlatform? = switch requestedPlatform {
                    case .some(GamePlatform.nds.rawValue): .nds
                    case .some(GamePlatform.n64.rawValue): .n64
                    case .some(GamePlatform.threeDS.rawValue): .threeDS
                    default: nil
                    }
                    let platforms: [GamePlatform] = selectedPlatform.map { [$0] } ?? [.nds, .n64, .threeDS]
                    let targets = platforms.compactMap { platform -> GameLibraryItem? in
                        if platform == .n64,
                           let fixture = library.games.first(where: { $0.url.lastPathComponent == "InputCPU.z64" }) { return fixture }
                        return library.games.first { $0.platform == platform }
                    }
                    guard targets.count == platforms.count else { exit(4) }
                    var statePassed = true
                    for game in targets {
                        print("DUO_PRO_TEST_START \(game.platform.rawValue)"); fflush(stdout)
                        session.runtimeConfiguration = DuoRuntimeConfiguration(preferences: DuoGamePreferences(), isPro: true)
                        session.start(romURL: game.url)
                        guard session.isRunning else { statePassed = false; continue }
                        try? await Task.sleep(for: .seconds(1))
                        let before = proStore.snapshots(for: game.url).count
                        session.saveSnapshot(name: "自动测试")
                        print("DUO_PRO_TEST_SAVED \(game.platform.rawValue)"); fflush(stdout)
                        let snapshots = proStore.snapshots(for: game.url)
                        if let snapshot = snapshots.first { session.loadSnapshot(snapshot) }
                        print("DUO_PRO_TEST_LOADED \(game.platform.rawValue)"); fflush(stdout)
                        statePassed = statePassed && snapshots.count == before + 1
                        session.stop()
                        print("DUO_PRO_TEST_STOPPED \(game.platform.rawValue)"); fflush(stdout)
                    }
                    let game = targets[0]
                    proStore.update(game.url) { $0.favorite = true; $0.category = "测试"; $0.resolutionScale = 2 }
                    let backup = try? proStore.createBackup()
                    let passed = statePassed && backup != nil && proStore.preferences(for: game.url).favorite
                    let platformNames = platforms.map(\.rawValue).joined(separator: ",")
                    print(passed ? "DUO_PRO_TEST_PASS \(platformNames) snapshot-load preferences backup" : "DUO_PRO_TEST_FAIL \(platformNames) state")
                    fflush(stdout); exit(passed ? 0 : 6)
                }
            }
            #endif
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                GameSettingsView(
                    library: library,
                    scrollCueEnabled: $scrollCueEnabled,
                    renderMode: $ndsRenderMode,
                    replayGuide: {
                        showingSettings = false
                        replayGuide = true
                    },
                    dismiss: { showingSettings = false }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPaywallPreview) { NavigationStack { DuoPaywallView() } }
        .sheet(item: $appearancePreviewGame) { game in
            NavigationStack { CartridgeAppearanceEditor(game: game, library: library) }
        }
        .onChange(of: showingSettings) { _, visible in if !visible { library.reload() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.releaseAllInputs(); session.saveGame() }
        }
        .onChange(of: session.gameRequestedExit) { _, requested in
            if requested { exitGame() }
        }
        .onChange(of: session.isRunning) { _, running in
            if !running, !isExiting { activeGame = nil }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: UTType.supportedGameFiles,
                      allowsMultipleSelection: proEntitlement.isUnlocked) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            guard !session.isRunning else { library.importError = String(localized: "请先退出游戏再导入文件"); return }
            Task {
                var imported: [GameLibraryItem] = []
                for url in urls {
                    if let game = await library.importGame(from: url) { imported.append(game) }
                }
                guard urls.count == 1, let game = imported.first,
                      game.isInstalledTitle || game.isBundledMK64Port else { return }
                library.importMessage = nil; beginEmulation(of: game)
                if session.isRunning { finishInsertion() }
            }
        }
        .overlay {
            if library.isImporting {
                ProgressView(String(localized: "正在解压、检查并导入…"))
                    .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.3))
            }
        }
        .alert(String(localized: "导入完成"), isPresented: Binding(get: { library.importMessage != nil }, set: { if !$0 { library.importMessage = nil } })) {
            Button(String(localized: "好")) { library.importMessage = nil }
        } message: { Text(library.importMessage ?? "") }
        .alert(String(localized: "无法启动"), isPresented: Binding(get: { session.launchError != nil }, set: { if !$0 { session.launchError = nil } })) {
            Button(String(localized: "好")) { session.launchError = nil }
        } message: { Text(session.launchError ?? "") }
        .alert(String(localized: "无法导入"), isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) { Button(String(localized: "好"), role: .cancel) { library.importError = nil } }
        message: { Text(library.importError ?? String(localized: "未知错误")) }
    }

    private func beginEmulation(of game: GameLibraryItem) {
        guard activeGame == nil, !library.isImporting else { return }
        if game.platform == .ps2 {
            // No PS2 core yet: the game screen shows its placeholder without a running session.
            activeGame = game
            playStartedAt = Date()
            return
        }
        session.runtimeConfiguration = DuoRuntimeConfiguration(
            preferences: proStore.preferences(for: game.url),
            isPro: proEntitlement.isUnlocked,
            renderMode: ndsRenderMode,
            pspRenderMode: pspRenderMode,
            pspFrameRateMode: pspFrameRateMode
        )
        session.start(romURL: game.url)
        if session.isRunning {
            activeGame = game
            playStartedAt = Date()
            DuoExternalDisplayCoordinator.shared.attach(session, enabled: proEntitlement.isUnlocked)
            if proEntitlement.isUnlocked {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if session.isRunning { session.saveSnapshot(name: String(localized: "启动前安全快照"), automatic: true) }
                }
            }
        }
    }
    private func finishInsertion() {
        guard (session.isRunning || activeGame?.platform == .ps2) && activeGame != nil else {
            libraryGeneration = UUID()
            libraryHidden = false
            return
        }
        if activeGame?.platform == .psp { DuoOrientation.setPSPGameplay(true) }
        withAnimation(.linear(duration: 0.12)) { libraryHidden = true }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cartridge-roundtrip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                assert(session.isRunning && activeGame != nil)
                print("DUO_GAME_HANDOFF_PASS: emulator running after insertion audio=\(session.isAudioRunning)")
                fflush(stdout)
                exitGame()
            }
        }
        #endif
    }
    private func exitGame() {
        guard activeGame != nil, !isExiting else { return }
        isExiting = true
        session.saveGame()
        if session.isRunning && !session.isPaused { session.togglePause() }
        if activeGame?.platform == .ps2, let runtime = PS2RuntimeModel.active {
            // The game screen plays its half first (TV off, tray, disc flight); the library then
            // continues from the same frame, or cross-fades in with Reduce Motion.
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            runtime.playExit(reduceMotion: reduceMotion) {
                if reduceMotion {
                    withAnimation(.easeInOut(duration: 0.3)) { libraryHidden = false }
                } else {
                    libraryHidden = false
                }
            }
        } else if activeGame?.platform == .psp {
            // The insertion scene takes ownership of the actual runtime mesh in
            // this same update, so a second console never crossfades over it.
            libraryHidden = false
        } else {
            withAnimation(.linear(duration: 0.12)) { libraryHidden = false }
        }
    }
    private func finishExit() {
        guard isExiting else { return }
        // PS2 has no core yet, so the shared session is not running for it.
        let usesSession = activeGame?.platform != .ps2
        if proEntitlement.isUnlocked && usesSession { session.saveSnapshot(name: String(localized: "退出时安全快照"), automatic: true) }
        if let game = activeGame, let playStartedAt { proStore.recordPlay(game.url, seconds: Date().timeIntervalSince(playStartedAt)) }
        if usesSession { session.stop() }
        DuoExternalDisplayCoordinator.shared.attach(session, enabled: false)
        activeGame = nil
        DuoOrientation.setPSPGameplay(false)
        playStartedAt = nil
        isExiting = false
    }
}

private struct GameSettingsView: View {
    @ObservedObject var library: GameLibraryStore
    @EnvironmentObject private var proEntitlement: DuoProEntitlement
    @Binding var scrollCueEnabled: Bool
    @Binding var renderMode: DuoRenderMode
    @AppStorage("pspRenderMode") private var pspRenderMode = DuoRenderMode.hd
    @AppStorage("pspFrameRateMode") private var pspFrameRateMode = DuoPSPFrameRateMode.high
    @AppStorage(HandheldCaseSettings.hideCasesKey) private var hideHandheldCases = false
    let replayGuide: () -> Void
    let dismiss: () -> Void

    var body: some View {
        List {
            Section(String(localized: "界面")) {
                Toggle(String(localized: "操作指引"), isOn: $scrollCueEnabled)
                    .accessibilityHint(String(localized: "显示或隐藏卡带下方的下滑箭头提示"))
                Button(String(localized: "重新体验互动操作指南"), action: replayGuide)
            }
            Section(String(localized: "游戏画质")) {
                Text(String(localized: "DS"))
                    .font(.subheadline.weight(.semibold))
                Picker(String(localized: "DS 画面模式"), selection: $renderMode) {
                    ForEach(DuoRenderMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(renderMode == .hd ? String(localized: "默认使用 512×384 内部高清渲染，兼顾稳定帧率与功耗。") : String(localized: "使用原始 256×192 分辨率，功耗最低。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "PSP"))
                    .font(.subheadline.weight(.semibold))
                Picker(String(localized: "PSP 画面模式"), selection: $pspRenderMode) {
                    ForEach(DuoRenderMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                Text(pspRenderMode == .hd ? String(localized: "2 倍高清（960×544），平滑纹理与锯齿。高负载时减少抗锯齿以优先保持流畅。重新启动游戏后生效。") : String(localized: "原生分辨率（480×272），保留原版纹理，降低功耗。重新启动游戏后生效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "PSP 帧率")) {
                Picker(String(localized: "PSP 帧率模式"), selection: $pspFrameRateMode) {
                    ForEach(DuoPSPFrameRateMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                Text(pspFrameRateMode == .high
                     ? String(localized: "默认开启。自动尝试提升可变帧率游戏，能稳定接近 60 帧时保留；锁帧、性能不足或发热时恢复原版。不会加速游戏。")
                     : String(localized: "保留游戏原来的帧率与运行设置。原本支持 60 帧的游戏仍可运行在 60 帧。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "下次启动游戏生效。部分锁帧游戏需要专用补丁，暂不自动启用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "游戏库")) {
                Toggle(String(localized: "不显示卡带盒"), isOn: $hideHandheldCases)
                Text(String(localized: "开启后，游戏库直接显示卡带、UMD 或 PS2 光盘，不再显示卡带盒。PS2 存档可在“存档管理”中查看和删除。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    CartridgeManagementView(library: library)
                } label: {
                    Label {
                        Text(String(localized: "游戏卡带管理"))
                    } icon: {
                        CartridgeManagementIcon()
                    }
                }
                NavigationLink {
                    SaveManagementView(library: library)
                } label: {
                    Label(String(localized: "存档管理"), systemImage: "externaldrive.badge.timemachine")
                }
            }
            Section(String(localized: "问题反馈")) {
                Link(destination: URL(string: "mailto:support@spare.cool")!) {
                    Label("support@spare.cool", systemImage: "envelope")
                }
                .accessibilityHint(String(localized: "打开邮件应用，向 Duo 支持团队反馈问题"))
            }
            Section(String(localized: "Duo 进阶版")) {
                NavigationLink {
                    if proEntitlement.isUnlocked {
                        DuoProSettingsView(library: library)
                    } else {
                        DuoPaywallView()
                    }
                } label: {
                    Label(proEntitlement.isUnlocked ? String(localized: "进阶功能") : String(localized: "永久解锁"), systemImage: "sparkles")
                }
                if proEntitlement.isUnlocked {
                    Label(String(localized: "已永久解锁"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(String(localized: "设置"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成"), action: dismiss) } }
    }
}

private struct CartridgeManagementIcon: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                CartridgeIconShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(lineWidth: 1.25)
                    .frame(width: 12, height: 9)
                    .offset(y: 1.5)
            }
            .frame(width: 24, height: 24)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .overlay {
                    Capsule()
                        .fill(.white)
                        .frame(width: 5, height: 1.25)
                }
                .offset(x: -2, y: 2)
        }
        .frame(width: 26, height: 24)
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
    }
}

private struct CartridgeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.minY + 4.5))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4.5))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 4))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + 6, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 6))
        path.addLine(to: CGPoint(x: rect.minX + 2, y: rect.minY + 4))
        path.closeSubpath()
        return path
    }
}

private struct CartridgeManagementView: View {
    @ObservedObject var library: GameLibraryStore
    @State private var gameToDelete: GameLibraryItem?
    @State private var gameToEdit: GameLibraryItem?
    @State private var errorMessage: String?

    private var removableGames: [GameLibraryItem] {
        library.games.filter(\.canBeDeleted)
    }

    var body: some View {
        List {
            if removableGames.isEmpty {
                ContentUnavailableView(
                    String(localized: "没有可删除的卡带"),
                    systemImage: "rectangle.stack",
                    description: Text(String(localized: "通过游戏库右上角的＋导入卡带后，可在这里删除。"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(removableGames) { game in
                        HStack(spacing: 12) {
                            Group {
                                if let icon = game.icon {
                                    Image(uiImage: icon)
                                        .resizable()
                                        .interpolation(.none)
                                        .scaledToFit()
                                } else {
                                    Image(systemName: "rectangle.portrait.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.title).lineLimit(1)
                                Text(game.isBundledTest ? String(localized: "内置游戏卡带") : game.isInstalledTitle ? String(localized: "已安装的 3DS 游戏") : game.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button { gameToEdit = game } label: {
                                Image(systemName: "pencil").frame(width: 36, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "编辑 \(game.title) 外观"))
                            Button(role: .destructive) { gameToDelete = game } label: {
                                Image(systemName: "trash")
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "删除 \(game.title) 游戏卡带"))
                            .accessibilityHint(String(localized: "删除游戏文件并保留存档"))
                        }
                    }
                } footer: {
                    Text(String(localized: "删除卡带会移除游戏本体并保留存档；内置游戏会从游戏库移除。"))
                }
            }
            if library.hasHiddenBundledGames {
                Section {
                    Button(String(localized: "恢复内置卡带"), systemImage: "arrow.counterclockwise") {
                        library.restoreBundledGames()
                    }
                }
            }
        }
        .navigationTitle(String(localized: "游戏卡带管理"))
        .sheet(item: $gameToEdit) { game in
            NavigationStack { CartridgeAppearanceEditor(game: game, library: library) }
        }
        .alert(item: $gameToDelete) { game in
            Alert(
                title: Text(String(localized: "删除“\(game.title)”？")),
                message: Text(String(localized: "游戏卡带会从本机移除，存档会保留。")),
                primaryButton: .destructive(Text(String(localized: "删除卡带"))) {
                    do { try library.deleteGame(game) }
                    catch { errorMessage = error.localizedDescription }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(String(localized: "删除失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button(String(localized: "好"), role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }
}

private struct CartridgeAppearanceEditor: View {
    let game: GameLibraryItem
    @ObservedObject var library: GameLibraryStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var entitlement: DuoProEntitlement
    @State private var engraving = ""
    @State private var shellColor: CartridgeShellColor?
    @State private var cover: UIImage?
    @State private var coverChanged = false
    @State private var restoreOriginalCover = false
    @State private var photo: PhotosPickerItem?
    @State private var importingFile = false
    @State private var showingPaywall = false
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var loadingPhoto = false
    @State private var previewRevision = UUID()
    @State private var previewScene: SCNScene?

    private var isUMD: Bool { game.cartridgeKind == .umd }

    var body: some View {
        Form {
            Section {
                CartridgeAppearancePreview(scene: previewScene)
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.black)
                    .accessibilityLabel(String(localized: "外观预览，可拖动查看卡带"))
            }
            Section(String(localized: "封面")) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(String(localized: "从照片选择"), systemImage: "photo")
                }
                Button(String(localized: "从文件选择"), systemImage: "folder") { importingFile = true }
                Button(String(localized: "恢复原始封面"), systemImage: "arrow.counterclockwise") {
                    cover = library.originalCover(for: game)
                    restoreOriginalCover = true
                    coverChanged = true
                    previewRevision = UUID()
                }
                if loadingPhoto { ProgressView(String(localized: "正在读取图片…")) }
                if isUMD {
                    Text(String(localized: "保留封面主体，空白部分渐变为图片主色。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !isUMD {
                Section(String(localized: "镌刻文字")) {
                    TextField(String(localized: "留空使用游戏名称"), text: $engraving, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: engraving) { _, text in
                            if text.count > 80 { engraving = String(text.prefix(80)) }
                            previewRevision = UUID()
                        }
                    Text(String(localized: "沿用卡带镌刻字体，只修改卡带上的文字。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(String(localized: "卡带颜色")) {
                    Picker(String(localized: "外壳"), selection: $shellColor) {
                        Text(String(localized: "原始颜色")).tag(CartridgeShellColor?.none)
                        ForEach(CartridgeShellColor.allCases) { color in
                            Label {
                                Text(color.title)
                            } icon: {
                                Circle().fill(Color(uiColor: color.uiColor)).frame(width: 14, height: 14)
                            }.tag(Optional(color))
                        }
                    }
                    .onChange(of: shellColor) { _, _ in previewRevision = UUID() }
                    Text(String(localized: "提供 DS 深灰、红外卡带黑和 3DS 浅灰白。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(isUMD ? String(localized: "编辑 UMD 封面") : String(localized: "编辑卡带外观"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "保存")) {
                    if entitlement.isUnlocked { save() } else { showingPaywall = true }
                }.disabled(loadingPhoto)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let preferences = DuoProStore.shared.preferences(for: game.url)
            engraving = preferences.cartridgeEngraving ?? ""
            shellColor = preferences.cartridgeColor
            cover = game.icon
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-appearance-preview-custom") {
                engraving = String(localized: "我的收藏")
                shellColor = .threeDSWhite
            }
            #endif
            previewRevision = UUID()
        }
        .task(id: previewRevision) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            let text = engraving.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = GameLibraryItem(url: game.url, title: game.title, detail: game.detail,
                platform: game.platform, cartridgeKind: game.cartridgeKind, icon: cover,
                isBundledTest: game.isBundledTest, programID: game.programID, productID: game.productID,
                engraving: text.isEmpty ? nil : text, shellColor: shellColor)
            previewScene = CartridgeSceneFactory.mediumScene(for: item)
        }
        .task(id: photo) {
            guard let photo else { return }
            loadingPhoto = true
            defer { loadingPhoto = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data)
                else { throw ROMFiles.Failure(message: String(localized: "无法读取这张图片")) }
                guard !Task.isCancelled else { return }
                useCover(image)
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let image = UIImage(contentsOfFile: url.path) else { throw ROMFiles.Failure(message: String(localized: "请选择有效的图片文件")) }
                useCover(image)
            } catch {
                if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showingPaywall) { NavigationStack { DuoPaywallView() } }
        .alert(String(localized: "无法保存外观"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好"), role: .cancel) { }
        } message: { Text(errorMessage ?? "") }
    }

    private func useCover(_ image: UIImage) {
        cover = image
        coverChanged = true
        restoreOriginalCover = false
        previewRevision = UUID()
    }

    private func save() {
        do {
            let text = engraving.trimmingCharacters(in: .whitespacesAndNewlines)
            try DuoProStore.shared.saveCartridgeAppearance(for: game.url,
                cover: restoreOriginalCover ? nil : cover, replaceCover: coverChanged,
                engraving: isUMD || text.isEmpty ? nil : text, color: isUMD ? nil : shellColor)
            library.reload()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private final class CartridgePreviewSceneView: SCNView {
    override func layoutSubviews() {
        super.layoutSubviews()
        fitPreview()
    }

    func fitPreview() {
        guard bounds.width > 0, bounds.height > 0,
              let model = scene?.rootNode.childNode(withName: "cartridgeModel", recursively: true),
              let camera = pointOfView?.camera else { return }
        let box = model.boundingBox
        let width = CGFloat(box.max.x - box.min.x)
        let height = CGFloat(box.max.y - box.min.y)
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(max(height, width / (bounds.width / bounds.height)) * 0.57)
    }
}

private struct CartridgeAppearancePreview: UIViewRepresentable {
    let scene: SCNScene?
    func makeUIView(context: Context) -> CartridgePreviewSceneView {
        let view = CartridgePreviewSceneView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        return view
    }
    func updateUIView(_ view: CartridgePreviewSceneView, context: Context) {
        guard view.scene !== scene else { return }
        view.scene = scene
        view.pointOfView = scene?.rootNode.childNodes.first { $0.camera != nil }
        if scene?.rootNode.childNode(withName: "umdExactMouldedShell", recursively: true) != nil {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .ambient
            light.light?.intensity = 700
            scene?.rootNode.addChildNode(light)
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.position = SCNVector3(-25, 35, 80)
            key.look(at: SCNVector3Zero)
            scene?.rootNode.addChildNode(key)
        }
        view.fitPreview()
    }
}

private struct SaveManagementView: View {
    @ObservedObject var library: GameLibraryStore
    @State private var saveToDelete: GameSaveInfo?
    @State private var refreshID = UUID()
    @State private var errorMessage: String?

    private var saves: [GameSaveInfo] { library.managedSaveInfos() }

    var body: some View {
        List(saves) { save in
            let game = save.game
            HStack(spacing: 12) {
                Group {
                    if let icon = game.icon {
                        Image(uiImage: icon).resizable().interpolation(.none).scaledToFit()
                    } else {
                        Image(systemName: "gamecontroller")
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title).lineLimit(1)
                    Text(save.exists ? saveSummary(save) : String(localized: "尚未检测到存档"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if save.exists {
                    Button(role: .destructive) { saveToDelete = save } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "删除 \(game.title) 的存档"))
                }
            }
        }
        .id(refreshID)
        .navigationTitle(String(localized: "存档管理"))
        .alert(item: $saveToDelete) { save in
            Alert(
                title: Text(String(localized: "删除“\(save.game.title)”的存档？")),
                message: Text(String(localized: "此操作无法撤销，游戏卡带不会被删除。")),
                primaryButton: .destructive(Text(String(localized: "删除存档"))) {
                    do {
                        try library.deleteSave(save)
                        refreshID = UUID()
                    } catch { errorMessage = error.localizedDescription }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(String(localized: "删除失败"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button(String(localized: "好"), role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }

    private func saveSummary(_ save: GameSaveInfo) -> String {
        let size = ByteCountFormatter.string(fromByteCount: save.byteCount, countStyle: .file)
        guard let date = save.modifiedAt else { return size }
        return "\(size) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Isolated, full-screen practice: never owns an EmulatorSession, ROM or library store.
private struct CartridgeTutorialView: View {
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Step { case add, chooseFiles, select, insert, opening, power, returning, pspInsert, pspOpening, pspControls, pspPower, done }
    @State private var step = Step.add
    @State private var selectedID: String?
    @State private var added: Set<Int> = []
    @State private var exiting = false
    @State private var practicedPSPButton = false
    @State private var practicedPSPStick = false
    @StateObject private var pspPracticeModel = PSP2000RuntimeModel()
    private let accent = Color(red: 1, green: 0.72, blue: 0.34)

    private var progress: Int {
        switch step {
        case .add, .chooseFiles: return 0
        case .select: return 1
        case .insert, .opening, .power, .returning: return 2
        case .pspInsert, .pspOpening: return 3
        case .pspControls: return 4
        case .pspPower: return 5
        case .done: return 6
        }
    }

    private static let examples: [GameLibraryItem] = [
        GameLibraryItem(url: URL(string: "duo-tutorial://cards/example-ds.nds")!,
                        title: "Nintendo DS", detail: "",
                        platform: .nds, cartridgeKind: .ndsStandard,
                        icon: UIImage(systemName: "rectangle.split.2x1"), isBundledTest: false,
                        programID: nil, productID: nil),
        GameLibraryItem(url: URL(string: "duo-tutorial://cards/example-3ds.3dsx")!,
                        title: "Nintendo 3DS", detail: "",
                        platform: .threeDS, cartridgeKind: .threeDS,
                        icon: UIImage(systemName: "square.stack.3d.up"), isBundledTest: false,
                        programID: nil, productID: nil)
    ]
    private var examples: [GameLibraryItem] {
        progress >= 3 ? [Self.pspExample] : Self.examples
    }
    private static let pspExample = GameLibraryItem(
        url: URL(string: "duo-tutorial://discs/example-psp.iso")!, title: String(localized: "PSP 操作练习"), detail: "",
        platform: .psp, cartridgeKind: .umd, icon: nil, isBundledTest: false, programID: nil, productID: nil)
    private var instruction: String {
        switch step {
        case .add, .chooseFiles: return String(localized: "添加游戏")
        case .select: return String(localized: "左右选卡")
        case .insert: return String(localized: "下拉开玩")
        case .opening: return String(localized: "打开主机")
        case .power: return String(localized: "轻点退出")
        case .returning: return String(localized: "回到收藏")
        case .pspInsert: return String(localized: "下拉装入 UMD")
        case .pspOpening: return String(localized: "合仓开玩")
        case .pspControls: return String(localized: "按动实体按键")
        case .pspPower: return String(localized: "上推两秒退出")
        case .done: return String(localized: "准备开玩")
        }
    }

    private var supportingText: String {
        switch step {
        case .add: return String(localized: "点击右上角 ＋，选择游戏文件。")
        case .chooseFiles: return String(localized: "点选两份文件，加入收藏。")
        case .select: return String(localized: "按住卡带左右滑动，换到另一张。")
        case .insert: return String(localized: "按住中间卡带，向下拖入卡槽。")
        case .opening: return String(localized: "插卡完成，等待主机展开。")
        case .power: return String(localized: "点击右下角电源键，合盖退卡。")
        case .returning: return String(localized: "退卡后，回到收藏架。")
        case .pspInsert: return String(localized: "PSP 游戏显示为 UMD。向下拖动，光盘上下翻转，装入倾斜主机的碟仓。")
        case .pspOpening: return String(localized: "碟仓合上后，用机身上的按钮和摇杆操作。")
        case .pspControls: return String(localized: "试按方向键或 △ ○ × □，再拖动左侧摇杆。SELECT、START、L、R 都在原机位置；HOME 暂停或继续。")
        case .pspPower: return String(localized: "把右侧实体推钮从 HOLD 向 POWER 推到顶，保持 2 秒退出。提前松手会回弹并取消关机。")
        case .done: return String(localized: "支持以下机型和游戏文件。")
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if step != .pspControls && step != .pspPower {
              DragCartridgeSceneView(
                games: examples, selectedID: selectedID, isExiting: exiting,
                onSelect: { id in
                    if step == .select, selectedID != nil, selectedID != id { step = .insert }
                    selectedID = id
                },
                onInserted: { _ in
                    if step == .insert { step = .opening }
                    if step == .pspInsert { step = .pspOpening }
                },
                onFinished: {
                    if step == .pspOpening { step = .pspControls; return }
                    guard step == .opening else { return }
                    step = .power
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-tutorial-test") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            powerOff()
                        }
                    }
                    #endif
                },
                onReturned: {
                    guard step == .returning else { return }
                    exiting = false
                    selectedID = Self.pspExample.id
                    step = .pspInsert
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-tutorial-test") {
                        print("TUTORIAL_PASS: two metadata-only cards, select, insert, same-scene power exit")
                        fflush(stdout)
                    }
                    #endif
                },
                onImport: { if step == .add { step = .chooseFiles } },
                onStageActivityChanged: { _ in },
                allowsSelection: step == .select || step == .insert,
                allowsInsertion: step == .insert || step == .pspInsert
            )
            .id(progress >= 3)
            .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.split.2x1")
                        Text("DUO").tracking(4)
                    }.font(.system(size: 17, weight: .bold))
                    Spacer()
                    Text(String(format: "%02d / 07", progress + 1))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    if step == .add {
                        Button { step = .chooseFiles; CartridgeFeedback.shared.playSelection(speed: 0.35) } label: {
                            Image(systemName: "plus").font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.white).frame(width: 48, height: 48)
                                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent, lineWidth: 1.5))
                        }
                        .accessibilityLabel(String(localized: "导入游戏"))
                        .overlay(alignment: .bottomTrailing) {
                            TutorialImportArrow()
                                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                                .frame(width: 95, height: 57)
                            .frame(width: 95, height: 57).offset(x: -12, y: 63)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                }.frame(height: 48)
                HStack(spacing: 5) {
                    ForEach(0..<7) { index in
                        Capsule().fill(index <= progress ? accent : Color.white.opacity(0.16))
                            .frame(height: 3)
                    }
                }
                .padding(.trailing, step == .add ? 112 : 0)
                .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 12) {
                    Text([String(localized: "导入收藏"), String(localized: "浏览卡带"), String(localized: "开始与结束"), String(localized: "PSP · 装入光盘"), String(localized: "PSP · 实体操作"), String(localized: "PSP · 电源推钮"), String(localized: "支持与兼容")][progress])
                        .font(.system(size: 11, weight: .semibold)).tracking(2).foregroundStyle(accent)
                    Text(instruction)
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .italic().tracking(1.5)
                        .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .minimumScaleFactor(0.8).lineLimit(2)
                    Text(supportingText)
                        .font(.system(size: 20, weight: .medium)).lineSpacing(5)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                if step == .pspControls || step == .pspPower {
                    PSP2000SceneView(model: pspPracticeModel, image: nil, session: nil, controlsLocked: false,
                        onExit: {
                            if step == .pspPower { step = .done }
                        }, onControl: { name in
                            if name == "ANALOG_STICK" { practicedPSPStick = true }
                            if name.hasPrefix("BUTTON_DPAD_") || ["BUTTON_CROSS", "BUTTON_CIRCLE", "BUTTON_TRIANGLE", "BUTTON_SQUARE"].contains(name) {
                                practicedPSPButton = true
                            }
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { pspPracticeModel.setIndicators(running: true, hold: false, memory: false) }
                    if step == .pspControls {
                        HStack {
                            Label(String(localized: "实体按键"), systemImage: practicedPSPButton ? "checkmark.circle.fill" : "circle")
                            Spacer()
                            Label(String(localized: "摇杆"), systemImage: practicedPSPStick ? "checkmark.circle.fill" : "circle")
                        }.foregroundStyle(accent)
                        Button(String(localized: "练习关机推钮")) { step = .pspPower }
                            .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                            .disabled(!practicedPSPButton || !practicedPSPStick)
                    }
                } else {
                    Spacer(minLength: 20)
                }

                if step == .chooseFiles {
                    VStack(spacing: 10) {
                        ForEach(0..<2) { index in
                            Button { addExample(index); CartridgeFeedback.shared.playSelection(speed: 0.35) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "doc").font(.title2).foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(index == 0 ? "Nintendo DS.nds" : "Nintendo 3DS.3dsx")
                                            .font(.system(size: 18, weight: .semibold))
                                        Text(index == 0 ? "Nintendo DS" : "Nintendo 3DS")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: added.contains(index) ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.title2).foregroundStyle(accent)
                                }
                                .padding(18)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.13), lineWidth: 1))
                            }
                            .disabled(added.contains(index))
                        }
                    }
                }
                if step == .select || step == .insert {
                    HStack(spacing: 14) {
                        Image(systemName: step == .select ? "arrow.left.and.right" : "arrow.down")
                            .font(.system(size: 23, weight: .medium)).foregroundStyle(accent)
                            .frame(width: 42)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(step == .select ? String(localized: "左右滑动") : String(localized: "向下拖动"))
                                .font(.system(size: 20, weight: .semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
                }
                if step == .done {
                    VStack(alignment: .leading, spacing: 16) {
                        compatibilityRow("Nintendo DS", models: "DS · DS Lite", formats: ".nds")
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                        compatibilityRow("Nintendo 3DS", models: "3DS · 3DS XL · 2DS", formats: ".3ds  .3dsx  .cci  .cxi")
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                        compatibilityRow("Sony PSP", models: "PSP-2000 · UMD", formats: ".iso  .cso  .chd  .pbp")
                        Text(String(localized: "支持 DS、3DS、N64 与 PSP 游戏；ZIP、7Z、RAR、TAR 自动展开。PSP 游戏存档自动保存；CIA/CIAx/ZCIA 安装后启动，更新和 DLC 需要对应本体。"))
                            .font(.system(size: 14)).lineSpacing(3).foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(20)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    Button(action: onComplete) {
                        HStack {
                            Text(String(localized: "进入游戏库"))
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.black).padding(20)
                        .background(accent, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
            .foregroundStyle(.white)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.88), value: step)

            if step == .power {
                GeometryReader { proxy in
                    let width = min(proxy.size.width * 1.08, proxy.size.height * 0.827)
                    let height = width * 2500 / 2200
                    Button(action: powerOff) {
                        RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.8), lineWidth: 2)
                            .background(Color.clear).contentShape(Rectangle())
                    }
                    .frame(width: width * 0.15, height: height * 0.09)
                    .position(x: proxy.size.width / 2 + width * 0.365,
                              y: proxy.size.height / 2 + height * 0.405)
                    .accessibilityLabel(String(localized: "电源，合盖并退出卡带"))
                }
            }
        }
        .onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-psp-tutorial-preview") { step = .pspControls }
            if arguments.contains("-psp-power-tutorial-preview") { step = .pspPower }
            if ProcessInfo.processInfo.arguments.contains("-tutorial-test") {
                // Drive the same add handlers; the scene then tests the real selection/insertion callbacks.
                step = .chooseFiles
                addExample(0)
                addExample(1)
            }
            #endif
        }
    }

    private func compatibilityRow(_ title: String, models: String, formats: String) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(models).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formats).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(accent)
        }
    }

    private func addExample(_ index: Int) {
        guard step == .chooseFiles, (0..<2).contains(index) else { return }
        added.insert(index)
        selectedID = examples.first?.id
        if added.count == 2 { step = .select }
    }
    private func powerOff() {
        guard step == .power else { return }
        step = .returning
        exiting = true
    }
}

private struct TutorialImportArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tip = CGPoint(x: rect.width * 0.86, y: 3)
        path.move(to: CGPoint(x: 4, y: rect.height - 4))
        path.addCurve(to: tip,
                      control1: CGPoint(x: rect.width * 0.7, y: rect.height),
                      control2: CGPoint(x: rect.width * 0.92, y: rect.height * 0.55))
        path.move(to: CGPoint(x: tip.x - 11, y: tip.y + 12))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + 9, y: tip.y + 14))
        return path
    }
}

private struct EmulatorView: View {
    @ObservedObject var session: EmulatorSession
    let game: GameLibraryItem
    let isExiting: Bool
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if game.platform == .ps2 {
                PS2GameView(session: nil, game: game, title: game.title, cover: game.icon?.cgImage, onExitRequested: onExit)
            } else if session.isPSP {
                PSPGameView(session: session, onExit: onExit)
            } else if session.isN64 {
                N64GameView(session: session, onExit: onExit)
            } else if let topImage = session.topImage, let bottomImage = session.bottomImage {
                if session.runtimeConfiguration.isPro && session.runtimeConfiguration.preferences.layout != .console {
                    DuoFlexibleGameLayout(topImage: topImage, bottomImage: bottomImage, session: session)
                        .ignoresSafeArea()
                } else {
                    OpenPortraitGameLayout(topImage: topImage, bottomImage: bottomImage, session: session, onExit: onExit)
                        .ignoresSafeArea()
                }
            } else {
                ProgressView(String(localized: "正在启动模拟器…"))
            }
            if session.runtimeConfiguration.isPro && game.platform != .ps2 {
                DuoProGameOverlay(session: session, game: game, onExit: onExit)
            }
            if session.isPaused && !isExiting {
                VStack(spacing: 10) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 28, weight: .semibold))
                    Text(String(localized: "已暂停"))
                        .font(.headline)
                    Text(String(localized: "按 HOME 继续"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.16)))
                .allowsHitTesting(false)
            }
        }
        .alert("Duo", isPresented: Binding(get: { session.proMessage != nil }, set: { if !$0 { session.proMessage = nil } })) {
            Button(String(localized: "好")) { session.proMessage = nil }
        } message: { Text(session.proMessage ?? "") }
    }
}

private struct OpenPortraitGameLayout: View {
    let topImage: CGImage
    let bottomImage: CGImage
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Rendered3DSXLConsoleView(topImage: topImage, bottomImage: bottomImage, session: session, onExit: onExit)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct Rendered3DSXLConsoleView: View {
    let topImage: CGImage
    let bottomImage: CGImage
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void

    private static let shellImage: UIImage = {
        let url = Bundle.main.url(forResource: "Nintendo-3DS-XL-180deg", withExtension: "png")!
        return UIImage(contentsOfFile: url.path)!
    }()

    var body: some View {
        GeometryReader { proxy in
            let modelWidth = min(proxy.size.width * 1.08, proxy.size.height * 0.827)
            let modelHeight = modelWidth * (2500.0 / 2200.0)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.035, green: 0.04, blue: 0.045), Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                Image(uiImage: Self.shellImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: modelWidth, height: modelHeight)
                    .position(center)

                ModelScreenOverlay(image: topImage, isTouchEnabled: false, session: session)
                    .frame(width: modelWidth * 0.648, height: modelHeight * 0.342)
                    .position(
                        x: center.x + modelWidth * 0.003,
                        y: center.y - modelHeight * 0.216
                    )

                ModelScreenOverlay(image: bottomImage, isTouchEnabled: true, session: session)
                    .frame(width: modelWidth * 0.514, height: modelHeight * 0.342)
                    .position(
                        x: center.x + modelWidth * 0.001,
                        y: center.y + modelHeight * 0.200
                    )
                    .zIndex(1)

                ModelControlOverlay(session: session, onExit: onExit)
                    .frame(width: modelWidth, height: modelHeight)
                    .position(center)
                    // The bottom screen has an explicit z-index because it
                    // must receive stylus input. Keep the physical controls
                    // above that layer so ABXY taps are not intercepted by
                    // the screen's transparent touch surface.
                    .zIndex(2)
            }
            .clipped()
        }
    }
}

private struct ModelScreenOverlay: View {
    let image: CGImage
    let isTouchEnabled: Bool
    @ObservedObject var session: EmulatorSession

    var body: some View {
        GeometryReader { proxy in
            let screen = ZStack {
                Color.black
                Image(image, scale: 1, orientation: .up, label: Text("Nintendo DS screen"))
                    .resizable()
                    .interpolation(.high)
                    .saturation(session.runtimeConfiguration.preferences.videoPreset == .vivid ? 1.28 : 1)
                    .contrast(session.runtimeConfiguration.preferences.videoPreset == .sharp ? 1.16 : 1)
                    .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())

            if isTouchEnabled {
                screen.overlay(StylusTouchSurface(aspect: CGFloat(image.width) / CGFloat(image.height),
                                                 onMove: { session.touch(at: $0, in: CGSize(width: 1, height: 1)) },
                                                 onRelease: { session.releaseTouch() }))
            } else {
                screen
            }
        }
    }
}

private struct StylusTouchSurface: UIViewRepresentable {
    let aspect: CGFloat
    let onMove: (CGPoint) -> Void
    let onRelease: () -> Void
    func makeUIView(context: Context) -> StylusView { StylusView() }
    func updateUIView(_ view: StylusView, context: Context) {
        view.aspect = aspect
        view.onMove = onMove
        view.onRelease = onRelease
    }
    static func dismantleUIView(_ view: StylusView, coordinator: ()) { view.cancelContact() }

    final class StylusView: UIView {
        var aspect: CGFloat = 4 / 3
        var onMove: ((CGPoint) -> Void)?
        var onRelease: (() -> Void)?
        private var contact: UITouch?
        private var pressed = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            NotificationCenter.default.addObserver(self, selector: #selector(cancelContact),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }
        static func position(_ point: CGPoint, size: CGSize, aspect: CGFloat) -> CGPoint? {
            guard size.width > 0, size.height > 0, aspect > 0 else { return nil }
            let width = min(size.width, size.height * aspect)
            let height = width / aspect
            let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
            guard point.x >= rect.minX, point.x <= rect.maxX,
                  point.y >= rect.minY, point.y <= rect.maxY else { return nil }
            return CGPoint(x: (point.x - rect.minX) / width, y: (point.y - rect.minY) / height)
        }
        private func move(_ touch: UITouch) {
            if let point = Self.position(touch.location(in: self), size: bounds.size, aspect: aspect) {
                pressed = true
                onMove?(point)
            } else if pressed {
                pressed = false
                onRelease?()
            }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard contact == nil, let touch = touches.first,
                  Self.position(touch.location(in: self), size: bounds.size, aspect: aspect) != nil else { return }
            contact = touch
            move(touch)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let contact, touches.contains(contact) else { return }
            move(contact)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let contact, touches.contains(contact) { cancelContact() }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let contact, touches.contains(contact) { cancelContact() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelContact() }
        }
        @objc func cancelContact() {
            if pressed { onRelease?() }
            pressed = false
            contact = nil
        }
    }
}

private struct ModelControlOverlay: View {
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                ModelCirclePad(session: session)
                    .frame(width: width * 0.210, height: height * 0.160)
                    .position(x: width * 0.120, y: height * 0.600)

                ModelDPad(session: session)
                    .frame(width: width * 0.210, height: height * 0.165)
                    .position(x: width * 0.120, y: height * 0.7575)

                ModelFaceButtonCluster(session: session)
                    .frame(width: width * 0.200, height: height * 0.160)
                    .position(x: width * 0.885, y: height * 0.645)

                ModelMenuButtonCluster(session: session)
                    .frame(width: width * 0.670, height: height * 0.090)
                    .position(x: width * 0.500, y: height * 0.920)

                ModelPowerButton(onExit: onExit)
                    .frame(width: width * 0.150, height: height * 0.090)
                    .position(x: width * 0.865, y: height * 0.905)

                ModelPressTarget(onPress: { session.press(.l) }, onRelease: { session.release(.l) })
                    .frame(width: width * 0.14, height: height * 0.05)
                    .position(x: width * 0.10, y: height * 0.345)

                ModelPressTarget(onPress: { session.press(.r) }, onRelease: { session.release(.r) })
                    .frame(width: width * 0.14, height: height * 0.05)
                    .position(x: width * 0.90, y: height * 0.345)
            }
            .opacity(session.runtimeConfiguration.isPro ? session.runtimeConfiguration.preferences.controlOpacity : 1)
            .scaleEffect(session.runtimeConfiguration.isPro ? session.runtimeConfiguration.preferences.controlScale : 1)
        }
    }
}

private enum ModelControlAssets {
    static let names = [
        "circle_base", "circle_cap",
        "dpad_up", "dpad_down", "dpad_left", "dpad_right",
        "face_x", "face_y", "face_a", "face_b",
        "menu_select_1", "menu_select_2", "menu_select_3", "menu_select_4",
        "menu_home_1", "menu_home_2", "menu_home_3", "menu_home_4",
        "menu_start_1", "menu_start_2", "menu_start_3", "menu_start_4",
        "power_1", "power_2", "power_3", "power_4"
    ]

    static let images: [String: UIImage] = Dictionary(uniqueKeysWithValues: names.map { name in
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Controls")!
        return (name, UIImage(contentsOfFile: url.path)!)
    })
}

private struct ModelControlPatch: View {
    let name: String

    var body: some View {
        Image(uiImage: ModelControlAssets.images[name]!)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .clipped()
            .allowsHitTesting(false)
    }
}

private struct ModelCirclePad: View {
    @ObservedObject var session: EmulatorSession
    @GestureState private var contactActive = false
    @State private var horizontalInput: DuoInput?
    @State private var verticalInput: DuoInput?
    @State private var knobOffset = CGSize.zero
    @State private var isEngaged = false
    @State private var releaseTask: Task<Void, Never>?

    // libctru/SDL report the 3DS Circle Pad on a -156...156 axis. The
    // thresholds below are our touch calibration within that real raw range.
    private let rawMaximum: CGFloat = 156
    private let engageThreshold: CGFloat = 10
    private let releaseThreshold: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if isEngaged {
                    ModelControlPatch(name: "circle_base")
                    ModelControlPatch(name: "circle_cap")
                        .offset(knobOffset)
                }

                Ellipse()
                    .fill(.white.opacity(0.001))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Ellipse())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($contactActive) { _, active, _ in active = true }
                            .onChanged {
                                update(
                                    with: $0.location,
                                    in: proxy.size
                                )
                            }
                            .onEnded { _ in releaseAll() }
                    )
            }
        }
        .onChange(of: contactActive) { _, active in if !active { releaseAll() } }
        .onDisappear { releaseAll() }
        .onChange(of: session.isPaused) { _, paused in if paused { releaseAll() } }
    }

    private func update(with location: CGPoint, in size: CGSize) {
        releaseTask?.cancel()
        isEngaged = true

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let vector = CGSize(width: location.x - center.x, height: location.y - center.y)
        let distance = hypot(vector.width, vector.height)
        let maximumTravel = min(size.width, size.height) * 0.10
        let clampedDistance = min(distance, maximumTravel)
        let travelScale = distance > 0 ? clampedDistance / distance : 0
        knobOffset = CGSize(width: vector.width * travelScale, height: vector.height * travelScale)

        let sensitivity = session.runtimeConfiguration.isPro ? session.runtimeConfiguration.preferences.stickSensitivity : 1
        let rawX = maximumTravel > 0 ? knobOffset.width / maximumTravel * rawMaximum * sensitivity : 0
        let rawY = maximumTravel > 0 ? knobOffset.height / maximumTravel * rawMaximum * sensitivity : 0
        session.setCirclePad(
            x: Double(rawX / rawMaximum),
            y: Double(rawY / rawMaximum)
        )
        let wasIdle = horizontalInput == nil && verticalInput == nil

        let nextHorizontal = mappedInput(
            rawValue: rawX,
            current: horizontalInput,
            positive: .right,
            negative: .left
        )
        let nextVertical = mappedInput(
            rawValue: rawY,
            current: verticalInput,
            positive: .down,
            negative: .up
        )

        updateInput(&horizontalInput, to: nextHorizontal)
        updateInput(&verticalInput, to: nextVertical)

        if wasIdle && (nextHorizontal != nil || nextVertical != nil) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

    }
    private func mappedInput(
        rawValue: CGFloat,
        current: DuoInput?,
        positive: DuoInput,
        negative: DuoInput
    ) -> DuoInput? {
        let threshold = current == nil ? engageThreshold : releaseThreshold
        guard abs(rawValue) >= threshold else { return nil }
        return rawValue >= 0 ? positive : negative
    }

    private func updateInput(_ current: inout DuoInput?, to next: DuoInput?) {
        guard current?.rawValue != next?.rawValue else { return }
        if let current { session.release(current) }
        if let next { session.press(next) }
        current = next
    }

    private func releaseAll() {
        if let horizontalInput { session.release(horizontalInput) }
        if let verticalInput { session.release(verticalInput) }
        horizontalInput = nil
        verticalInput = nil
        session.setCirclePad(x: 0, y: 0)
        withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.88)) {
            knobOffset = .zero
        }
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, horizontalInput == nil, verticalInput == nil else { return }
            isEngaged = false
        }
    }
}

private struct ModelDPad: View {
    @ObservedObject var session: EmulatorSession
    @GestureState private var contactActive = false
    @State private var activeInput: DuoInput?
    @State private var patchName: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let patchName {
                    ModelControlPatch(name: patchName)
                        .transition(.opacity)
                }

                Rectangle()
                    .fill(.white.opacity(0.001))
                    .frame(width: proxy.size.width * 0.72, height: proxy.size.height * 0.88)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($contactActive) { _, active, _ in active = true }
                            .onChanged {
                                update(
                                    with: $0.location,
                                    in: CGSize(width: proxy.size.width * 0.72, height: proxy.size.height * 0.88)
                                )
                            }
                            .onEnded { _ in release() }
                    )
            }
        }
        .onChange(of: contactActive) { _, active in if !active { release() } }
        .onDisappear { release() }
        .onChange(of: session.isPaused) { _, paused in if paused { release() } }
    }

    private func update(with location: CGPoint, in size: CGSize) {
        let dx = location.x - size.width / 2
        let dy = location.y - size.height / 2
        let next: DuoInput
        let nextPatch: String

        if abs(dx) > abs(dy) {
            next = dx > 0 ? .right : .left
            nextPatch = dx > 0 ? "dpad_right" : "dpad_left"
        } else {
            next = dy > 0 ? .down : .up
            nextPatch = dy > 0 ? "dpad_down" : "dpad_up"
        }

        guard activeInput?.rawValue != next.rawValue else { return }
        if let activeInput { session.release(activeInput) }
        session.press(next)
        if activeInput == nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        activeInput = next
        withAnimation(.easeOut(duration: 0.045)) { patchName = nextPatch }
    }

    private func release() {
        if let activeInput { session.release(activeInput) }
        activeInput = nil
        withAnimation(.easeOut(duration: 0.065)) { patchName = nil }
    }
}

private struct ModelFaceButtonCluster: View {
    @ObservedObject var session: EmulatorSession
    @State private var activeInput: DuoInput?
    @State private var patchName: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let patchName {
                    ModelControlPatch(name: patchName)
                        .transition(.opacity)
                }

                // One stable hit surface avoids SwiftUI's coordinate-space
                // ambiguity when several positioned transparent circles are
                // layered in a small GeometryReader.
                Rectangle()
                    .fill(.white.opacity(0.002))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let key = nearestKey(to: value.location, in: proxy.size)
                                press(key)
                            }
                            .onEnded { _ in releaseActiveButton() }
                    )
            }
        }
        .onDisappear { releaseActiveButton() }
        .onChange(of: session.isPaused) { _, paused in if paused { releaseActiveButton() } }
    }

    private func press(_ key: FaceKey) {
        guard activeInput?.rawValue != key.input.rawValue else { return }

        if let activeInput { session.releaseMomentary(activeInput) }
        session.pressMomentary(key.input)
        activeInput = key.input
        withAnimation(.easeOut(duration: 0.035)) { patchName = key.patchName }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func nearestKey(to location: CGPoint, in size: CGSize) -> FaceKey {
        FaceKey.allCases.min { lhs, rhs in
            let lp = CGPoint(x: size.width * lhs.center.x, y: size.height * lhs.center.y)
            let rp = CGPoint(x: size.width * rhs.center.x, y: size.height * rhs.center.y)
            return hypot(location.x - lp.x, location.y - lp.y) < hypot(location.x - rp.x, location.y - rp.y)
        }!
    }

    private func releaseActiveButton(expected: DuoInput? = nil) {
        guard let activeInput else { return }
        guard expected == nil || expected?.rawValue == activeInput.rawValue else { return }
        session.releaseMomentary(activeInput)
        self.activeInput = nil
        withAnimation(.easeOut(duration: 0.065)) { patchName = nil }
    }

    private struct FaceKey: Hashable {
        let input: DuoInput
        let patchName: String
        let label: String
        let center: CGPoint

        static let allCases: [FaceKey] = [
            FaceKey(input: .x, patchName: "face_x", label: "X", center: CGPoint(x: 0.45, y: 0.30)),
            FaceKey(input: .y, patchName: "face_y", label: "Y", center: CGPoint(x: 0.225, y: 0.5625)),
            FaceKey(input: .a, patchName: "face_a", label: "A", center: CGPoint(x: 0.70, y: 0.5625)),
            FaceKey(input: .b, patchName: "face_b", label: "B", center: CGPoint(x: 0.45, y: 0.83125))
        ]
    }
}

private struct ModelMenuButtonCluster: View {
    @ObservedObject var session: EmulatorSession
    @State private var activeKey: MenuKey?
    @State private var displayedKey: MenuKey?
    @State private var modelFrame = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let displayedKey, modelFrame > 0 {
                    ModelControlPatch(name: displayedKey.patchName(frame: modelFrame))
                }

                ForEach(MenuKey.allCases, id: \.self) { key in
                    Rectangle()
                        .fill(.white.opacity(0.002))
                        .frame(width: proxy.size.width * 0.31, height: proxy.size.height)
                        .position(x: proxy.size.width * key.centerX, y: proxy.size.height / 2)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in press(key) }
                                .onEnded { _ in release(key) }
                        )
                        .accessibilityLabel(key.accessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .onDisappear { release() }
        .onChange(of: session.isPaused) { _, paused in if paused { release() } }
    }

    private func press(_ key: MenuKey) {
        guard activeKey == nil || activeKey == key else { return }
        guard activeKey == nil else { return }

        animationTask?.cancel()
        if displayedKey != key {
            modelFrame = 0
        }
        activeKey = key
        displayedKey = key
        modelFrame = 1

        switch key {
        case .select: session.pressMomentary(.select)
        case .home: session.togglePause()
        case .start: session.pressMomentary(.start)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        animatePress(for: key)
    }

    private func release(_ expectedKey: MenuKey? = nil) {
        guard let activeKey, expectedKey == nil || expectedKey == activeKey else { return }
        switch activeKey {
        case .select: session.releaseMomentary(.select)
        case .home: break
        case .start: session.releaseMomentary(.start)
        }
        self.activeKey = nil
        animateRelease(for: activeKey)
    }

    private func animatePress(for key: MenuKey) {
        guard modelFrame < 4 else { return }
        animationTask = Task { @MainActor in
            for frame in (modelFrame + 1)...4 {
                guard !Task.isCancelled, activeKey == key else { return }
                modelFrame = frame
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func animateRelease(for key: MenuKey) {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            for frame in stride(from: max(modelFrame, 1), through: 1, by: -1) {
                guard !Task.isCancelled, activeKey == nil, displayedKey == key else { return }
                modelFrame = frame
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, activeKey == nil else { return }
            modelFrame = 0
            displayedKey = nil
        }
    }

    private enum MenuKey: CaseIterable {
        case select
        case home
        case start

        var centerX: CGFloat {
            switch self {
            case .select: 0.224
            case .home: 0.500
            case .start: 0.776
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .select: "SELECT"
            case .home: "HOME"
            case .start: "START"
            }
        }

        func patchName(frame: Int) -> String {
            switch self {
            case .select: "menu_select_\(frame)"
            case .home: "menu_home_\(frame)"
            case .start: "menu_start_\(frame)"
            }
        }
    }
}

private struct ModelPowerButton: View {
    let onExit: () -> Void
    @State private var isPressed = false
    @State private var modelFrame = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if modelFrame > 0 {
                    ModelControlPatch(name: "power_\(modelFrame)")
                }

                Circle()
                    .fill(.white.opacity(0.001))
                    .frame(width: proxy.size.height * 0.72, height: proxy.size.height * 0.72)
                    .position(x: proxy.size.width * 0.333, y: proxy.size.height * 0.492)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in press() }
                            .onEnded { _ in release() }
                    )
            }
        }
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        animationTask?.cancel()
        onExit()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard modelFrame < 4 else { return }
        animationTask = Task { @MainActor in
            for frame in (modelFrame + 1)...4 {
                guard !Task.isCancelled, isPressed else { return }
                modelFrame = frame
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            for frame in stride(from: max(modelFrame, 1), through: 1, by: -1) {
                guard !Task.isCancelled, !isPressed else { return }
                modelFrame = frame
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, !isPressed else { return }
            modelFrame = 0
        }
    }
}

private struct ModelPressTarget: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false
    @GestureState private var contactActive = false

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($contactActive) { _, active, _ in active = true }
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
            .onChange(of: contactActive) { _, active in
                if !active, isPressed { isPressed = false; onRelease() }
            }
            .onDisappear { if isPressed { isPressed = false; onRelease() } }
    }
}

private struct ThreeDSXLConsoleView: View {
    let topImage: CGImage
    let bottomImage: CGImage
    @ObservedObject var session: EmulatorSession

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let topScreenWidth = min(width - 24, height * 0.35 * (4.0 / 3.0))
            let bottomScreenWidth = min(width * 0.54, height * 0.31 * (4.0 / 3.0))

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.19, blue: 0.21),
                        Color(red: 0.055, green: 0.06, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        ShoulderButton(label: "L", session: session, input: .l)
                        Spacer(minLength: 0)
                        ShoulderButton(label: "R", session: session, input: .r)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)

                    XLScreenPanel(image: topImage, windowAspect: 4.0 / 3.0, isTouchEnabled: false, session: session)
                        .frame(width: topScreenWidth)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.10), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 12)
                        .overlay { Capsule().fill(.mint.opacity(0.55)).frame(width: 34, height: 3) }
                        .padding(.vertical, 5)

                    ZStack {
                        XLScreenPanel(image: bottomImage, windowAspect: 4.0 / 3.0, isTouchEnabled: true, session: session)
                            .frame(width: bottomScreenWidth)
                            .offset(y: -min(height * 0.09, 92))

                        ControlDeck(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
        }
    }
}

private struct XLScreenPanel: View {
    let image: CGImage
    let windowAspect: CGFloat
    let isTouchEnabled: Bool
    @ObservedObject var session: EmulatorSession

    var body: some View {
        GeometryReader { proxy in
            if isTouchEnabled {
                screenView.overlay(StylusTouchSurface(aspect: CGFloat(image.width) / CGFloat(image.height),
                                                     onMove: { session.touch(at: $0, in: CGSize(width: 1, height: 1)) },
                                                     onRelease: { session.releaseTouch() }))
            } else {
                screenView
            }
        }
        .aspectRatio(windowAspect, contentMode: .fit)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.black).shadow(color: .black.opacity(0.8), radius: 5, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.20)))
    }

    private var screenView: some View {
        ZStack {
            Color.black
            Image(image, scale: 1, orientation: .up, label: Text("Nintendo DS screen"))
                .resizable()
                .interpolation(.high)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
    }

    private func touchGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in session.touch(at: value.location, in: size) }
            .onEnded { _ in session.releaseTouch() }
    }
}

private struct ControlDeck: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 8) {
                CirclePad(session: session)
                DirectionPad(session: session)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                ButtonPad(session: session)
                HStack(spacing: 7) {
                    MenuButton(label: "SELECT", session: session) { session.pressMomentary(.select) } onRelease: { session.releaseMomentary(.select) }
                    MenuButton(label: "HOME", session: session) { session.togglePause() } onRelease: { }
                    MenuButton(label: "START", session: session) { session.pressMomentary(.start) } onRelease: { session.releaseMomentary(.start) }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct CirclePad: View {
    @ObservedObject var session: EmulatorSession
    @State private var activeInput: DuoInput?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.white.opacity(0.26), Color.black.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().stroke(.white.opacity(0.28), lineWidth: 1)
                Circle().fill(Color(red: 0.10, green: 0.11, blue: 0.12)).padding(8)
                Circle().stroke(.black.opacity(0.8), lineWidth: 2).padding(8)
                Circle().fill(.white.opacity(0.10)).frame(width: 18, height: 18)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in updateDirection(for: value.location, in: proxy.size) }
                    .onEnded { _ in releaseDirection() }
            )
        }
        .frame(width: 82, height: 82)
        .shadow(color: .black.opacity(0.75), radius: 4, y: 3)
    }

    private func updateDirection(for point: CGPoint, in size: CGSize) {
        let vector = CGSize(width: point.x - size.width / 2, height: point.y - size.height / 2)
        let next: DuoInput?
        if max(abs(vector.width), abs(vector.height)) < 12 {
            next = nil
        } else if abs(vector.width) > abs(vector.height) {
            next = vector.width > 0 ? .right : .left
        } else {
            next = vector.height > 0 ? .down : .up
        }
        guard activeInput?.rawValue != next?.rawValue else { return }
        if let activeInput { session.release(activeInput) }
        if let next { session.press(next) }
        activeInput = next
    }

    private func releaseDirection() {
        if let activeInput { session.release(activeInput) }
        activeInput = nil
    }
}

private struct DirectionPad: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        ZStack {
            control(.up, systemName: "chevron.up", offset: .init(width: 0, height: -25))
            control(.down, systemName: "chevron.down", offset: .init(width: 0, height: 25))
            control(.left, systemName: "chevron.left", offset: .init(width: -25, height: 0))
            control(.right, systemName: "chevron.right", offset: .init(width: 25, height: 0))
        }
        .frame(width: 104, height: 104)
    }

    private func control(_ input: DuoInput, systemName: String, offset: CGSize) -> some View {
        PressableButton(systemName: systemName) {
            session.press(input)
        } onRelease: {
            session.release(input)
        }
        .offset(offset)
    }
}

private struct ButtonPad: View {
    @ObservedObject var session: EmulatorSession

    var body: some View {
        ZStack {
            RoundLabelButton(label: "X") { session.press(.x) } onRelease: { session.release(.x) }
                .offset(x: -27, y: -27)
            RoundLabelButton(label: "A") { session.press(.a) } onRelease: { session.release(.a) }
                .offset(x: 27, y: -27)
            RoundLabelButton(label: "B") { session.press(.b) } onRelease: { session.release(.b) }
                .offset(x: -27, y: 27)
            RoundLabelButton(label: "Y") { session.press(.y) } onRelease: { session.release(.y) }
                .offset(x: 27, y: 27)
        }
        .frame(width: 116, height: 116)
    }
}

private struct ShoulderButton: View {
    let label: String
    @ObservedObject var session: EmulatorSession
    let input: DuoInput

    var body: some View {
        PillButton(label: label) { session.press(input) } onRelease: { session.release(input) }
    }
}

private struct MenuButton: View {
    let label: String
    @ObservedObject var session: EmulatorSession
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        PillButton(label: label, width: 78, height: 25, fontSize: 9, onPress: onPress, onRelease: onRelease)
    }
}

private struct RoundLabelButton: View {
    let label: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 16, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 48, height: 48)
            .background(LinearGradient(colors: pressed ? [.mint.opacity(0.9), .mint.opacity(0.4)] : [Color.white.opacity(0.28), Color.black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.28)))
            .shadow(color: .black.opacity(0.8), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
            .scaleEffect(pressed ? 0.93 : 1)
            .gesture(pressGesture)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !pressed {
                    pressed = true
                    onPress()
                }
            }
            .onEnded { _ in
                pressed = false
                onRelease()
            }
    }
}

private struct PillButton: View {
    let label: String
    var width: CGFloat = 42
    var height: CGFloat = 30
    var fontSize: CGFloat = 12
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    init(label: String, width: CGFloat = 42, height: CGFloat = 30, fontSize: CGFloat = 12, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.label = label
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.onPress = onPress
        self.onRelease = onRelease
    }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.78))
            .frame(width: width, height: height)
            .background(LinearGradient(colors: [Color.white.opacity(0.25), Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.8), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
            .scaleEffect(pressed ? 0.95 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

private struct PressableButton: View {
    let systemName: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    init(systemName: String, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.systemName = systemName
        self.onPress = onPress
        self.onRelease = onRelease
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.headline)
            .frame(width: 48, height: 48)
            .foregroundStyle(.white.opacity(0.8))
            .background(LinearGradient(colors: pressed ? [.mint.opacity(0.85), .mint.opacity(0.4)] : [Color.white.opacity(0.24), Color.black.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.25)))
            .shadow(color: .black.opacity(0.8), radius: pressed ? 1 : 4, y: pressed ? 1 : 4)
            .scaleEffect(pressed ? 0.93 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

private extension UTType {
    static let supportedGameFiles: [UTType] = ROMFiles.accepted.sorted().map {
        UTType(filenameExtension: $0) ?? .data
    }
}

private struct N64GameView: View {
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Nintendo 64").font(.headline)
                Spacer()
                Button(session.isPaused ? String(localized: "继续") : String(localized: "暂停")) { session.togglePause() }
                Button(String(localized: "退出"), action: onExit)
            }
            if let image = session.topImage {
                Image(image, scale: 1, label: Text(String(localized: "Nintendo 64 游戏画面")))
                    .resizable().aspectRatio(4.0 / 3.0, contentMode: .fit)
            } else { ProgressView(String(localized: "正在启动 N64…")).frame(maxHeight: .infinity) }
            HStack {
                hold("L", 2); hold("Z", 12); hold("START", 3); hold("R", 13)
            }
            HStack(spacing: 20) {
                Circle().fill(.white.opacity(0.15)).overlay(Text(String(localized: "摇杆")))
                    .frame(width: 100, height: 100)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        session.setCirclePad(x: (value.location.x - 50) / 50, y: (value.location.y - 50) / 50)
                    }.onEnded { _ in session.setCirclePad(x: 0, y: 0) })
                    .accessibilityLabel(String(localized: "N64 模拟摇杆"))
                VStack { hold("C ↑", 9); HStack { hold("C ←", 10); hold("C →", 11) }; hold("C ↓", 8) }
                VStack { hold("B", 1); hold("A", 0) }
            }
            HStack { hold("←", 6); hold("↑", 4); hold("↓", 5); hold("→", 7) }
        }
        .padding(24)
        .onDisappear { session.releaseAllInputs() }
    }
    private func hold(_ label: String, _ code: Int) -> some View {
        Text(label).font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in session.setN64Button(code, pressed: true) }
                .onEnded { _ in session.setN64Button(code, pressed: false) })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                session.setN64Button(code, pressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { session.setN64Button(code, pressed: false) }
            }
    }
}

@MainActor
struct PSPShutdownHandoff {
    static var take: ((SCNView) -> PSPShutdownHandoff?)?
    let nodes: [SCNNode]
    let lights: [SCNNode]
    let origin: CGPoint
    let pointsPerUnit: CGFloat
    #if DEBUG
    let anchors: [(SCNNode, CGPoint)]
    #endif
}

@MainActor
private final class PSP2000RuntimeModel: ObservableObject {
    let scene: SCNScene
    let cameraNode = SCNNode()
    private var screenNodes: [SCNNode] = []
    private var screenMaterials: [SCNMaterial] = []
    private var lastScreenImage: CGImage?
    private var handedOff = false
    var onVisualChange: (() -> Void)?
    private var lastViewport: CGSize = .zero
    private var lastUsableRect: CGRect = .zero
    var displayBrightness: CGFloat { screenBrightness }
    private var restPositions: [String: SCNVector3] = [:]
    private var indicatorMaterials: [String: [SCNMaterial]] = [:]
    private var consoleSize = CGSize(width: 0.1694, height: 0.0714)
    private var consoleCenter = CGPoint.zero
    private let buttonTravel: Float = 0.00082
    private let powerSlider = SCNNode()
    private let powerRest = SCNVector3(0.07965, -0.022, 0.0100)
    private let powerTravel: Float = 0.003
    private var powerSliderProgress: CGFloat = 0
    private var powerBlinkTask: Task<Void, Never>?
    private var powerIsRunning = false
    private(set) var powerIsBlinking = false
    private var screenBrightness: CGFloat = 1

    init() {
        let url = Bundle.main.url(forResource: "PSP2000-UMD-Open-Transition", withExtension: "usdz")!
        scene = (try? SCNScene(url: url, options: [.checkConsistency: true])) ?? SCNScene()
        scene.rootNode.enumerateChildNodes { node, _ in
            node.removeAllAnimations()
            if let name = node.name, PSP2000InteractiveSCNView.controlNames.contains(name) {
                restPositions[name] = node.position
            }
            if node.name == "SCREEN_SURFACE" || node.name == "SCREEN_SURFACE_USD" {
                screenNodes.append(node)
            }
        }
        let requiredControls = [
            "BUTTON_CROSS", "BUTTON_CIRCLE", "BUTTON_SQUARE", "BUTTON_TRIANGLE",
            "BUTTON_DPAD_UP", "BUTTON_DPAD_DOWN", "BUTTON_DPAD_LEFT", "BUTTON_DPAD_RIGHT",
            "BUTTON_L", "BUTTON_R", "BUTTON_START", "BUTTON_SELECT", "BUTTON_HOME",
            "BUTTON_VOLUME_DOWN", "BUTTON_VOLUME_UP", "ANALOG_STICK"
        ]
        let missingControls = requiredControls.filter { restPositions[$0] == nil }
        #if DEBUG
        print(missingControls.isEmpty
              ? "DUO_PSP_CONTROL_RIG_PASS: \(requiredControls.count) physical controls"
              : "DUO_PSP_CONTROL_RIG_FAIL: missing=\(missingControls.joined(separator: ","))")
        #endif
        measureConsole()
        bindIndicator(name: "memory", nodeName: "Access_indicator")
        bindIndicator(name: "wlan", nodeName: "Access_indicator.001")
        bindIndicator(name: "power", nodeName: "Power_indicator")
        bindIndicator(name: "hold", nodeName: "Power_indicator.001")
        scene.rootNode.childNode(withName: "UMD_LID", recursively: true)?.eulerAngles.x = 0

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.12
        camera.zNear = 0.01
        camera.zFar = 2
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 0.34)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.position = SCNVector3(-0.10, 0.12, 0.28)
        key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 700
        fill.position = SCNVector3(0.10, 0.12, -0.20)
        fill.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 200
        scene.rootNode.addChildNode(ambient)
        buildPowerSlider()
        setIndicators(running: false, hold: false, memory: false)
        updateScreen(nil)
    }

    private func bindIndicator(name: String, nodeName: String) {
        // The silver export merges the POWER lens into the housing mesh. Bind
        // that material directly so the original physical lens lights in place.
        if name == "power" {
            var lenses: [SCNMaterial] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                geometry.materials = geometry.materials.map { original in
                    guard original.name == "Power_LED___green" else { return original }
                    let material = (original.copy() as? SCNMaterial) ?? original
                    lenses.append(material)
                    return material
                }
            }
            if !lenses.isEmpty { indicatorMaterials[name] = lenses; return }
        }
        guard let node = scene.rootNode.childNode(withName: nodeName, recursively: true) else { return }
        var materials: [SCNMaterial] = []
        func bind(_ candidate: SCNNode) {
            guard let geometry = candidate.geometry else { return }
            let copies = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            geometry.materials = copies
            materials.append(contentsOf: copies)
        }
        bind(node)
        node.enumerateChildNodes { child, _ in bind(child) }
        indicatorMaterials[name] = materials
    }

    private func measureConsole() {
        guard let console = scene.rootNode.childNode(withName: "PSP_CONSOLE", recursively: true) else { return }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        console.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            let bounds = node.boundingBox
            let corners = [
                SCNVector3(bounds.min.x, bounds.min.y, bounds.min.z),
                SCNVector3(bounds.max.x, bounds.min.y, bounds.min.z),
                SCNVector3(bounds.min.x, bounds.max.y, bounds.min.z),
                SCNVector3(bounds.max.x, bounds.max.y, bounds.min.z),
                SCNVector3(bounds.min.x, bounds.min.y, bounds.max.z),
                SCNVector3(bounds.max.x, bounds.min.y, bounds.max.z),
                SCNVector3(bounds.min.x, bounds.max.y, bounds.max.z),
                SCNVector3(bounds.max.x, bounds.max.y, bounds.max.z)
            ]
            for corner in corners {
                let root = node.convertPosition(corner, to: scene.rootNode)
                minimum = simd_min(minimum, SIMD3(root.x, root.y, root.z))
                maximum = simd_max(maximum, SIMD3(root.x, root.y, root.z))
                found = true
            }
        }
        guard found else { return }
        consoleSize = CGSize(width: CGFloat(maximum.x - minimum.x), height: CGFloat(maximum.y - minimum.y))
        consoleCenter = CGPoint(x: CGFloat(maximum.x + minimum.x) / 2,
                                y: CGFloat(maximum.y + minimum.y) / 2)
        #if DEBUG
        print("DUO_PSP_MODEL_SIZE: \(consoleSize.width)x\(consoleSize.height)")
        #endif
    }

    // A narrow curved cap follows the housing edge; there is no front-panel control overlay.
    private func powerPosition(_ progress: CGFloat) -> SCNVector3 {
        let travel = Float(min(1, max(0, progress))) * powerTravel
        return SCNVector3(powerRest.x + 0.46 * travel - 10.5 * travel * travel,
                          powerRest.y + travel, powerRest.z)
    }

    private func buildPowerSlider() {
        // Work in millimetres for the Bezier profile, then scale to the imported mesh's metres.
        func curvedStrip(width: CGFloat, bottom: CGFloat, top: CGFloat, depth: CGFloat) -> SCNShape {
            func x(_ y: CGFloat) -> CGFloat { 0.46 * y - 0.0105 * y * y }
            let r = width / 2
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x(bottom) - r, y: bottom))
            path.addQuadCurve(to: CGPoint(x: x(top) - r, y: top),
                              controlPoint: CGPoint(x: 0.46 * (bottom + top) / 2 - 0.0105 * bottom * top - r,
                                                    y: (bottom + top) / 2))
            path.addQuadCurve(to: CGPoint(x: x(top) + r, y: top),
                              controlPoint: CGPoint(x: x(top), y: top + r))
            path.addQuadCurve(to: CGPoint(x: x(bottom) + r, y: bottom),
                              controlPoint: CGPoint(x: 0.46 * (bottom + top) / 2 - 0.0105 * bottom * top + r,
                                                    y: (bottom + top) / 2))
            path.addQuadCurve(to: CGPoint(x: x(bottom) - r, y: bottom),
                              controlPoint: CGPoint(x: x(bottom), y: bottom - r))
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: depth)
            shape.chamferRadius = 0.12
            return shape
        }
        let seat = curvedStrip(width: 1.65, bottom: -2.4, top: 5.1, depth: 0.22)
        seat.firstMaterial?.diffuse.contents = UIColor(white: 0.22, alpha: 1)
        seat.firstMaterial?.roughness.contents = 0.6
        let track = SCNNode(geometry: seat)
        track.scale = SCNVector3(0.001, 0.001, 0.001)
        track.position = SCNVector3(powerRest.x, powerRest.y, powerRest.z - 0.00025)
        scene.rootNode.addChildNode(track)

        let cap = curvedStrip(width: 1.35, bottom: -2.2, top: 2.2, depth: 0.65)
        cap.firstMaterial?.diffuse.contents = UIColor(white: 0.72, alpha: 1)
        cap.firstMaterial?.metalness.contents = 0.65
        cap.firstMaterial?.roughness.contents = 0.3
        let capNode = SCNNode(geometry: cap)
        capNode.scale = SCNVector3(0.001, 0.001, 0.001)
        powerSlider.addChildNode(capNode)
        powerSlider.name = "DUO_POWER_SLIDER"
        powerSlider.position = powerRest
        for offset in [-0.00075, 0, 0.00075] as [Float] {
            let groove = SCNCapsule(capRadius: 0.000065, height: 0.00105)
            groove.firstMaterial?.diffuse.contents = UIColor(white: 0.32, alpha: 1)
            groove.firstMaterial?.roughness.contents = 0.7
            let ridge = SCNNode(geometry: groove)
            ridge.eulerAngles.z = -.pi / 2 - atan(0.46 - 21 * offset)
            ridge.position = SCNVector3(0.46 * offset - 10.5 * offset * offset, offset, 0.00034)
            powerSlider.addChildNode(ridge)
        }
        scene.rootNode.addChildNode(powerSlider)
    }

    func powerEndpoints(in view: SCNView) -> (rest: CGPoint, pushed: CGPoint) {
        let a = view.projectPoint(powerPosition(0))
        let b = view.projectPoint(powerPosition(1))
        return (CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)), CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)))
    }

    func setPowerSlider(_ progress: CGFloat, returning: Bool = false) {
        powerSlider.removeAllActions()
        let target = min(1, max(0, progress))
        if returning {
            let start = powerSliderProgress
            let frames = (1...12).map { index -> SCNAction in
                let t = CGFloat(index) / 12
                let eased = 1 - pow(1 - t, 3)
                return .move(to: powerPosition(start + (target - start) * eased), duration: 0.16 / 12)
            }
            powerSlider.runAction(.sequence(frames))
        } else {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            powerSlider.position = powerPosition(target)
            SCNTransaction.commit()
        }
        powerSliderProgress = target
        onVisualChange?()
    }

    func setIndicators(running: Bool, hold: Bool, memory: Bool) {
        powerIsRunning = running
        setIndicator("memory", color: .systemOrange, active: memory)
        setIndicator("wlan", color: .systemGreen, active: false)
        if !powerIsBlinking { setIndicator("power", color: .systemGreen, active: running) }
        setIndicator("hold", color: .systemOrange, active: hold)
    }

    func setPowerShuttingDown(_ active: Bool) {
        guard active != powerIsBlinking else { return }
        powerBlinkTask?.cancel()
        powerBlinkTask = nil
        powerIsBlinking = active
        guard active else {
            setIndicator("power", color: .systemGreen, active: powerIsRunning)
            return
        }
        setIndicator("power", color: .systemGreen, active: true)
        // Only the real POWER lens blinks. No per-frame polling or overlay glow.
        powerBlinkTask = Task { @MainActor [weak self] in
            var lit = true
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
                guard let self, self.powerIsBlinking else { return }
                lit.toggle()
                self.setIndicator("power", color: .systemGreen, active: lit)
            }
        }
    }

    func finishPowerOff() {
        powerIsRunning = false
        setPowerShuttingDown(false)
        setIndicator("power", color: .systemGreen, active: false)
    }

    #if DEBUG
    var powerLampIsLit: Bool {
        indicatorMaterials["power"]?.contains { $0.emission.intensity > 0 } == true
    }
    #endif

    private func setIndicator(_ name: String, color: UIColor, active: Bool) {
        guard let materials = indicatorMaterials[name] else { return }
        let visible = active ? color : UIColor(white: 0.08, alpha: 1)
        guard materials.contains(where: { ($0.emission.intensity > 0) != active }) else { return }
        for material in materials {
            material.diffuse.contents = visible
            material.emission.contents = active ? color : UIColor.black
            material.emission.intensity = active ? 1.45 : 0
        }
        onVisualChange?()
    }

    func updateViewport(_ size: CGSize, usableRect: CGRect) {
        guard size.width > 0, size.height > 0,
              usableRect.width > 0, usableRect.height > 0 else { return }
        guard size != lastViewport || usableRect != lastUsableRect else { return }
        lastViewport = size
        lastUsableRect = usableRect
        onVisualChange?()
        // Fit the measured mesh to the actual unobstructed pixels, with no percentage padding.
        let pointsPerUnit = min(usableRect.width / consoleSize.width,
                                usableRect.height / consoleSize.height)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.camera?.orthographicScale = Double(size.height / pointsPerUnit / 2)
        cameraNode.position.x = Float(consoleCenter.x - (usableRect.midX - size.width / 2) / pointsPerUnit)
        cameraNode.position.y = Float(consoleCenter.y + (usableRect.midY - size.height / 2) / pointsPerUnit)
        SCNTransaction.commit()
    }

    func updateScreen(_ image: CGImage?) {
        guard !handedOff else { return }
        if screenMaterials.isEmpty {
            var configured = Set<ObjectIdentifier>()
            for node in screenNodes {
                func prepare(_ candidate: SCNNode) {
                    guard let geometry = candidate.geometry,
                          configured.insert(ObjectIdentifier(geometry)).inserted else { return }
                    let material = SCNMaterial()
                    material.lightingModel = .constant
                    material.diffuse.contents = UIColor.black
                    material.isDoubleSided = true
                    material.multiply.contents = UIColor(white: screenBrightness, alpha: 1)
                    geometry.materials = [material]
                    screenMaterials.append(material)
                }
                prepare(node)
                node.enumerateChildNodes { child, _ in prepare(child) }
            }
        }
        guard image !== lastScreenImage else { return }
        lastScreenImage = image
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for material in screenMaterials {
            material.diffuse.contents = image ?? UIColor.black
        }
        SCNTransaction.commit()
    }

    func displayRect(in view: SCNView) -> CGRect? {
        var result = CGRect.null
        for root in screenNodes {
            func include(_ node: SCNNode) {
                guard node.geometry != nil else { return }
                let b = node.boundingBox
                for x in [b.min.x, b.max.x] { for y in [b.min.y, b.max.y] {
                    let p = view.projectPoint(node.convertPosition(SCNVector3(x, y, b.max.z), to: nil))
                    result = result.union(CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0.001, height: 0.001))
                } }
            }
            include(root)
            root.enumerateChildNodes { node, _ in include(node) }
        }
        return result.isNull || result.width < 1 ? nil : result
    }

    func takeForShutdown(from sourceView: SCNView, into destinationView: SCNView) -> PSPShutdownHandoff? {
        guard !handedOff, sourceView.bounds.height > 0,
              let camera = cameraNode.camera else { return nil }
        finishPowerOff()
        updateScreen(nil)
        onVisualChange = nil
        handedOff = true
        let zero = sourceView.projectPoint(SCNVector3Zero)
        let origin = destinationView.convert(CGPoint(x: CGFloat(zero.x), y: CGFloat(zero.y)), from: sourceView)
        let nodes = scene.rootNode.childNodes.filter { $0.camera == nil && $0.light == nil }
        let lights = scene.rootNode.childNodes.filter { $0.light != nil }
        let scale = sourceView.bounds.height / (2 * camera.orthographicScale)
        #if DEBUG
        let anchors = ["BUTTON_CROSS", "BUTTON_DPAD_LEFT", "BUTTON_L", "BUTTON_R"].compactMap { name -> (SCNNode, CGPoint)? in
            guard let node = scene.rootNode.childNode(withName: name, recursively: true) else { return nil }
            let p = sourceView.projectPoint(node.worldPosition)
            return (node, destinationView.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), from: sourceView))
        }
        return PSPShutdownHandoff(nodes: nodes, lights: lights, origin: origin, pointsPerUnit: scale, anchors: anchors)
        #else
        return PSPShutdownHandoff(nodes: nodes, lights: lights, origin: origin, pointsPerUnit: scale)
        #endif
    }

    func restControlCenter(_ name: String) -> SCNVector3? {
        guard let node = scene.rootNode.childNode(withName: name, recursively: true),
              let rest = restPositions[name], let parent = node.parent else { return nil }
        let box = node.boundingBox
        let center = SCNVector3((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2,
                               (box.min.z + box.max.z) / 2)
        var position = node.convertPosition(center, to: parent)
        position.x += rest.x - node.position.x
        position.y += rest.y - node.position.y
        position.z += rest.z - node.position.z
        return parent.convertPosition(position, to: nil)
    }

    func setPressed(_ name: String, pressed: Bool) {
        onVisualChange?()
        guard let node = scene.rootNode.childNode(withName: name, recursively: true),
              let rest = restPositions[name] else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = pressed ? 0.045 : 0.095
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(
            name: pressed ? .easeIn : .easeOut
        )
        node.position = SCNVector3(rest.x, rest.y, rest.z - (pressed ? buttonTravel : 0))
        SCNTransaction.commit()
    }

    func cycleScreenBrightness() {
        screenBrightness = screenBrightness > 0.9 ? 0.65 : (screenBrightness < 0.7 ? 0.82 : 1)
        for node in screenNodes {
            node.geometry?.materials.forEach { $0.multiply.contents = UIColor(white: screenBrightness, alpha: 1) }
            node.enumerateChildNodes { child, _ in
                child.geometry?.materials.forEach { $0.multiply.contents = UIColor(white: self.screenBrightness, alpha: 1) }
            }
        }
    }

    func setAnalog(x: CGFloat, y: CGFloat, engaged: Bool) {
        onVisualChange?()
        let name = "ANALOG_STICK"
        guard let node = scene.rootNode.childNode(withName: name, recursively: true),
              let rest = restPositions[name] else { return }
        let travel: Float = 0.0022
        SCNTransaction.begin()
        SCNTransaction.animationDuration = engaged ? 0.025 : 0.11
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        node.position = SCNVector3(
            rest.x + Float(x) * travel,
            rest.y - Float(y) * travel,
            rest.z - (engaged ? 0.00038 : 0)
        )
        SCNTransaction.commit()
    }
}

private struct PSP2000SceneView: UIViewRepresentable {
    let model: PSP2000RuntimeModel
    let image: CGImage?
    let session: EmulatorSession?
    let controlsLocked: Bool
    let onExit: () -> Void
    var onControl: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = PSP2000InteractiveSCNView(frame: .zero)
        NeutralBranding.applyConsole(to: model.scene.rootNode)
        view.scene = model.scene
        view.pointOfView = model.cameraNode
        view.runtimeModel = model
        view.session = session
        session?.pspFramePresenter = { [weak view] image in view?.presentVideo(image) }
        session?.pspBufferPresenter = { [weak view] buffer, flipped in view?.presentBuffer(buffer, flipped: flipped) }
        if session != nil {
            PSPShutdownHandoff.take = { [weak view, weak model] destination in
                guard let view, let model, view.window != nil else { return nil }
                view.controlsLocked = true
                view.session?.pspBufferPresenter = nil
                view.session?.pspFramePresenter = nil
                view.clearVideo()
                return model.takeForShutdown(from: view, into: destination)
            }
        }
        model.onVisualChange = { [weak view] in view?.animatePhysicalModel() }
        view.onExit = onExit
        view.onControl = onControl
        view.backgroundColor = .clear
        view.isOpaque = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.animatePhysicalModel()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-psp-drive-test") {
            Task { @MainActor [weak view] in
                try? await Task.sleep(for: .seconds(1))
                await view?.runDrivingProbe()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-psp-system-volume-test") {
            Task { @MainActor [weak view] in
                try? await Task.sleep(for: .seconds(2))
                await view?.verifySystemVolume()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-psp-controls-test") {
            Task { @MainActor [weak view] in
                try? await Task.sleep(for: .seconds(1))
                await view?.verifyPhysicalControls()
            }
        }
        #endif
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if let interactive = view as? PSP2000InteractiveSCNView {
            interactive.updateModelViewport()
            interactive.presentVideo(image)
            interactive.controlsLocked = controlsLocked
            interactive.onExit = onExit
            interactive.onControl = onControl
        }
    }
}

@MainActor
private final class PSP2000InteractiveSCNView: SCNView {
    weak var session: EmulatorSession?
    var runtimeModel: PSP2000RuntimeModel?
    var onExit: (() -> Void)?
    var onControl: ((String) -> Void)?
    var controlsLocked = false {
        didSet { if controlsLocked && !oldValue { cancelAllControls() } }
    }
    private lazy var pressFeedback = UIImpactFeedbackGenerator(style: .rigid, view: self)
    private lazy var gridFeedback = UISelectionFeedbackGenerator(view: self)
    private var analogCell = 12
    private let videoLayer = CALayer()
    private let sharedVideoLayer = AVSampleBufferDisplayLayer()
    private var sharedFormat: CMVideoFormatDescription?
    private var sharedVideoActive = false
    private var currentVideoImage: CGImage?
    private var modelIdleWork: DispatchWorkItem?

    func animatePhysicalModel() {
        modelIdleWork?.cancel()
        isPlaying = true
        rendersContinuously = true
        let work = DispatchWorkItem { [weak self] in
            self?.rendersContinuously = false
            self?.isPlaying = false
        }
        modelIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // A front-facing PSP has a planar screen. Updating its image as a separate
    // layer avoids redrawing the unchanged housing for every emulated frame.
    // Buttons, stick, lamps and shutdown remain the original live 3D geometry.
    func clearVideo() {
        sharedVideoActive = false
        sharedVideoLayer.flushAndRemoveImage()
        presentVideo(nil)
    }

    func presentVideo(_ image: CGImage?) {
        if image == nil && sharedVideoActive && session?.isRunning == true { return }
        sharedVideoActive = false
        sharedVideoLayer.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.opacity = Float(runtimeModel?.displayBrightness ?? 1)
        if image !== currentVideoImage {
            currentVideoImage = image
            videoLayer.contents = image
        }
        videoLayer.isHidden = image == nil
        CATransaction.commit()
    }

    func presentBuffer(_ buffer: CVPixelBuffer, flipped: Bool) {
        if sharedVideoLayer.status == .failed { sharedVideoLayer.flush() }
        guard sharedVideoLayer.isReadyForMoreMediaData else { return }
        if sharedFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(sharedFormat!, imageBuffer: buffer) {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: buffer, formatDescriptionOut: &sharedFormat) == noErr else { return }
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard let format = sharedFormat,
              CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        sharedVideoActive = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.isHidden = true
        sharedVideoLayer.isHidden = false
        sharedVideoLayer.opacity = Float(runtimeModel?.displayBrightness ?? 1)
        sharedVideoLayer.transform = CATransform3DMakeScale(1, flipped ? -1 : 1, 1)
        CATransaction.commit()
        sharedVideoLayer.enqueue(sample)
    }
    private var activeControls: [ObjectIdentifier: String] = [:]
    private var analogOrigins: [ObjectIdentifier: CGPoint] = [:]
    private var powerTouch: ObjectIdentifier?
    private var powerOrigin = CGPoint.zero
    private var powerProgress: CGFloat = 0
    private var powerTask: Task<Void, Never>?
    private var volumeBeforeMute: Float = 1
    private let systemVolume = PSPSystemVolumeControl(frame: CGRect(x: -240, y: 0, width: 200, height: 44))

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        isMultipleTouchEnabled = true
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = UIColor.black.cgColor
        videoLayer.minificationFilter = .linear
        videoLayer.magnificationFilter = .linear
        videoLayer.masksToBounds = true
        videoLayer.isHidden = true
        layer.addSublayer(videoLayer)
        sharedVideoLayer.videoGravity = .resizeAspect
        sharedVideoLayer.backgroundColor = UIColor.black.cgColor
        sharedVideoLayer.masksToBounds = true
        sharedVideoLayer.isHidden = true
        layer.addSublayer(sharedVideoLayer)
        // Keep Apple's volume control attached for route/hardware-volume updates.
        // It is driven only by a user's press of the model's volume buttons.
        addSubview(systemVolume)
        NotificationCenter.default.addObserver(self, selector: #selector(cancelAllControls),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit {
        powerTask?.cancel()
        modelIdleWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelAllControls(); sharedVideoLayer.flushAndRemoveImage() }
        else {
            // The body is a UI surface, independent of emulated screen pixels.
            // Bound its fill cost on 3x displays while retaining 60 Hz controls.
            contentScaleFactor = min(2, traitCollection.displayScale)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateModelViewport()
        if let rect = runtimeModel?.displayRect(in: self) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = rect
            sharedVideoLayer.frame = rect
            CATransaction.commit()
        }
        presentVideo(currentVideoImage)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    func updateModelViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Full-screen surface: reserve only the camera/island side, not the mirrored
        // landscape safe-area padding on the opposite edge or the hidden home bar.
        var usable = bounds.insetBy(dx: 1 / contentScaleFactor, dy: 1 / contentScaleFactor)
        if DuoOrientation.isDuoDevice {
            runtimeModel?.updateViewport(bounds.size, usableRect: bounds)
            return
        }
        let insets = window?.safeAreaInsets ?? safeAreaInsets
        let orientation = window?.windowScene?.interfaceOrientation
        let windowRect = window.map { convert($0.bounds, from: $0) } ?? bounds
        if orientation?.isLandscape == true {
            if orientation == .landscapeLeft {
                usable.size.width = min(usable.maxX, windowRect.maxX - insets.right) - usable.minX
            } else {
                let edge = max(usable.minX, windowRect.minX + insets.left)
                usable.size.width = usable.maxX - edge
                usable.origin.x = edge
            }
        } else if orientation == .portraitUpsideDown {
            usable.size.height = min(usable.maxY, windowRect.maxY - insets.bottom) - usable.minY
        } else {
            let edge = max(usable.minY, windowRect.minY + insets.top)
            usable.size.height = usable.maxY - edge
            usable.origin.y = edge
        }
        runtimeModel?.updateViewport(bounds.size, usableRect: usable)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            if powerTouch == nil, let endpoints = runtimeModel?.powerEndpoints(in: self) {
                let hitRect = CGRect(x: endpoints.rest.x - 22, y: endpoints.pushed.y - 14,
                                     width: 44, height: endpoints.rest.y - endpoints.pushed.y + 36)
                if hitRect.contains(point) {
                    powerTouch = id
                    powerOrigin = point
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    continue
                }
            }
            guard let control = controlName(at: point) else { continue }
            if controlsLocked { continue }
            // One owner for the analog stick: another finger must never move its
            // origin or leave a stale direction behind when either finger lifts.
            if control == "ANALOG_STICK", activeControls.values.contains(control) { continue }
            let alreadyHeld = activeControls.values.contains(control)
            activeControls[id] = control
            if control == "ANALOG_STICK" {
                analogOrigins[id] = point
                analogCell = 12
                session?.setCirclePad(x: 0, y: 0)
            }
            if !alreadyHeld { press(control) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if id == powerTouch {
                movePower(to: touch.location(in: self))
                continue
            }
            guard activeControls[id] == "ANALOG_STICK", let origin = analogOrigins[id] else { continue }
            var latestAxis: CGPoint?
            for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                let point = sample.location(in: self)
                let axis = Self.analogValue(displacement: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
                latestAxis = axis
                let cell = Self.gridCell(axis)
                if cell != analogCell {
                    analogCell = cell
                    // Deliberately no cooldown: each delivered cell transition
                    // requests feedback at this control's current screen position.
                    gridFeedback.selectionChanged(at: feedbackPoint("ANALOG_STICK"))
                }
                if hypot(axis.x, axis.y) > 0.2 { onControl?("ANALOG_STICK") }
            }
            // Retain every grid-crossing haptic, but only the newest sample
            // can be displayed or polled by the game after this event returns.
            if let axis = latestAxis {
                session?.setCirclePad(x: axis.x, y: axis.y)
                runtimeModel?.setAnalog(x: axis.x, y: axis.y, engaged: true)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    private static func analogValue(displacement: CGPoint) -> CGPoint {
        let distance = hypot(displacement.x, displacement.y)
        let deadzone: CGFloat = 3.5
        guard distance > deadzone else { return .zero }
        let magnitude = min(1, (distance - deadzone) / (34 - deadzone))
        return CGPoint(x: displacement.x / distance * magnitude, y: displacement.y / distance * magnitude)
    }

    private static func gridCell(_ axis: CGPoint) -> Int {
        let column = min(4, max(0, Int((axis.x + 1) * 2.5)))
        let row = min(4, max(0, Int((axis.y + 1) * 2.5)))
        return row * 5 + column
    }

    private func feedbackPoint(_ name: String) -> CGPoint {
        guard let position = runtimeModel?.restControlCenter(name) else { return .zero }
        let projected = projectPoint(position)
        return CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
    }

    private func controlName(at point: CGPoint) -> String? {
        for hit in hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var node: SCNNode? = hit.node
            while let current = node {
                // USD wraps buttons in BUTTON_*_Geometry nodes. Only the exact rig
                // node has an input mapping and the intended press animation.
                if let name = current.name, Self.controlNames.contains(name) {
                    return name
                }
                node = current.parent
            }
        }
        // Expand the stick target to twice its visible diameter in each axis.
        // Exact physical button hits above take priority over the larger target.
        if let node = scene?.rootNode.childNode(withName: "ANALOG_STICK", recursively: true) {
            let box = node.boundingBox
            let a = projectPoint(node.convertPosition(box.min, to: nil))
            let b = projectPoint(node.convertPosition(box.max, to: nil))
            let radius = max(32, CGFloat(abs(b.x - a.x)))
            let center = feedbackPoint("ANALOG_STICK")
            if hypot(point.x - center.x, point.y - center.y) <= radius { return "ANALOG_STICK" }
        }
        return nil
    }

    private func press(_ control: String) {
        runtimeModel?.setPressed(control, pressed: true)
        onControl?(control)
        if let code = Self.buttonCodes[control] {
            session?.setPSPButton(code, pressed: true)
        } else {
            switch control {
            case "ANALOG_STICK": runtimeModel?.setAnalog(x: 0, y: 0, engaged: true)
            case "BUTTON_HOME": session?.togglePause()
            case "BUTTON_VOLUME_DOWN": changeSystemVolume(by: -1 / 16)
            case "BUTTON_VOLUME_UP": changeSystemVolume(by: 1 / 16)
            case "BUTTON_DISPLAY":
                runtimeModel?.cycleScreenBrightness()
                presentVideo(currentVideoImage)
            case "BUTTON_SOUND":
                if let session {
                    if session.gameVolume > 0 {
                        volumeBeforeMute = session.gameVolume
                        session.adjustVolume(by: -session.gameVolume)
                    } else { session.adjustVolume(by: volumeBeforeMute) }
                }
            default: break
            }
        }
        pressFeedback.impactOccurred(intensity: control == "ANALOG_STICK" ? 0.55 : 0.8,
                                     at: feedbackPoint(control))
        gridFeedback.prepare()
    }

    private func changeSystemVolume(by delta: Float) {
        guard !systemVolume.adjust(by: delta) else { return }
        // Fixed-volume routes and Simulator do not expose a writable slider.
        // Never silently substitute the game's gain for system volume.
        guard let controller = window?.rootViewController,
              controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: String(localized: "System Volume"),
            message: String(localized: "This audio output controls its own volume. Use its volume buttons or Control Center."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        controller.present(alert, animated: true)
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if id == powerTouch { cancelPower(); continue }
            analogOrigins.removeValue(forKey: id)
            guard let control = activeControls.removeValue(forKey: id) else { continue }
            // Two fingers may hold the same button; release only the last one.
            if activeControls.values.contains(control) { continue }
            runtimeModel?.setPressed(control, pressed: false)
            pressFeedback.impactOccurred(intensity: 0.4, at: feedbackPoint(control))
            if let code = Self.buttonCodes[control] { session?.setPSPButton(code, pressed: false) }
            if control == "ANALOG_STICK" {
                session?.setCirclePad(x: 0, y: 0)
                runtimeModel?.setAnalog(x: 0, y: 0, engaged: false)
                analogCell = 12
            }
        }
    }

    private func movePower(to point: CGPoint) {
        guard let endpoints = runtimeModel?.powerEndpoints(in: self) else { return }
        let travel = max(18, endpoints.rest.y - endpoints.pushed.y)
        let progress = abs(point.x - powerOrigin.x) > 44 ? 0 : min(max((powerOrigin.y - point.y) / travel, 0), 1)
        updatePower(progress)
    }

    private func updatePower(_ progress: CGFloat) {
        powerProgress = progress
        runtimeModel?.setPowerSlider(progress)
        if progress >= 0.92 {
            guard powerTask == nil else { return }
            runtimeModel?.setPowerShuttingDown(true)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            powerTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.powerTouch != nil, self.powerProgress >= 0.92 else { return }
                self.cancelAllControls()
                self.runtimeModel?.finishPowerOff()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.onExit?()
            }
        } else {
            powerTask?.cancel()
            powerTask = nil
            runtimeModel?.setPowerShuttingDown(false)
        }
    }

    private func cancelPower() {
        powerTask?.cancel()
        powerTask = nil
        powerTouch = nil
        powerProgress = 0
        runtimeModel?.setPowerShuttingDown(false)
        runtimeModel?.setPowerSlider(0, returning: true)
    }

    @objc private func cancelAllControls() {
        cancelPower()
        for control in Set(activeControls.values) { runtimeModel?.setPressed(control, pressed: false) }
        activeControls.removeAll()
        analogOrigins.removeAll()
        analogCell = 12
        runtimeModel?.setAnalog(x: 0, y: 0, engaged: false)
        session?.releaseAllInputs()
    }

    static let controlNames = Set(buttonCodes.keys).union([
        "ANALOG_STICK", "BUTTON_HOME", "BUTTON_VOLUME_DOWN", "BUTTON_VOLUME_UP",
        "BUTTON_DISPLAY", "BUTTON_SOUND"
    ])

    #if DEBUG
    // Explicit opt-in local QA controls. Commands exercise the same model and
    // input handlers as touches. A lost connection releases inputs after 15s.
    func runDrivingProbe() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let commandURL = documents.appendingPathComponent("psp-drive-command.json")
        var lastID = ""
        var held = Set<String>()
        var expiry = Date.distantPast
        let deadline = Date().addingTimeInterval(900)
        func releaseProbe() {
            for name in held {
                runtimeModel?.setPressed(name, pressed: false)
                if let code = Self.buttonCodes[name] { session?.setPSPButton(code, pressed: false) }
            }
            held.removeAll()
            session?.setCirclePad(x: 0, y: 0)
            runtimeModel?.setAnalog(x: 0, y: 0, engaged: false)
        }
        defer { releaseProbe() }
        while Date() < deadline, window != nil, session?.isRunning == true {
            if let data = try? Data(contentsOf: commandURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? String, id != lastID {
                lastID = id
                let next = Set((json["buttons"] as? [String] ?? []).filter { Self.buttonCodes[$0] != nil })
                for name in held.subtracting(next) {
                    runtimeModel?.setPressed(name, pressed: false)
                    if let code = Self.buttonCodes[name] { session?.setPSPButton(code, pressed: false) }
                }
                for name in next.subtracting(held) { press(name) }
                held = next
                let x = min(1, max(-1, json["x"] as? Double ?? 0))
                let y = min(1, max(-1, json["y"] as? Double ?? 0))
                session?.setCirclePad(x: x, y: y)
                runtimeModel?.setAnalog(x: x, y: y, engaged: x != 0 || y != 0)
                expiry = Date().addingTimeInterval(min(15, max(0.05, json["seconds"] as? Double ?? 1)))
                if json["capture"] as? Bool == true, let window {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try? image.jpegData(compressionQuality: 0.85)?.write(to: documents.appendingPathComponent("psp-drive.jpg"), options: .atomic)
                }
                print("DUO_PSP_DRIVE_COMMAND: \(id) buttons=\(next.sorted()) axis=\(x),\(y)")
            }
            if Date() >= expiry { releaseProbe(); expiry = .distantFuture }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // Run against the imported model and real SceneKit hit testing, not a copied
    // dictionary of expected results. Also exercises the production cancel/timer path.
    func verifySystemVolume() async {
        let before = AVAudioSession.sharedInstance().outputVolume
        let gain = session?.gameVolume ?? 1
        let delta: Float = before > 0.9 ? -1 / 16 : 1 / 16
        press(delta > 0 ? "BUTTON_VOLUME_UP" : "BUTTON_VOLUME_DOWN")
        try? await Task.sleep(for: .milliseconds(500))
        let changed = AVAudioSession.sharedInstance().outputVolume
        runtimeModel?.setPressed("BUTTON_VOLUME_UP", pressed: false)
        runtimeModel?.setPressed("BUTTON_VOLUME_DOWN", pressed: false)
        systemVolume.adjust(by: before - changed)
        try? await Task.sleep(for: .milliseconds(500))
        let restored = AVAudioSession.sharedInstance().outputVolume
        let passed = abs(changed - (before + delta)) < 0.02 && abs(restored - before) < 0.02 && (session?.gameVolume ?? 1) == gain
        let result: [String: Any] = ["passed": passed, "before": before, "changed": changed,
            "restored": restored, "gameGainUnchanged": (session?.gameVolume ?? 1) == gain]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
            try? data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("system-volume-test.json"))
        }
        print("DUO_SYSTEM_VOLUME_TEST: \(result)")
        fflush(stdout)
    }

    func verifyPhysicalControls() async {
        precondition(Self.analogValue(displacement: .zero) == .zero)
        precondition(Self.analogValue(displacement: CGPoint(x: 2, y: -2)) == .zero)
        precondition(Self.analogValue(displacement: CGPoint(x: 34, y: 0)) == CGPoint(x: 1, y: 0))
        precondition(Self.gridCell(.zero) == 12)
        var gridCells = Set<Int>()
        for row in 0..<5 { for col in 0..<5 {
            gridCells.insert(Self.gridCell(CGPoint(x: -0.8 + Double(col) * 0.4, y: -0.8 + Double(row) * 0.4)))
        } }
        precondition(gridCells.count == 25)
        print("DUO_PSP_ANALOG_PASS: neutral deadzone, full travel and 25 distinct feedback cells")
        for name in Self.controlNames.sorted() {
            guard let node = scene?.rootNode.childNode(withName: name, recursively: true) else {
                preconditionFailure("Missing physical control: \(name)")
            }
            let box = node.boundingBox
            let center = SCNVector3((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2,
                                    (box.min.z + box.max.z) / 2)
            let projected = projectPoint(node.convertPosition(center, to: nil))
            let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            let hit = controlName(at: point)
            print("DUO_PSP_HIT: \(name) -> \(hit ?? "nil") at \(point)")
            precondition(hit == name, "Physical control is not routed to its exact rig: \(name)")
            if Self.buttonCodes[name] != nil {
                press(name)
                try? await Task.sleep(for: .milliseconds(90))
                precondition(node.presentation.position.z < node.position.z + 0.00015,
                             "Physical button animation did not reach its pressed pose")
                session?.setPSPButton(Self.buttonCodes[name]!, pressed: false)
                runtimeModel?.setPressed(name, pressed: false)
            }
        }
        print("DUO_PSP_CONTROLS_PASS: all \(Self.controlNames.count) physical controls hit their exact rig")
        guard session?.isRunning != true else { fflush(stdout); return }
        let savedExit = onExit
        var exits = 0
        onExit = { exits += 1 }
        powerTouch = ObjectIdentifier(self)
        runtimeModel?.setIndicators(running: true, hold: false, memory: false)
        updatePower(1)
        precondition(runtimeModel?.powerIsBlinking == true && runtimeModel?.powerLampIsLit == true)
        func waitForLamp(_ lit: Bool) async -> Bool {
            for _ in 0..<40 {
                if runtimeModel?.powerLampIsLit == lit { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        let blinkedOff = await waitForLamp(false)
        let blinkedOn = await waitForLamp(true)
        precondition(blinkedOff && blinkedOn, "Shutdown POWER lens must alternate off and on")
        cancelPower()
        precondition(runtimeModel?.powerIsBlinking == false && runtimeModel?.powerLampIsLit == true,
                     "Early release must restore steady POWER light")
        try? await Task.sleep(for: .milliseconds(2050))
        precondition(exits == 0, "Releasing early must cancel shutdown")
        powerTouch = ObjectIdentifier(self)
        updatePower(1)
        cancelAllControls()
        try? await Task.sleep(for: .milliseconds(2050))
        precondition(exits == 0, "Background cancellation must cancel shutdown")
        powerTouch = ObjectIdentifier(self)
        updatePower(1)
        try? await Task.sleep(for: .milliseconds(2250))
        precondition(exits == 1 && powerProgress == 0 && powerTouch == nil)
        precondition(runtimeModel?.powerIsBlinking == false && runtimeModel?.powerLampIsLit == false,
                     "Completed shutdown must extinguish POWER light")
        print("DUO_PSP_POWER_LIGHT_PASS: flashes while held; cancellation restores steady green; exit extinguishes")
        onExit = savedExit
        print("DUO_PSP_POWER_PASS: early release and background cancel; 2-second hold exits once and springs back")
        fflush(stdout)
    }
    #endif

    private static let buttonCodes: [String: Int] = [
        "BUTTON_CROSS": 0, "BUTTON_SQUARE": 1, "BUTTON_SELECT": 2, "BUTTON_START": 3,
        "BUTTON_DPAD_UP": 4, "BUTTON_DPAD_DOWN": 5, "BUTTON_DPAD_LEFT": 6,
        "BUTTON_DPAD_RIGHT": 7, "BUTTON_CIRCLE": 8, "BUTTON_TRIANGLE": 9,
        "BUTTON_L": 10, "BUTTON_R": 11
    ]
}

private struct PSPGameView: View {
    @ObservedObject var session: EmulatorSession
    let onExit: () -> Void
    @State private var controlsLocked = false
    @StateObject private var model = PSP2000RuntimeModel()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [.black, Color(red: 0.035, green: 0.04, blue: 0.047), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ZStack {
                    PSP2000SceneView(
                        model: model,
                        image: session.pspUsesSharedBuffer ? nil : session.topImage,
                        session: session,
                        controlsLocked: controlsLocked,
                        onExit: onExit
                    )
                        .accessibilityLabel(String(localized: "PSP-2000 银色实体操作界面"))
                    PSPModelIndicatorDriver(
                        session: session,
                        controlsLocked: controlsLocked,
                        model: model
                    )

                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
        .onDisappear { session.releaseAllInputs() }
    }
}

private struct PSPModelIndicatorDriver: View {
    @ObservedObject var session: EmulatorSession
    let controlsLocked: Bool
    let model: PSP2000RuntimeModel
    @State private var memoryActive = false
    @State private var pulseTask: Task<Void, Never>?

    var body: some View {
        Color.clear
        .allowsHitTesting(false)
        .onAppear {
            updateModel()
            pulseMemoryLight()
        }
        .onChange(of: session.isRunning) { _, _ in updateModel() }
        .onChange(of: controlsLocked) { _, _ in updateModel() }
        .onChange(of: session.storageActivityToken) { _, _ in pulseMemoryLight() }
        .onDisappear { pulseTask?.cancel() }
        .accessibilityHidden(true)
    }

    private func updateModel() {
        model.setIndicators(running: session.isRunning, hold: controlsLocked, memory: memoryActive)
    }

    private func pulseMemoryLight() {
        pulseTask?.cancel()
        memoryActive = true
        updateModel()
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            memoryActive = false
            updateModel()
        }
    }
}

/// Native system media volume. No audio-session override, private selector, or PCM gain.
@MainActor
private final class PSPSystemVolumeControl: MPVolumeView {
    private var requestedVolume: Float?
    private var lastRequest = TimeInterval.zero

    private var volumeSlider: UISlider? {
        func slider(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }
        return slider(in: self)
    }

    @discardableResult
    func adjust(by delta: Float) -> Bool {
        #if targetEnvironment(simulator)
        return false // Apple does not implement system volume in Simulator.
        #else
        guard window != nil, let slider = volumeSlider, slider.isEnabled else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        // Consecutive fast taps must accumulate even before the route acknowledges
        // the previous value. Hardware/Control Center changes win between gestures.
        let actual = AVAudioSession.sharedInstance().outputVolume
        let base = now - lastRequest < 0.15 ? (requestedVolume ?? actual) : actual
        let target = min(slider.maximumValue, max(slider.minimumValue, base + delta))
        requestedVolume = target
        lastRequest = now
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            print("DUO_SYSTEM_VOLUME: requested=\(target) actual=\(AVAudioSession.sharedInstance().outputVolume)")
        }
        #endif
        return true
        #endif
    }
}
