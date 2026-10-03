import AVFoundation
import CoreHaptics
import SceneKit
import SwiftUI
import UIKit

private final class CartridgeViewport: SCNView {
    var onResize: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onResize?()
    }
}

/// One scene owns the cards, the closed console, and the handoff. A drag never replaces its card.
struct DragCartridgeSceneView: UIViewRepresentable {
    let games: [GameLibraryItem]
    let selectedID: String?
    let isExiting: Bool
    let onSelect: (String) -> Void
    let onInserted: (GameLibraryItem) -> Void
    let onFinished: () -> Void
    let onReturned: () -> Void
    let onImport: () -> Void
    let onStageActivityChanged: (Bool) -> Void
    var preservesCoverPane = false
    var circularWhenExpanded = false
    var allowsSelection = true
    var allowsInsertion = true
    var isVisible = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> SCNView { context.coordinator.makeView() }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.owner = self
        guard isVisible else {
            view.isPlaying = false
            view.rendersContinuously = false
            return
        }
        context.coordinator.reloadIfNeeded()
        // Selection publication causes SwiftUI to update this wrapper while
        // the display link is already laying out the same scene. Avoid doing
        // the full 3D layout twice in one frame.
        if (context.coordinator.mode != .finished || isExiting) &&
            context.coordinator.displayLink == nil &&
            context.coordinator.interactionDisplayLink == nil {
            context.coordinator.layout()
        }
        if isExiting { context.coordinator.reverseInsertion() }
        #if DEBUG
        context.coordinator.testTutorialIfRequested()
        #endif
    }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.displayLink?.invalidate()
        coordinator.interactionDisplayLink?.invalidate()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// `caseOpening` … `browsing` are PS2-only: the case opens in place, then its disc or
        /// memory card is pulled (`pull`, `latching`, …); `browsing` = card seated, save page shown.
        enum Mode { case idle, scroll, pull, latching, returning, opening, finished, closing, ejecting,
                    caseOpening, caseOpen, caseClosing, browsing }
        enum MotionCurve { case smooth, decelerating }
        var owner: DragCartridgeSceneView
        weak var view: SCNView?
        let scene = SCNScene()
        let console = SCNNode()
        let pspConsole = SCNNode()
        let cameraNode = SCNNode()
        let stage = SCNNode()
        let stageLight = SCNNode()
        let stageBackdrop = SCNNode()
        let stagePoolLight = SCNNode()
        let keyLight = SCNLight()
        let ambientLight = SCNLight()
        var lid: SCNNode?
        var pspLid: SCNNode?
        var pspShutdownHandoff: PSPShutdownHandoff?
        var cards: [SCNNode] = []
        var ids: [String] = []
        var appearanceRevisions: [UUID] = []
        var mode = Mode.idle {
            didSet {
                let active = mode != .idle && mode != .scroll && !(mode == .returning && pull == 0)
                if active != chromeHidden {
                    chromeHidden = active
                    DispatchQueue.main.async { [weak self] in self?.owner.onStageActivityChanged(active) }
                }
            }
        }
        var chromeHidden = false
        #if DEBUG
        var didTestTutorial = false
        func testTutorialIfRequested() {
            guard !didTestTutorial, ProcessInfo.processInfo.arguments.contains("-tutorial-test"),
                  owner.games.count == 2, owner.games.allSatisfy({ $0.url.scheme == "duo-tutorial" }) else { return }
            didTestTutorial = true
            assert(Set(ids).count == 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                assert(self.owner.allowsSelection && !self.owner.allowsInsertion)
                assert(!self.accessibleInsert(), "Cannot bypass selection lesson")
                self.settleSelection(to: 1) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        assert(self.owner.allowsInsertion)
                        assert(self.accessibleInsert())
                    }
                }
            }
        }
        #endif
        var selection = 0
        var selectionDestination: Int?
        var lastObservedSelectionID: String?
        var scroll: Float = 0
        var scrollStart: Float = 0
        var feedbackIndex = 0
        var feedbackStepPosition = 0
        var feedbackScrollSample: Float = 0
        var feedbackSampleTime = CACurrentMediaTime()
        var pendingScrollSpeed: Float = 0
        var pull: Float = 0
        var opening: Float = 0
        /// PS2: the opened case with its console (nil while every case is closed), its open
        /// presentation 0…1, and the tray travel after the disc latched (nil = follows `pull`).
        var ps2: PS2InsertionStage?
        var ps2Open: Float = 0
        var ps2Tray: Float?
        /// PS2 exit pan: overrides the stage backdrop/lights visibility (0 = transparent stage).
        var ps2StageVisibility: Float?
        /// DS / 3DS / PSP: the opened retail case and its medium (nil while every case is closed).
        /// Uses the PS2 case modes (`caseOpening` … `caseClosing`); see HandheldCaseStage.swift.
        var handheldCase: HandheldCaseStage?
        /// `HandheldCaseSettings.casesHidden` when the cards were last built.
        var builtCasesHidden = HandheldCaseSettings.casesHidden
        var displayLink: CADisplayLink?
        var interactionDisplayLink: CADisplayLink?
        var pendingScroll: Float?
        var pendingPull: Float?
        var gestureStartPoint = CGPoint.zero
        var animationStart = 0.0
        var animationDuration = 0.0
        var animationUpdate: ((Float) -> Void)?
        var animationCompletion: (() -> Void)?
        var animationCurve = MotionCurve.smooth
        #if DEBUG
        var animationFrameCount = 0
        var animationLastTick = 0.0
        var animationFrameIntervals: [Double] = []
        #endif
        var fullHeight: Float = 24
        let tilt: Float = .pi * 0.36
        let scrollPointsDivisor: CGFloat = 3.6
        var isCircular: Bool {
            guard owner.circularWhenExpanded, let view else { return false }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ring-test") { return true }
            #endif
            return view.bounds.width > view.bounds.height
        }
        func wrappedIndex(_ index: Int) -> Int {
            guard !cards.isEmpty else { return 0 }
            return ((index % cards.count) + cards.count) % cards.count
        }

        /// Gives the first and last cartridge a short rubber-band travel.
        /// The logarithmic resistance keeps the scene bounded even when the
        /// finger continues far beyond the end of the collection.
        func rubberBandedScroll(_ proposed: Float) -> Float {
            guard !cards.isEmpty else { return 0 }
            let lower: Float = 0
            let upper = Float(cards.count - 1)
            if proposed < lower {
                let excess = lower - proposed
                return lower - min(0.52, log1p(excess * 2.2) / 4.2)
            }
            if proposed > upper {
                let excess = proposed - upper
                return upper + min(0.52, log1p(excess * 2.2) / 4.2)
            }
            return proposed
        }

        init(_ owner: DragCartridgeSceneView) { self.owner = owner }

        func makeView() -> SCNView {
            let v = CartridgeViewport()
            view = v
            v.onResize = { [weak self] in
                guard self?.owner.isVisible == true else { return }
                self?.layout()
            }
            v.scene = scene
            // Keep the same scene ready during display and size transitions.
            // Hinge-specific APIs are SDK-beta-only, so the store build uses
            // the same size-driven layout on foldable and non-foldable iPhones.
            v.backgroundColor = .black
            v.antialiasingMode = .multisampling4X
            // Use one fixed cadence so carousel motion never oscillates
            // between adaptive refresh-rate steps.
            v.preferredFramesPerSecond = 60
            v.autoenablesDefaultLighting = false
            v.allowsCameraControl = false
            v.isAccessibilityElement = true
            v.accessibilityTraits = [.adjustable]
            v.accessibilityHint = String(localized: "左右滚动选择游戏，向下拖动卡带插入。长按可导入游戏。")
            v.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "上一个游戏"), target: self, selector: #selector(previous)),
                UIAccessibilityCustomAction(name: String(localized: "下一个游戏"), target: self, selector: #selector(next)),
                UIAccessibilityCustomAction(name: String(localized: "插入当前卡带"), target: self, selector: #selector(accessibleInsert)),
                UIAccessibilityCustomAction(name: String(localized: "打开或合上 PS2 碟盒"), target: self, selector: #selector(accessibleTogglePS2Case)),
                UIAccessibilityCustomAction(name: String(localized: "插入 PS2 记忆卡"), target: self, selector: #selector(accessibleInsertPS2MemoryCard)),
                UIAccessibilityCustomAction(name: String(localized: "打开或合上游戏盒"), target: self, selector: #selector(accessibleToggleHandheldCase)),
                UIAccessibilityCustomAction(name: String(localized: "导入游戏"), target: self, selector: #selector(importGame))
            ]
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.zNear = 0.1
            camera.zFar = 100
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(-0.01, 4.05, 30)
            scene.rootNode.addChildNode(cameraNode)
            v.pointOfView = cameraNode
            if let environment = Bundle.main.url(forResource: "Console-Studio", withExtension: "hdr") {
                scene.lightingEnvironment.contents = environment
            }
            scene.lightingEnvironment.intensity = 0
            let light = keyLight
            light.type = .directional
            light.intensity = 1100
            light.categoryBitMask = 1
            let lightNode = SCNNode()
            lightNode.light = light
            lightNode.eulerAngles = SCNVector3(-0.3, -0.25, 0)
            cameraNode.addChildNode(lightNode)
            let fill = SCNNode()
            fill.light = ambientLight
            fill.light?.type = .ambient
            fill.light?.intensity = 320
            fill.light?.categoryBitMask = 1
            scene.rootNode.addChildNode(fill)
            let backdrop = SCNPlane(width: 45, height: 45)
            let backdropMaterial = SCNMaterial()
            backdropMaterial.diffuse.contents = UIColor.black
            backdropMaterial.emission.contents = UIColor.black
            backdropMaterial.lightingModel = .constant
            backdropMaterial.roughness.contents = 1.0
            backdrop.materials = [backdropMaterial]
            stageBackdrop.geometry = backdrop
            stageBackdrop.categoryBitMask = 2
            stage.addChildNode(stageBackdrop)
            stageLight.light = SCNLight()
            stageLight.light?.type = .area
            stageLight.light?.areaExtents = SIMD3<Float>(10, 14, 0)
            stageLight.light?.categoryBitMask = 1
            stageLight.light?.color = UIColor(white: 1, alpha: 1)
            stageLight.light?.intensity = 1350
            stageLight.light?.spotInnerAngle = 18
            stageLight.light?.spotOuterAngle = 65
            stageLight.light?.attenuationStartDistance = 8
            stageLight.light?.attenuationEndDistance = 35
            stage.addChildNode(stageLight)
            stagePoolLight.light = SCNLight()
            stagePoolLight.light?.type = .omni
            stagePoolLight.light?.categoryBitMask = 2
            stagePoolLight.light?.intensity = 180
            stagePoolLight.light?.attenuationStartDistance = 0
            stagePoolLight.light?.attenuationEndDistance = 20
            stagePoolLight.light?.attenuationFalloffExponent = 2
            stage.addChildNode(stagePoolLight)
            scene.rootNode.addChildNode(stage)
            if let url = Bundle.main.url(forResource: "3DSXL-Cartridge-Open-Transition", withExtension: "usdz"),
               let model = try? SCNScene(url: url) {
                for node in model.rootNode.childNodes { console.addChildNode(node) }
                console.enumerateChildNodes { node, _ in
                    node.removeAllAnimations()
                    if node.name?.hasPrefix("LID_") == true { self.lid = node }
                }
            }
            scene.rootNode.addChildNode(console)
            if let url = Bundle.main.url(forResource: "PSP2000-UMD-Open-Transition", withExtension: "usdz"),
               let model = try? SCNScene(url: url) {
                for node in model.rootNode.childNodes { pspConsole.addChildNode(node) }
                pspConsole.enumerateChildNodes { node, stop in
                    node.removeAllAnimations()
                    if node.name == "UMD_LID" {
                        self.pspLid = node
                        stop.pointee = true
                    }
                }
                // The PSP asset is authored in metres. SceneKit's existing
                // carousel stage uses centimetre-like units.
                pspConsole.scale = SCNVector3(100, 100, 100)
            }
            pspConsole.isHidden = true
            scene.rootNode.addChildNode(pspConsole)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            v.addGestureRecognizer(pan)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            // Import is a deliberate still hold on idle Cover Flow; any drift belongs to the pan.
            hold.allowableMovement = 6
            hold.delegate = self
            v.addGestureRecognizer(hold)
            // One tap recognizer for every case: two on the same view would exclude each other
            // (only one tap is recognised), so a PS2 case would never see its tap.
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapCase(_:)))
            v.addGestureRecognizer(tap)
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handheldCaseSettingsChanged),
                name: UserDefaults.didChangeNotification, object: nil)
            reloadIfNeeded()
            let debugWarmupDelay = ProcessInfo.processInfo.arguments.contains("-library-fps-test") ? 1.0 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + debugWarmupDelay) {
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("-ring-test"), self.cards.count > 1 {
                    assert(self.wrappedIndex(-1) == self.cards.count - 1)
                    self.mode = .scroll
                    self.scroll = Float(-self.cards.count * 3 + 1)
                    self.updateSelectionFeedback()
                    self.settleSelection {
                        assert(self.selection == 1)
                        self.mode = .scroll
                        self.scroll = Float(self.cards.count * 4)
                        self.updateSelectionFeedback()
                        self.settleSelection {
                            assert(self.selection == 0 && self.scroll == 0)
                            assert(self.cards.dropFirst().contains { cos($0.eulerAngles.y) < 0 },
                                   "Rear arc must expose the real cartridge back")
                            print("RING_PASS: reverse wrap, forward wrap, selection and rear geometry")
                            fflush(stdout)
                            if arguments.contains("-cartridge-autoplay") { _ = self.accessibleInsert() }
                        }
                    }
                    return
                }
                if let index = arguments.firstIndex(of: "-cartridge-preview"),
                   arguments.indices.contains(index + 1), let progress = Float(arguments[index + 1]) {
                    self.mode = .pull
                    self.pull = min(max(progress, 0), 1)
                    if arguments.indices.contains(index + 2), let opening = Float(arguments[index + 2]) {
                        self.opening = min(max(opening, 0), 1)
                    }
                }
                if let index = arguments.firstIndex(of: "-coverflow-preview"),
                   arguments.indices.contains(index + 1), let offset = Float(arguments[index + 1]) {
                    self.scroll = min(max(offset, 0), Float(max(self.cards.count - 1, 0)))
                    self.mode = .scroll
                }
                if arguments.contains("-coverflow-test"), self.cards.count > 1 {
                    let original = self.selection
                    let target = original == 0 ? 1 : 0
                    // Exercise the held-drag path before release/settling can publish selection.
                    self.mode = .scroll
                    self.scroll = Float(target)
                    self.updateSelectionFeedback()
                    assert(self.selection == original && self.feedbackIndex == target)
                    DispatchQueue.main.async {
                        assert(self.owner.selectedID == self.ids[target])
                        print("LIVE_TITLE_PASS: selection published before finger release")
                        fflush(stdout)
                    }
                    self.settleSelection(to: target, publishDuringAnimation: false) {
                        assert(self.selection == target && self.feedbackIndex == target)
                        // Match a real gesture sequence: let SwiftUI commit the
                        // selected title before beginning a second interaction.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.settleSelection(to: original, publishDuringAnimation: false) {
                                assert(self.selection == original && self.feedbackIndex == original && self.mode == .idle)
                                print("COVERFLOW_PASS: rotate, select, feedback detent, and restore")
                                fflush(stdout)
                                if arguments.contains("-duo-layout-test") {
                                    self.owner.onSelect(self.ids[target])
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        assert(self.selection == target, "Library selection must reach the 3D scene")
                                        self.owner.onSelect(self.ids[original])
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                                            self.owner.onSelect(self.ids[target])
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                assert(self.selection == target && self.owner.selectedID == self.ids[target],
                                                       "The latest tap must win while selection is animating")
                                                self.owner.onSelect(self.ids[original])
                                                print("DUO_LAYOUT_PASS: bidirectional selection; rapid reversal keeps latest tap")
                                                fflush(stdout)
                                            }
                                        }
                                    }
                                }
                                if arguments.contains("-cartridge-autoplay") { _ = self.accessibleInsert() }
                            }
                        }
                    }
                } else if arguments.contains("-cartridge-autoplay") {
                    _ = self.accessibleInsert()
                }
                self.runPS2HitTestSelfTestIfRequested()
                self.runCaseTapTestIfRequested()
                self.runHandheldCasePreviewIfRequested()
                #endif
                self.layout()
            }
            return v
        }

        func reloadIfNeeded() {
            guard mode == .idle || (mode == .returning && pull == 0) else { return }
            let newIDs = owner.games.map(\.id)
            let newRevisions = owner.games.map(\.appearanceRevision)
            guard newIDs != ids || newRevisions != appearanceRevisions
                    || HandheldCaseSettings.casesHidden != builtCasesHidden else {
                guard owner.selectedID != lastObservedSelectionID else { return }
                lastObservedSelectionID = owner.selectedID
                if let requested = ids.firstIndex(of: owner.selectedID ?? ""),
                   requested != (selectionDestination ?? selection) {
                    settleSelection(to: requested, publishDuringAnimation: false)
                }
                return
            }
            cards.forEach { $0.removeFromParentNode() }
            cards = owner.games.enumerated().compactMap { index, game in
                guard let model = CartridgeSceneFactory.scene(for: game).rootNode
                    .childNode(withName: "cartridgeModel", recursively: true) else { return nil }
                model.removeFromParentNode()
                model.name = "library-card-\(index)"
                model.eulerAngles = SCNVector3Zero
                model.scale = SCNVector3(0.1, 0.1, 0.1)
                scene.rootNode.addChildNode(model)
                return model
            }
            ids = newIDs
            appearanceRevisions = newRevisions
            builtCasesHidden = HandheldCaseSettings.casesHidden
            if owner.games.contains(where: { $0.platform == .ps2 }) { PS2StageAssets.preload() }
            #if DEBUG
            let previewArguments = ProcessInfo.processInfo.arguments
            let previewTitleIndex = previewArguments.firstIndex(of: "-psp-preview-title")
            let previewTitle = previewTitleIndex.flatMap { index in
                previewArguments.indices.contains(index + 1) ? previewArguments[index + 1] : nil
            }
            let previewSelection = previewArguments.contains("-psp-cartridge-preview")
                ? owner.games.firstIndex(where: {
                    $0.platform == .psp && (previewTitle == nil || $0.title.localizedCaseInsensitiveContains(previewTitle!))
                }) : debugCaseGameIndex()
            #else
            let previewSelection: Int? = nil
            #endif
            lastObservedSelectionID = owner.selectedID
            selection = previewSelection ?? ids.firstIndex(of: owner.selectedID ?? "") ?? 0
            scroll = Float(selection)
            feedbackIndex = selection
            feedbackStepPosition = selection
            feedbackScrollSample = scroll
            feedbackSampleTime = CACurrentMediaTime()
            layout()
            // Compile SceneKit resources before the first drag so shader and
            // texture preparation cannot steal frames from the interaction.
            view?.prepare([scene]) { _ in }
        }

        func layout() {
            guard let view, view.bounds.height > 0 else { return }
            let size = view.bounds.size
            let paneWidth = owner.preservesCoverPane ? DuoLibraryLayout.paneWidth(in: size) : size.width
            let stageWidth = paneWidth + (size.width - paneWidth) * CGFloat(opening)
            let modelWidth = min(stageWidth * 1.08, size.height * 0.827)
            let modelHeight = modelWidth * 2500 / 2200
            fullHeight = Float(18.75 * size.height / modelHeight)
            cameraNode.camera?.orthographicScale = Double(fullHeight / 2)
            // Keep the cover's projection fixed; only the lid-opening handoff expands into gameplay.
            cameraNode.position.x = -0.01 - Float((size.width - stageWidth) / 2 / size.height) * fullHeight
            // Move the shelf down 30% from its previous screen-space centre (38% -> 49.4%).
            // Share this anchor with lighting and insertion so neither jumps when dragging.
            // Only the outer display's landscape layout moves the carousel 20% lower.
            // Foldable displays are handled by the same safe size-based anchor.
            let isOuterLandscape = size.width > size.height
            let shelfY = 4.05 + fullHeight * (isOuterLandscape ? -0.0928 : 0.006)
            let stageY: Float = 4.05 - fullHeight * 0.10 - (cos(tilt) * 4.65 - sin(tilt) * 0.47)
            let approaching = min(pull / 0.68, 1)
            let entry = max(0, (pull - 0.68) / 0.32)
            let active = mode == .pull || mode == .latching || (mode == .returning && pull > 0) || mode == .opening || mode == .finished || mode == .closing || mode == .ejecting || mode == .browsing
            let stageVisibility = ps2StageVisibility ?? (active ? max(0, 1 - pull * 4) : 1)
            stage.isHidden = stageVisibility == 0
            stageBackdrop.opacity = CGFloat(stageVisibility)
            stageBackdrop.position = SCNVector3(0, shelfY, isCircular ? -12 : -4)
            stageLight.position = SCNVector3(-4, shelfY + 7, 12)
            stageLight.look(at: SCNVector3(0, shelfY - 1, -4))
            stageLight.light?.intensity = CGFloat(80 * stageVisibility)
            stagePoolLight.position = SCNVector3(-1.5, shelfY - 2.5, 5)
            stagePoolLight.look(at: SCNVector3(0, shelfY - 2.5, -4))
            stagePoolLight.light?.intensity = CGFloat(90 * stageVisibility)
            keyLight.intensity = CGFloat(mix(350, 1100, 1 - stageVisibility))
            ambientLight.intensity = CGFloat(mix(100, 320, 1 - stageVisibility))
            scene.lightingEnvironment.intensity = CGFloat(0.55 * (1 - stageVisibility))
            if owner.games.indices.contains(selection), owner.games[selection].platform == .ps2 {
                // The black PS2 case and console wash out to grey under the handheld insertion light.
                keyLight.intensity = CGFloat(mix(350, 620, 1 - stageVisibility))
                ambientLight.intensity = CGFloat(mix(100, 150, 1 - stageVisibility))
                scene.lightingEnvironment.intensity = CGFloat(0.35 * (1 - stageVisibility))
            }
            if handheldCase != nil {
                // Retail cases wash out under the insertion light too; by the time the console has
                // opened into the game (`opening` 1) the light is exactly the handheld one again.
                let dark = 1 - stageVisibility
                keyLight.intensity = CGFloat(mix(350, mix(620, 1100, opening), dark))
                ambientLight.intensity = CGFloat(mix(100, mix(150, 320, opening), dark))
                scene.lightingEnvironment.intensity = CGFloat(mix(0.35, 0.55, opening) * dark)
            }
            let rise = active ? approaching : 0
            let isPSP = owner.games.indices.contains(selection) && owner.games[selection].platform == .psp
            let isPS2 = owner.games.indices.contains(selection) && owner.games[selection].platform == .ps2
            let caseStage = handheldCase
            NeutralBranding.applyConsole(to: console)
            NeutralBranding.applyConsole(to: pspConsole)
            // Fit the whole PSP, including the shoulder buttons, inside this viewport.
            let pspScale = min(Float(stageWidth / size.height) * fullHeight * 0.94 / 0.1694, 100)
            pspConsole.scale = SCNVector3(pspScale, pspScale, pspScale)
            console.isHidden = isPSP || isPS2 || !active || pull <= 0
            pspConsole.isHidden = !isPSP || !active || pull <= 0
            let activeConsole = isPSP ? pspConsole : console
            activeConsole.position = SCNVector3(0, mix(-fullHeight, stageY, rise) * (1 - opening), 0)
            activeConsole.eulerAngles = SCNVector3(
                tilt * (1 - opening),
                0,
                0
            )
            if isPSP, let handoff = pspShutdownHandoff {
                let screenUnits = fullHeight / Float(size.height)
                let finalScale = Float(handoff.pointsPerUnit) * screenUnits
                let scale = mix(pspScale, finalScale, opening)
                pspConsole.scale = SCNVector3(scale, scale, scale)
                let finalX = cameraNode.position.x + Float(handoff.origin.x - size.width / 2) * screenUnits
                let finalY = cameraNode.position.y - Float(handoff.origin.y - size.height / 2) * screenUnits
                pspConsole.position.x += finalX * opening
                pspConsole.position.y += finalY * opening
                // Preserve the runtime lighting exactly at the handoff, then
                // transition continuously into the library's insertion lighting.
                keyLight.intensity *= CGFloat(1 - opening)
                ambientLight.intensity *= CGFloat(1 - opening)
                scene.lightingEnvironment.intensity *= CGFloat(1 - opening)
                for node in handoff.lights {
                    node.light?.intensity = CGFloat(node.light?.type == .ambient ? 200 : 700) * CGFloat(opening)
                }
            }
            lid?.eulerAngles = SCNVector3(.pi * (1 - opening), 0, 0)
            // A PSP game uses the rear UMD bay. It starts open while the disc
            // is dragged in, then closes before emulation is launched.
            pspLid?.eulerAngles.x = -0.6632251 * (1 - opening)
            let rotation = simd_quatf(angle: tilt * (1 - opening), axis: SIMD3<Float>(1, 0, 0))
            // Card front sits 0.2 above the bay centre; the original card has 0.4 total depth.
            let seated = rotation.act(SIMD3<Float>(0, mix(6.55, 2.88, entry), 0.67))
                + SIMD3<Float>(console.position.x, console.position.y, console.position.z)
            let meeting = simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0))
                .act(SIMD3<Float>(0, 6.55, 0.67)) + SIMD3<Float>(0, stageY, 0)
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            for (index, card) in cards.enumerated() {
                let offset = Float(index) - scroll
                let outsideLinearViewport = !isCircular && abs(offset) > 2.25
                let fadedDuringInsertion = active && index != selection && pull >= 0.17
                card.isHidden = outsideLinearViewport || fadedDuringInsertion
                if card.isHidden { continue }
                // With an open retail case the case stays the shelf card and its medium is inserted.
                let insertsSelected = index == selection && active && !isPS2
                if insertsSelected {
                    let card = caseStage?.medium ?? card
                    let pspDiscVisibility = isPSP ? 1 - smoothstep(0.12, 0.52, opening) : 1
                    card.opacity = CGFloat(pspDiscVisibility)
                    // The shelf is 30% smaller; in the drive use the physical disc/bay ratio.
                    let scale = mix(0.145, isPSP ? pspScale / 700 : 0.1, approaching)
                    card.scale = SCNVector3(scale, scale, scale)
                    if isPSP {
                        // Model contract: UMD centre is (0, 0, -0.00515) m.
                        // Approach from 5 cm above the bay, then settle into it.
                        let pspEntry = pspConsole.simdConvertPosition(SIMD3<Float>(0, 0.05, -0.00515), to: nil)
                        let pspSeated = pspConsole.simdConvertPosition(SIMD3<Float>(0, 0, -0.00515), to: nil)
                        card.simdPosition = approaching < 1
                            ? simd_mix(SIMD3<Float>(0, shelfY, 0.67), pspEntry, SIMD3<Float>(repeating: approaching))
                            : simd_mix(pspEntry, pspSeated, SIMD3<Float>(repeating: entry))
                        // The selected UMD starts label-forward. During the
                        // downward pull it flips top-to-bottom around its horizontal
                        // axis, then aligns to the tilted PSP's rear drive.
                        let flipProgress = smoothstep(0.08, 0.76, approaching)
                        let alignmentProgress = smoothstep(0.76, 1, approaching)
                        let flipped = simd_quatf(
                            angle: .pi * flipProgress,
                            axis: SIMD3<Float>(1, 0, 0)
                        )
                        let seatedOrientation = pspConsole.simdOrientation
                            * simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                        card.simdOrientation = simd_slerp(flipped, seatedOrientation, alignmentProgress)
                    } else {
                        card.simdPosition = approaching < 1
                            ? simd_mix(SIMD3<Float>(0, shelfY, 0.67), meeting, SIMD3<Float>(repeating: approaching))
                            : seated
                        card.eulerAngles = SCNVector3(tilt * approaching * (1 - opening), 0, 0)
                    }
                }
                if !insertsSelected || caseStage != nil {
                    let turn = min(max(offset, -1), 1)
                    let distance = min(abs(offset), 1)
                    let scale = 0.145 - 0.045 * distance
                    card.scale = SCNVector3(scale, scale, scale)
                    if isCircular && cards.count > 1 {
                        let angle = offset * 2 * .pi / Float(cards.count)
                        let rear = (1 - cos(angle)) / 2
                        let radius = max(3.5, Float(size.width / size.height) * fullHeight * 0.44 - 1.8)
                        let rearOffset: Float = cards.count == 2 ? 0.55 * rear : 0
                        card.position = SCNVector3(radius * (sin(angle) - rearOffset),
                                                   shelfY + rear * 4, 0.67 - rear * 8)
                        card.eulerAngles = SCNVector3(0, angle, 0)
                        let ringScale: Float = 0.115 - rear * 0.025
                        card.scale = SCNVector3(ringScale, ringScale, ringScale)
                    } else {
                        card.position = SCNVector3(offset * 2.6 + turn * 2.4, shelfY - distance * 0.3, 0.67 - distance * 2)
                        card.eulerAngles = SCNVector3(0, -turn * .pi * 0.32, 0)
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-card-back-preview") {
                        card.eulerAngles.y += .pi
                    }
                    #endif
                    card.opacity = active ? CGFloat(max(0, 1 - pull * 6)) : 1
                }
                if isPS2, let ps2 {
                    if index == selection {
                        ps2.layout(card: card, frame: .init(
                            cameraY: cameraNode.position.y, shelfY: shelfY, fullHeight: fullHeight,
                            width: Float(stageWidth / size.height) * fullHeight,
                            open: ps2Open, pull: pull, tray: ps2Tray))
                    } else {
                        // Neighbours step aside while a case lies open across the stage.
                        card.opacity *= CGFloat(1 - ps2Open)
                        card.isHidden = card.isHidden || ps2Open >= 1
                    }
                }
                if let caseStage {
                    if index == selection {
                        caseStage.layout(card: card, frame: .init(
                            cameraY: cameraNode.position.y, shelfY: shelfY, fullHeight: fullHeight,
                            width: Float(stageWidth / size.height) * fullHeight,
                            pull: active ? pull : 0, opening: opening), insertion: insertsSelected)
                    } else {
                        card.opacity *= CGFloat(1 - caseStage.open)
                        card.isHidden = card.isHidden || caseStage.open >= 1
                    }
                }
            }
            SCNTransaction.commit()
            view.accessibilityLabel = owner.games.indices.contains(selection) ? owner.games[selection].title : String(localized: "游戏卡带")
        }

        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
            let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer is UILongPressGestureRecognizer { return mode == .idle }
            guard mode == .idle || mode == .caseOpen, !cards.isEmpty, owner.games.indices.contains(selection) else { return false }
            if selectedHasHandheldCase {
                return owner.games[selection].platform == .psp ? pspLid != nil : lid != nil
            }
            switch owner.games[selection].platform {
            case .ps2: return true
            case .psp: return mode == .idle && pspLid != nil
            default: return mode == .idle && lid != nil
            }
        }

        /// The cartridge is deliberately rendered smaller than a comfortable
        /// touch target. Let a downward drag begin from the surrounding stage
        /// as well, while direction locking keeps horizontal carousel gestures
        /// unchanged.
        func isInsideExpandedPullRegion(_ point: CGPoint, in view: SCNView) -> Bool {
            let paneWidth = owner.preservesCoverPane
                ? DuoLibraryLayout.paneWidth(in: view.bounds.size)
                : view.bounds.width
            let region = CGRect(
                x: paneWidth * 0.08,
                y: view.bounds.height * 0.18,
                width: paneWidth * 0.84,
                height: view.bounds.height * 0.64
            )
            return region.contains(point)
        }

        func pointHitsSelectedCard(_ point: CGPoint, in view: SCNView) -> Bool {
            view.hitTest(point, options: nil).contains { result in
                var node: SCNNode? = result.node
                while let current = node {
                    if current === cards[selection] { return true }
                    node = current.parent
                }
                return false
            }
        }

        @objc func pan(_ pan: UIPanGestureRecognizer) {
            guard let view else { return }
            let delta = pan.translation(in: view)
            switch pan.state {
            case .began:
                gestureStartPoint = pan.location(in: view)
                scrollStart = scroll
                pendingScroll = nil
                pendingPull = nil
                CartridgeFeedback.shared.prepare()
            case .changed:
                if mode == .idle || mode == .caseOpen {
                    let horizontalTravel = abs(delta.x)
                    let verticalTravel = abs(delta.y)
                    // Wait for a few points of travel before locking the axis.
                    // A generous horizontal bias keeps a slightly diagonal
                    // finger movement attached to the carousel.
                    if owner.allowsSelection,
                       horizontalTravel >= 5,
                       horizontalTravel >= verticalTravel * 0.72 {
                        // An open PS2 case snaps shut first, then the carousel moves on.
                        if mode == .caseOpen { closeOpenCase(thenStep: delta.x < 0 ? 1 : -1); return }
                        mode = .scroll
                        scrollStart = scroll
                        startInteractionDisplayLink()
                    } else if owner.allowsInsertion,
                              delta.y >= 7,
                              verticalTravel > horizontalTravel * 1.15,
                              (pointHitsSelectedCard(gestureStartPoint, in: view) ||
                               isInsideExpandedPullRegion(gestureStartPoint, in: view)) {
                        if selectedHasHandheldCase {
                            // A drag on a closed case opens it; still dragging once it is open (or a
                            // new drag on the open case) takes the medium out, starting from zero.
                            guard beginHandheldCasePull() else { return }
                            pan.setTranslation(.zero, in: view)
                            startInteractionDisplayLink()
                            return
                        }
                        if owner.games[selection].platform == .ps2 {
                            guard beginPS2Pull(from: gestureStartPoint, in: view) else { return }
                            startInteractionDisplayLink()
                            return
                        }
                        mode = .pull
                        startInteractionDisplayLink()
                    } else {
                        return
                    }
                }
                if mode == .scroll {
                    let unitsPerPoint = CGFloat(fullHeight) / view.bounds.height
                    let proposed = scrollStart - Float(delta.x * unitsPerPoint / scrollPointsDivisor)
                    pendingScroll = isCircular ? proposed : rubberBandedScroll(proposed)
                    pendingScrollSpeed = abs(Float(pan.velocity(in: view).x * unitsPerPoint / scrollPointsDivisor))
                } else if mode == .pull {
                    pendingPull = Float(min(max(delta.y / (view.bounds.height * 0.38), 0), 1))
                }
            case .ended:
                applyPendingInteractionFrame()
                stopInteractionDisplayLink()
                if mode == .scroll {
                    let unitsPerPoint = CGFloat(fullHeight) / view.bounds.height
                    let velocity = pan.velocity(in: view).x
                    let momentum = min(max(Float(-velocity * unitsPerPoint / scrollPointsDivisor * 0.20), -1.5), 1.5)
                    let projected = scroll + momentum
                    let target = isCircular
                        ? Int(projected.rounded())
                        : min(max(Int(projected.rounded()), 0), cards.count - 1)
                    // The title already followed the finger during the drag.
                    // If inertia advances once more, publish that final title
                    // after the glide so SwiftUI cannot interrupt a frame.
                    settleSelection(to: target, publishDuringAnimation: false)
                }
                else if mode == .pull { returnToShelf() }
            case .cancelled, .failed:
                applyPendingInteractionFrame()
                stopInteractionDisplayLink()
                if mode == .scroll { settleSelection() }
                else if mode == .pull { returnToShelf() }
            default: break
            }
        }

        func startInteractionDisplayLink() {
            guard interactionDisplayLink == nil else { return }
            let link = view?.window?.windowScene?.displayLink(
                target: self,
                selector: #selector(interactionTick)
            ) ?? CADisplayLink(target: self, selector: #selector(interactionTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            interactionDisplayLink = link
        }

        func stopInteractionDisplayLink() {
            interactionDisplayLink?.invalidate()
            interactionDisplayLink = nil
        }

        @objc func interactionTick() {
            applyPendingInteractionFrame()
        }

        /// Touch events can arrive more than once inside one display interval.
        /// Keep only the newest position and perform one SceneKit layout per frame.
        func applyPendingInteractionFrame() {
            if mode == .scroll, let pendingScroll {
                self.pendingScroll = nil
                scroll = pendingScroll
                updateSelectionFeedback(publish: false, speed: pendingScrollSpeed)
                layout()
            } else if mode == .pull, let pendingPull {
                self.pendingPull = nil
                pull = pendingPull
                layout()
                if pull >= 0.92 {
                    stopInteractionDisplayLink()
                    snapIntoLatch()
                }
            }
        }

        func updateSelectionFeedback(publish: Bool = true, speed suppliedSpeed: Float? = nil) {
            let now = CACurrentMediaTime()
            let elapsed = max(now - feedbackSampleTime, 1.0 / 240.0)
            let measuredSpeed = abs(scroll - feedbackScrollSample) / Float(elapsed)
            let speed = suppliedSpeed ?? measuredSpeed
            feedbackScrollSample = scroll
            feedbackSampleTime = now

            let rawNearest = Int(scroll.rounded())
            guard rawNearest != feedbackStepPosition else { return }
            let direction = rawNearest > feedbackStepPosition ? 1 : -1
            while feedbackStepPosition != rawNearest {
                feedbackStepPosition += direction
                CartridgeFeedback.shared.playSelection(speed: speed)
            }
            let nearest = isCircular ? wrappedIndex(rawNearest) : rawNearest
            guard ids.indices.contains(nearest) else { return }
            feedbackIndex = nearest
            if publish {
                lastObservedSelectionID = ids[nearest]
                owner.onSelect(ids[nearest])
            }
        }

        func settleSelection(to requested: Int? = nil, publishDuringAnimation: Bool = true,
                             completion: (() -> Void)? = nil) {
            let proposedTarget = requested ?? Int(scroll.rounded())
            let rawTarget = isCircular
                ? proposedTarget
                : min(max(proposedTarget, 0), max(cards.count - 1, 0))
            let target = isCircular ? wrappedIndex(rawTarget) : rawTarget
            let start = scroll
            let destination: Float
            if isCircular, requested != nil, !cards.isEmpty {
                let count = Float(cards.count)
                destination = Float(target) + ((start - Float(target)) / count).rounded() * count
            } else { destination = Float(rawTarget) }
            selectionDestination = target
            CartridgeFeedback.shared.prepare()
            mode = .returning
            let distance = abs(destination - start)
            let settleDuration = UIAccessibility.isReduceMotionEnabled
                ? 0.05
                : min(0.44, max(0.22, 0.18 + Double(distance) * 0.10))
            animate(duration: settleDuration, update: { t in
                self.scroll = self.mix(start, destination, t)
                self.updateSelectionFeedback(publish: publishDuringAnimation)
                self.layout()
            }, completion: {
                let shouldPlayFinalFeedback = self.feedbackIndex != target
                self.selection = target
                self.scroll = Float(target)
                self.feedbackIndex = target
                self.feedbackStepPosition = Int(destination.rounded())
                self.selectionDestination = nil
                self.mode = .idle
                if shouldPlayFinalFeedback { CartridgeFeedback.shared.playSelection(speed: 0.35) }
                if self.ids.indices.contains(target) {
                    self.lastObservedSelectionID = self.ids[target]
                    self.owner.onSelect(self.ids[target])
                }
                self.layout()
                completion?()
            }, curve: .decelerating)
        }

        func returnToShelf() {
            let start = pull
            // A PS2 disc or card falls back into its open case instead of the shelf.
            let rest: Mode = ps2 != nil || handheldCase != nil ? .caseOpen : .idle
            ps2?.pullReleased()
            mode = .returning
            animate(duration: 0.28, update: { t in self.pull = start * (1 - t); self.layout() },
                completion: {
                    self.mode = rest
                    self.pull = 0
                    if let ps2 = self.ps2, ps2.caseStage.isBare {
                        // A bare PS2 disc has no case to fall back into: back to its shelf slot.
                        ps2.remove()
                        self.ps2 = nil
                        self.mode = .idle
                    }
                    self.layout()
                })
        }

        func snapIntoLatch() {
            guard mode == .pull, owner.games.indices.contains(selection) else { return }
            mode = .latching
            let start = pull
            animate(duration: UIAccessibility.isReduceMotionEnabled ? 0.04 : 0.085, update: { t in
                self.pull = self.mix(start, 1, t)
                self.layout()
            }, completion: { self.completeLatch() })
        }

        func completeLatch() {
            guard mode == .latching, owner.games.indices.contains(selection) else { return }
            if ps2 != nil { completePS2Latch(); return }
            let insertedGame = owner.games[selection]
            let isTutorialCard = insertedGame.url.scheme == "duo-tutorial"
            mode = .opening
            pull = 1
            layout()
            CartridgeFeedback.shared.playInsertionLatch()
            if isTutorialCard { owner.onInserted(insertedGame) }
            let duration = UIAccessibility.isReduceMotionEnabled ? 0.55 : 1.6
            animate(duration: duration, update: { t in
                self.opening = t
                self.layout()
            }, completion: {
                self.mode = .finished
                self.opening = 1
                self.layout()
                if !isTutorialCard { self.owner.onInserted(insertedGame) }
                self.owner.onFinished()
            })
        }

        func reverseInsertion() {
            guard mode == .finished else { return }
            if ps2 != nil { reversePS2Insertion(); return }
            if let view, owner.games.indices.contains(selection), owner.games[selection].platform == .psp,
               let handoff = PSPShutdownHandoff.take?(view) {
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                pspConsole.childNodes.forEach { $0.removeFromParentNode() }
                for node in handoff.nodes { pspConsole.addChildNode(node) }
                for node in handoff.lights { scene.rootNode.addChildNode(node) }
                pspLid = pspConsole.childNode(withName: "UMD_LID", recursively: true)
                // The handed-off nodes have not been neutralised by this scene yet.
                NeutralBranding.invalidate(pspConsole)
                pspShutdownHandoff = handoff
                PSPShutdownHandoff.take = nil
                SCNTransaction.commit()
                #if DEBUG
                print("DUO_PSP_SAME_MODEL_HANDOFF: transferred runtime geometry without rebuilding")
                #endif
            }
            mode = .closing
            pull = 1
            opening = 1
            layout()
            #if DEBUG
            if let handoff = pspShutdownHandoff, let view {
                for (node, expected) in handoff.anchors {
                    let actual = view.projectPoint(node.worldPosition)
                    let error = hypot(CGFloat(actual.x) - expected.x, CGFloat(actual.y) - expected.y)
                    precondition(error < 1, "PSP shutdown handoff moved a physical control by \(error) points")
                }
                print("DUO_PSP_HANDOFF_ALIGNMENT_PASS: four physical anchors stay within one point")
                if ProcessInfo.processInfo.arguments.contains("-cartridge-roundtrip") {
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? view.snapshot().pngData()?.write(to: directory.appendingPathComponent("psp-handoff.png"))
                }
            }
            #endif
            // Reuse the forward pose function in reverse: close before withdrawing the card.
            animate(duration: UIAccessibility.isReduceMotionEnabled ? 0.55 : 1.6, update: { t in
                self.opening = 1 - t
                self.layout()
            }, completion: {
                assert(self.pull == 1 && self.opening == 0)
                self.mode = .ejecting
                CartridgeFeedback.shared.playEjectionRelease()
                self.animate(duration: UIAccessibility.isReduceMotionEnabled ? 0.4 : 1.1, update: { t in
                    self.pull = 1 - t
                    self.layout()
                }, completion: {
                    self.pull = 0
                    self.opening = 0
                    // A medium taken from a retail case has dropped back into it: close the case.
                    if self.handheldCase != nil {
                        self.closeHandheldCase { self.finishReturn() }
                    } else {
                        self.finishReturn()
                    }
                })
            })
        }

        /// Exit complete: Cover Flow is idle with the returned card selected.
        func finishReturn() {
            self.mode = .idle
            self.scroll = Float(self.selection)
            self.layout()
            assert(self.console.isHidden && self.displayLink == nil)
            self.pspShutdownHandoff?.lights.forEach { $0.removeFromParentNode() }
            self.pspShutdownHandoff = nil
            self.owner.onReturned()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-cartridge-roundtrip") {
                assert(self.mode == .idle && self.pull == 0 && self.opening == 0)
                print("CARTRIDGE_ROUNDTRIP_PASS: closed, ejected, selection restored")
                fflush(stdout)
                if ProcessInfo.processInfo.arguments.contains("-cartridge-reenter") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        let started = self.accessibleInsert()
                        assert(started)
                        print("CARTRIDGE_REENTER_PASS: input unlocked and insertion restarted")
                    }
                }
            }
            #endif
        }

        func animate(duration: Double, update: @escaping (Float) -> Void,
                     completion: @escaping () -> Void, curve: MotionCurve = .smooth) {
            stopInteractionDisplayLink()
            displayLink?.invalidate()
            animationStart = CACurrentMediaTime()
            animationDuration = duration
            animationUpdate = update
            animationCompletion = completion
            animationCurve = curve
            #if DEBUG
            animationFrameCount = 0
            animationLastTick = animationStart
            animationFrameIntervals.removeAll(keepingCapacity: true)
            #endif
            // The scene's link follows it onto the inner display during unfolding.
            let link = view?.window?.windowScene?.displayLink(target: self, selector: #selector(tick))
                ?? CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        @objc func tick() {
            #if DEBUG
            animationFrameCount += 1
            let frameTime = CACurrentMediaTime()
            animationFrameIntervals.append(frameTime - animationLastTick)
            animationLastTick = frameTime
            #endif
            let t = min(Float((CACurrentMediaTime() - animationStart) / animationDuration), 1)
            let eased: Float
            switch animationCurve {
            case .smooth:
                eased = t * t * (3 - 2 * t)
            case .decelerating:
                eased = 1 - (1 - t) * (1 - t)
            }
            animationUpdate?(eased)
            if t >= 1 {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-library-fps-test") {
                    let elapsed = CACurrentMediaTime() - animationStart
                    let fps = Double(animationFrameCount) / elapsed
                    let sorted = animationFrameIntervals.sorted()
                    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                    let maxInterval = sorted.last ?? 0
                    let dropped = sorted.filter { $0 > (1.0 / 60.0) * 1.5 }.count
                    print("DUO_LIBRARY_FPS target=60 actual=\(String(format: "%.1f", fps)) p95ms=\(String(format: "%.1f", p95 * 1000)) maxms=\(String(format: "%.1f", maxInterval * 1000)) drops=\(dropped) duration=\(String(format: "%.3f", elapsed))")
                    fflush(stdout)
                }
                #endif
                displayLink?.invalidate()
                displayLink = nil
                let finish = animationCompletion
                animationUpdate = nil
                animationCompletion = nil
                finish?()
            }
        }
        @objc func interrupted() {
            applyPendingInteractionFrame()
            stopInteractionDisplayLink()
            if mode == .pull { returnToShelf() }
            if mode == .scroll { settleSelection() }
        }
        @objc func longPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began && mode == .idle { owner.onImport() }
        }
        @objc func importGame() -> Bool { owner.onImport(); return true }
        @objc func previous() -> Bool {
            guard owner.allowsSelection, mode == .idle, !cards.isEmpty else { return false }
            settleSelection(to: isCircular ? wrappedIndex(selection - 1) : max(0, selection - 1)); return true
        }
        @objc func next() -> Bool {
            guard owner.allowsSelection, mode == .idle, !cards.isEmpty else { return false }
            settleSelection(to: isCircular ? wrappedIndex(selection + 1) : min(cards.count - 1, selection + 1)); return true
        }
        @objc func accessibleInsert() -> Bool {
            if owner.games.indices.contains(selection), owner.games[selection].platform == .ps2 {
                return accessibleInsertPS2(.disc)
            }
            if selectedHasHandheldCase { return accessibleInsertHandheld() }
            guard owner.allowsInsertion, mode == .idle, !cards.isEmpty else { return false }
            mode = .pull
            animate(duration: 0.48, update: { self.pull = $0 * 0.90; self.layout() }, completion: {
                self.snapIntoLatch()
            })
            return true
        }
    }
}

@MainActor
final class CartridgeFeedback {
    static let shared = CartridgeFeedback()

    private var hapticEngine: CHHapticEngine?
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let selectionPlayers = (0..<4).map { _ in AVAudioPlayerNode() }
    private var nextSelectionPlayer = 0
    private let selectionBuffer: AVAudioPCMBuffer?
    private let insertionBuffer: AVAudioPCMBuffer?
    private let ejectionBuffer: AVAudioPCMBuffer?
    private var audioIsPrepared = false
    private let selectionImpact = UIImpactFeedbackGenerator(style: .soft)
    private let fallbackImpact = UIImpactFeedbackGenerator(style: .rigid)

    private init() {
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            hapticEngine = try? CHHapticEngine()
            hapticEngine?.isAutoShutdownEnabled = true
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        selectionBuffer = Self.makeSelectionClick(format: format)
        let insertionRecording = Self.loadInsertionRecording()
        insertionBuffer = insertionRecording
        ejectionBuffer = insertionRecording.flatMap {
            Self.reversedBuffer($0, trimmingLeadingSeconds: 0.07)
        }
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        for selectionPlayer in selectionPlayers {
            audioEngine.attach(selectionPlayer)
            audioEngine.connect(selectionPlayer, to: audioEngine.mainMixerNode, format: format)
        }
        audioEngine.mainMixerNode.outputVolume = 0.68
        audioEngine.isAutoShutdownEnabled = true
    }

    func prepare() {
        selectionImpact.prepare()
        fallbackImpact.prepare()
        try? hapticEngine?.start()
        guard !audioEngine.isRunning else {
            audioIsPrepared = true
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            audioEngine.prepare()
            try audioEngine.start()
            audioIsPrepared = true
        } catch {
            audioIsPrepared = false
        }
    }

    func playSelection(speed: Float) {
        if !audioIsPrepared || !audioEngine.isRunning { prepare() }
        let normalized = min(max(speed / 8, 0), 1)
        let intensity = CGFloat(0.28 + normalized * 0.60)
        selectionImpact.impactOccurred(intensity: intensity)
        selectionImpact.prepare()
        guard audioIsPrepared, let selectionBuffer else { return }
        let selectionPlayer = selectionPlayers[nextSelectionPlayer]
        nextSelectionPlayer = (nextSelectionPlayer + 1) % selectionPlayers.count
        selectionPlayer.stop()
        selectionPlayer.volume = 0.22 + normalized * 0.46
        selectionPlayer.scheduleBuffer(selectionBuffer, at: nil, options: .interrupts)
        selectionPlayer.play()
    }

    func playInsertionLatch() {
        if let hapticEngine {
            let contact = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.58),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.92)
                ],
                relativeTime: 0
            )
            let latch = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                ],
                relativeTime: 0.018
            )
            let settle = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.72),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.98)
                ],
                relativeTime: 0.052
            )
            if let pattern = try? CHHapticPattern(events: [contact, latch, settle], parameters: []),
               let patternPlayer = try? hapticEngine.makePlayer(with: pattern) {
                try? patternPlayer.start(atTime: CHHapticTimeImmediate)
            }
        } else {
            fallbackImpact.impactOccurred(intensity: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.052) { [fallbackImpact] in
                fallbackImpact.impactOccurred(intensity: 0.72)
            }
        }
        play(buffer: insertionBuffer)
    }

    func playEjectionRelease() {
        fallbackImpact.impactOccurred(intensity: 0.82)
        play(buffer: ejectionBuffer)
    }

    private func play(buffer: AVAudioPCMBuffer?) {
        if !audioIsPrepared || !audioEngine.isRunning { prepare() }
        guard audioIsPrepared, let buffer else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private static func makeSelectionClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        makeBuffer(format: format, duration: 0.045) { time, _ in
            let decay = exp(-time * 88)
            return decay * (sin(2 * .pi * 2_100 * time) * 0.32 + sin(2 * .pi * 3_700 * time) * 0.14)
        }
    }

    private static func loadInsertionRecording() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(
            forResource: "Cartridge-Finger-Snap",
            withExtension: "wav"
        ), let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else { return nil }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    private static func reversedBuffer(
        _ source: AVAudioPCMBuffer,
        trimmingLeadingSeconds seconds: Double
    ) -> AVAudioPCMBuffer? {
        let sourceFrameLength = source.frameLength
        let trimFrames = min(
            AVAudioFrameCount(source.format.sampleRate * seconds),
            sourceFrameLength > 1 ? sourceFrameLength - 1 : 0
        )
        let frameLength = sourceFrameLength - trimFrames
        guard frameLength > 0,
              let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: frameLength
              ),
              let sourceChannels = source.floatChannelData,
              let destinationChannels = destination.floatChannelData else { return nil }

        destination.frameLength = frameLength
        let frames = Int(frameLength)
        let trimmedFrames = Int(trimFrames)
        let fadeFrames = min(Int(source.format.sampleRate * 0.004), frames)
        for channel in 0..<Int(source.format.channelCount) {
            let input = sourceChannels[channel]
            let output = destinationChannels[channel]
            for frame in 0..<frames {
                var sample = input[Int(sourceFrameLength) - trimmedFrames - frame - 1]
                if frame < fadeFrames {
                    sample *= Float(frame) / Float(max(1, fadeFrames))
                }
                output[frame] = sample
            }
        }
        return destination
    }

    private static func makeBuffer(
        format: AVAudioFormat,
        duration: Double,
        sample: (_ time: Double, _ noise: Double) -> Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        var noiseState: UInt32 = 0x51A7_C0DE
        for frame in 0..<Int(frameCount) {
            noiseState = 1_664_525 &* noiseState &+ 1_013_904_223
            let noise = (Double(noiseState) / Double(UInt32.max)) * 2 - 1
            let value = sample(Double(frame) / format.sampleRate, noise)
            samples[frame] = Float(max(-0.92, min(0.92, value)))
        }
        return buffer
    }
}
