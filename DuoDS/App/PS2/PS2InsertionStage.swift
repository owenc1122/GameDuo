import SceneKit
import SwiftUI
import UIKit

enum PS2PullTarget { case disc, memoryCard }

/// PS2 part of the Cover Flow scene: poses the opened case, the console rising from below
/// (tray, memory card door, LEDs) and the disc / memory card travelling between them.
/// `DragCartridgeSceneView.Coordinator` owns the timing (its state machine and `animate`);
/// this type turns the progress values into node transforms.
@MainActor
final class PS2InsertionStage {
    /// Scene-space inputs of one layout pass.
    struct Frame {
        var cameraY: Float
        var shelfY: Float
        /// Visible scene height and stage width in scene units.
        var fullHeight: Float
        var width: Float
        /// Case presentation, 0 closed in the shelf … 1 open facing the camera.
        var open: Float
        /// Shared pull progress (same thresholds as the DS/PSP insertion: approach until 0.68, then entry).
        var pull: Float
        /// Explicit tray travel (0…1 of 0.135 m) after the latch; nil = follows the disc pull.
        var tray: Float?
    }

    enum PowerLight { case off, standby, on }

    let caseStage: PS2CaseStage
    var target = PS2PullTarget.disc
    private var holderClicks = CaseHolderClicks()
    /// Leaving a game: the disc travels from `start` (world) to its rest in the case.
    var discReturn: (start: simd_float4x4, progress: Float)?
    /// Entering a game (one continuous camera move): the console blends from its resting pose
    /// (progress 0) to `pose` (1), where it matches the game screen's console, and the case rises
    /// out of view.
    var entry: (pose: EntryPose, progress: Float)?

    struct EntryPose {
        var centre: SIMD3<Float>
        var orientation: simd_quatf
        var scale: Float
    }
    private let consoleRoot = SCNNode()
    private let console: SCNNode?
    private let tray: SCNNode?
    private let trayRest: SIMD3<Float>
    private let trayAnchor: SCNNode?
    private let door: SCNNode?
    private let slot: SCNNode?
    private var powerMaterials: [SCNMaterial] = []
    private var ejectMaterials: [SCNMaterial] = []
    private var blinkTask: Task<Void, Never>?
    private let powerGlow = SCNNode()
    private let ejectGlow = SCNNode()
    private var trayEjectAnnounced = false
    /// Slot door sound state: whether its opening was announced, and the extreme opening since.
    private var doorAnnouncedOpen = false
    private var doorExtreme: Float = 0

    static let trayTravel: Float = 0.135
    private static let consoleTilt: Float = 0.62
    /// The console's visual centre in its own units (the point the layout places).
    private static let visualCentre = SIMD3<Float>(0, 0.039, 0.05)
    private static let green = UIColor(red: 0.235, green: 1, blue: 0.42, alpha: 1)   // #3CFF6B, as PS2GameView
    private static let red = UIColor(red: 1, green: 0.165, blue: 0.1, alpha: 1)      // #FF2A1A
    private static let blue = UIColor(red: 0.227, green: 0.482, blue: 1, alpha: 1)   // #3A7BFF

    init?(card: SCNNode, game: GameLibraryItem, parent: SCNNode) {
        guard let caseStage = PS2CaseStage(card: card, game: game, parent: parent)
                ?? PS2CaseStage(bareDiscCard: card, game: game, parent: parent) else { return nil }
        self.caseStage = caseStage
        let console = PS2StageAssets.console?.clone()
        self.console = console
        tray = console?.childNode(withName: "DISC_TRAY", recursively: true)
        trayRest = tray?.simdPosition ?? .zero
        trayAnchor = console?.childNode(withName: "TRAY_DISC_ANCHOR", recursively: true)
        door = console?.childNode(withName: "MC_DOOR_1", recursively: true)
        slot = console?.childNode(withName: "SLOT_MC_1", recursively: true)
        if let console {
            consoleRoot.addChildNode(console)
            powerMaterials = Self.bindMaterials(console.childNode(withName: "LED_POWER", recursively: true))
            ejectMaterials = Self.bindMaterials(console.childNode(withName: "LED_EJECT", recursively: true))
            // The 1.6 mm lenses are only a few pixels here; an additive halo makes their colour readable.
            // Lens centres in console space, as PS2GameView uses them.
            Self.addGlow(powerGlow, to: console.childNode(withName: "BTN_RESET", recursively: true),
                         at: SIMD3(0.1404, 0.0717, 0.0912), in: console)
            Self.addGlow(ejectGlow, to: console.childNode(withName: "BTN_EJECT", recursively: true),
                         at: SIMD3(0.1402, 0.0422, 0.0912), in: console)
        }
        consoleRoot.name = "DUO_PS2_INSERTION_CONSOLE"
        consoleRoot.isHidden = true
        parent.addChildNode(consoleRoot)
        setPowerLight(.standby)
    }

    /// The pose that puts the console's body on `rect` (view points) as the game screen shows it:
    /// seen from 13° above and 16° to the left, like PS2RuntimeModel's camera.
    func entryPose(fitting rect: CGRect, in view: SCNView, unitsPerPoint: Float) -> EntryPose? {
        guard let body = console?.childNode(withName: "BODY", recursively: true) else { return nil }
        let saved = (consoleRoot.simdPosition, consoleRoot.simdOrientation, consoleRoot.simdScale)
        defer {
            consoleRoot.simdPosition = saved.0
            consoleRoot.simdOrientation = saved.1
            consoleRoot.simdScale = saved.2
        }
        let orientation = simd_quatf(angle: 13 * .pi / 180, axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: 16 * .pi / 180, axis: SIMD3(0, 1, 0))
        var scale = saved.2.x
        var centre = saved.0 + saved.1.act(Self.visualCentre) * scale
        func apply() {
            consoleRoot.simdOrientation = orientation
            consoleRoot.simdScale = SIMD3(repeating: scale)
            consoleRoot.simdPosition = centre - orientation.act(Self.visualCentre) * scale
        }
        func projected() -> CGRect {
            let (a, b) = body.boundingBox
            var r = CGRect.null
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = view.projectPoint(SCNVector3(body.simdConvertPosition(SIMD3(x, y, z), to: nil)))
                r = r.union(CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0))
            } } }
            return r
        }
        for _ in 0..<3 {
            apply()
            let r = projected()
            guard !r.isNull, r.width > 1 else { return nil }
            scale *= Float(rect.width / r.width)
            apply()
            let moved = projected()
            centre.x += Float(rect.midX - moved.midX) * unitsPerPoint
            centre.y -= Float(rect.midY - moved.midY) * unitsPerPoint
        }
        return EntryPose(centre: centre, orientation: orientation, scale: scale)
    }

    func remove() {
        blinkTask?.cancel()
        caseStage.remove()
        consoleRoot.removeFromParentNode()
    }

    // MARK: Layout

    /// Poses the selected case `card` (whose carousel pose the caller has just set: that is the
    /// closed pose this blends from), the console, the disc and the memory card.
    func layout(card: SCNNode, frame f: Frame) {
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let caseUnits = CartridgeSceneFactory.ps2CaseUnitsPerMetre
        if !caseStage.isBare { holderClicks.update(pull: f.pull) }
        let approach = min(f.pull / 0.68, 1)
        let entry = max(0, (f.pull - 0.68) / 0.32)
        let lift = smooth(0, 1, approach)

        // Case: hinges, then the book-like open pose facing the camera, fitted to the width.
        // (Bare-disc mode: the card keeps its Cover Flow pose; only its disc travels.)
        if !caseStage.isBare {
        let spine = smooth(0, 0.62, f.open)
        let lidOpen = smooth(0.3, 1, f.open)
        caseStage.setHinges(spine: spine, lid: lidOpen)
        let fitUnits = min(f.width * 0.94 / 0.284, f.fullHeight * 0.40 / 0.19)
        let presentedUnits = fitUnits * (1 - 0.14 * lift)
        let openY = f.shelfY + f.fullHeight * 0.03
        let pulledY = f.cameraY + f.fullHeight * 0.5 - 0.19 * presentedUnits * 0.5 - f.fullHeight * 0.07
        let closedPosition = card.simdPosition
        let closedScale = card.scale.x
        let scale = mix(closedScale, presentedUnits / caseUnits, f.open)
        let centreShift = -PS2CaseStage.openCentreShift(spine: spine, lid: lidOpen) * caseUnits * scale
        card.simdPosition = SIMD3(mix(closedPosition.x, 0, f.open) + centreShift,
                                  mix(closedPosition.y, mix(openY, pulledY, lift), f.open),
                                  closedPosition.z)
        card.scale = SCNVector3(scale, scale, scale)
        // A slight three-quarter turn while the lid swings, so the orthographic camera sees it move.
        let swing = sin(.pi * f.open)
        card.eulerAngles = SCNVector3(-0.10 * swing, 0.28 * swing, 0)
        card.opacity = 1
        card.isHidden = false
        }

        // Console: rises from below like the PSP, tilted so the tray and top face the camera.
        let consoleUnits = min(f.width * 0.88 / 0.301, f.fullHeight * 0.40 / 0.25)
        let orientation = simd_quatf(angle: Self.consoleTilt, axis: SIMD3(1, 0, 0))
        let visualCentre = Self.visualCentre
        let restingY = f.cameraY - f.fullHeight * 0.5 + 0.25 * consoleUnits * 0.5 + f.fullHeight * 0.06
        let hiddenY = f.cameraY - f.fullHeight * 0.5 - 0.22 * consoleUnits
        let centre = SIMD3<Float>(0, mix(hiddenY, restingY, approach), 0.3)
        consoleRoot.isHidden = f.pull <= 0
        consoleRoot.simdOrientation = orientation
        consoleRoot.simdScale = SIMD3(repeating: consoleUnits)
        consoleRoot.simdPosition = centre - orientation.act(visualCentre) * consoleUnits
        if let move = self.entry {
            // One continuous move: the console turns to the game camera's angle and shrinks onto
            // its spot between the TV and the controller while the case lifts away.
            let t = move.progress // already eased by the animation curve
            let movedCentre = centre + (move.pose.centre - centre) * t
            let turned = simd_slerp(orientation, move.pose.orientation, t)
            let scale = mix(consoleUnits, move.pose.scale, t)
            consoleRoot.simdOrientation = turned
            consoleRoot.simdScale = SIMD3(repeating: scale)
            consoleRoot.simdPosition = movedCentre - turned.act(visualCentre) * scale
            let away = caseStage.isBare ? 0 : smooth(0, 0.75, move.progress)
            card.simdPosition.y += away * f.fullHeight * 0.85
            card.opacity = CGFloat(1 - away)
        }
        let trayTravel = f.tray ?? (target == .disc ? smooth(0.08, 0.7, f.pull) : 0)
        if f.tray == nil, target == .disc {
            // The motor starts as soon as the tray begins to follow the disc.
            if f.pull > 0.08, !trayEjectAnnounced {
                trayEjectAnnounced = true
                PS2Feedback.shared.playTrayEject()
            } else if f.pull <= 0 {
                trayEjectAnnounced = false
            }
        }
        tray?.simdPosition = trayRest + SIMD3(0, 0, Self.trayTravel * trayTravel)
        // The slot door must be open before the card reaches the slot (contract).
        let doorOpening = target == .memoryCard ? smooth(0.3, 0.62, f.pull) : 0
        door?.eulerAngles.x = .pi / 2 * doorOpening
        announceDoor(doorOpening)

        // Disc and card: rest in the case, or travel case → above the tray / in front of the slot → seated.
        let discRest = caseStage.discRestTransform
        let cardRest = caseStage.memoryCardRestTransform
        let travelLift = sin(.pi * approach) * 0.08 * consoleUnits
        if target == .disc, f.pull > 0, let anchor = trayAnchor?.simdWorldTransform {
            let above = anchor * simd_float4x4(translation: SIMD3(0, 0.05, 0))
            var pose = approach < 1 ? PS2Pose.blend(discRest, above, lift) : PS2Pose.blend(above, anchor, entry)
            pose.columns.3.z += travelLift
            caseStage.disc.simdTransform = pose
        } else if let discReturn {
            caseStage.disc.simdTransform = PS2Pose.blend(discReturn.start, discRest, discReturn.progress)
        } else {
            caseStage.disc.simdTransform = discRest
        }
        if target == .memoryCard, f.pull > 0, let seated = slot?.simdWorldTransform {
            let front = seated * simd_float4x4(translation: SIMD3(0, 0, 0.07))
            var pose = approach < 1 ? PS2Pose.blend(cardRest, front, lift) : PS2Pose.blend(front, seated, entry)
            pose.columns.3.z += travelLift
            caseStage.memoryCard.simdTransform = pose
        } else {
            caseStage.memoryCard.simdTransform = cardRest
        }
    }

    /// The slot door clicks open as it starts to swing, and shut (reversed) once it clearly swings
    /// back; the hysteresis keeps a jittery drag from repeating either sound.
    private func announceDoor(_ opening: Float) {
        if doorAnnouncedOpen {
            doorExtreme = max(doorExtreme, opening)
            guard opening <= 0.001 || opening < doorExtreme - 0.15 else { return }
            doorAnnouncedOpen = false
            doorExtreme = opening
            PS2Feedback.shared.playSlotDoor(open: false)
        } else {
            doorExtreme = min(doorExtreme, opening)
            guard opening > doorExtreme + (doorExtreme <= 0.001 ? 0.01 : 0.15) else { return }
            doorAnnouncedOpen = true
            doorExtreme = opening
            PS2Feedback.shared.playSlotDoor(open: true)
        }
    }

    /// A pull let go before the latch: the disc falls back into the case and an ejected tray
    /// retracts with it (the card's door closes by itself through `announceDoor`).
    func pullReleased() {
        PS2Feedback.shared.stopTray()
        if target == .disc, trayEjectAnnounced { PS2Feedback.shared.playTrayRetract() }
    }

    // MARK: Lights

    func setPowerLight(_ light: PowerLight) {
        let color: UIColor? = switch light {
        case .off: nil
        case .standby: Self.red
        case .on: Self.green
        }
        Self.paint(powerMaterials, glow: powerGlow, color: color)
    }

    func setEjectLight(_ on: Bool) {
        blinkTask?.cancel()
        Self.paint(ejectMaterials, glow: ejectGlow, color: on ? Self.blue : nil)
    }

    /// Blue disc-reading blink, then `completion`.
    func blinkEject(duration: TimeInterval, completion: @escaping () -> Void) {
        blinkTask?.cancel()
        blinkTask = Task { @MainActor [weak self] in
            let end = Date().addingTimeInterval(duration)
            var lit = true
            while Date() < end {
                guard let self, !Task.isCancelled else { return }
                Self.paint(self.ejectMaterials, glow: self.ejectGlow, color: lit ? Self.blue : nil)
                lit.toggle()
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, !Task.isCancelled else { return }
            Self.paint(self.ejectMaterials, glow: self.ejectGlow, color: nil)
            completion()
        }
    }

    private static func bindMaterials(_ node: SCNNode?) -> [SCNMaterial] {
        guard let node else { return [] }
        var materials: [SCNMaterial] = []
        node.enumerateHierarchy { candidate, _ in
            guard let geometry = candidate.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            candidate.geometry = geometry
            materials.append(contentsOf: geometry.materials)
        }
        return materials
    }

    private static func paint(_ materials: [SCNMaterial], glow: SCNNode, color: UIColor?) {
        for material in materials {
            material.emission.contents = color ?? UIColor.black
            material.emission.intensity = color == nil ? 0 : 2
            if let color { material.diffuse.contents = color }
        }
        glow.isHidden = color == nil
        glow.geometry?.firstMaterial?.multiply.contents = color ?? UIColor.clear
    }

    private static let glowImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
        let colors = [UIColor(white: 1, alpha: 1), UIColor(white: 1, alpha: 0.5), UIColor(white: 1, alpha: 0)]
            .map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                        locations: [0, 0.2, 1]) else { return }
        let c = CGPoint(x: 32, y: 32)
        context.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: 32, options: [])
    }

    private static func addGlow(_ node: SCNNode, to parent: SCNNode?, at position: SIMD3<Float>, in console: SCNNode) {
        guard let parent else { return }
        let plane = SCNPlane(width: 0.012, height: 0.012)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = glowImage
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false   // the lens sits in a recess; draw its halo over the rim
        plane.materials = [material]
        node.geometry = plane
        node.renderingOrder = 10
        node.isHidden = true
        node.simdPosition = parent.simdConvertPosition(position, from: console) + SIMD3(0, 0, 0.002)
        parent.addChildNode(node)
    }

    // MARK: Save browser

    /// Presents the game's memory card page full screen with a cross-fade; `onClose` runs after
    /// it has faded out.
    static func presentSaveBrowser(for game: GameLibraryItem, from view: UIView, onClose: @escaping () -> Void) {
        guard var presenter = view.window?.rootViewController else { onClose(); return }
        while let next = presenter.presentedViewController { presenter = next }
        let card = PS2MemoryCard(root: GameLibraryStore.ps2MemoryCardRoot(for: game))
        weak var weakHost: UIViewController?
        let browser = PS2SaveBrowserView(card: card, gameTitle: game.title) {
            guard let host = weakHost else { onClose(); return }
            host.dismiss(animated: true, completion: onClose)
        }
        let host = UIHostingController(rootView: browser)
        weakHost = host
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        presenter.present(host, animated: true)
    }
}

// MARK: - Carousel state machine (PS2 branch)

extension DragCartridgeSceneView.Coordinator {
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private var selectedPS2Game: GameLibraryItem? {
        guard owner.games.indices.contains(selection), owner.games[selection].platform == .ps2 else { return nil }
        return owner.games[selection]
    }

    /// Tap: the selected closed case opens; tapping the open case's lid closes it.
    @objc func tapPS2Case(_ gesture: UITapGestureRecognizer) {
        guard let view, selectedPS2Game != nil, gesture.state == .ended else { return }
        let point = gesture.location(in: view)
        switch mode {
        case .idle:
            if owner.allowsInsertion, !cards.isEmpty, pointHitsSelectedCard(point, in: view) { openPS2Case() }
        case .caseOpen:
            if ps2?.caseStage.target(at: point, in: view) == .lid { closePS2Case() }
        default:
            break
        }
    }

    func openPS2Case(completion: (() -> Void)? = nil) {
        guard mode == .idle, let game = selectedPS2Game, cards.indices.contains(selection),
              !CartridgeSceneFactory.isBarePS2Disc(cards[selection]) else { return }
        if ps2 == nil {
            ps2 = PS2InsertionStage(card: cards[selection], game: game, parent: scene.rootNode)
        }
        guard ps2 != nil else { return }
        mode = .caseOpening
        PS2Feedback.shared.prepare()
        PS2Feedback.shared.playCaseOpen()
        let start = ps2Open
        animate(duration: reduceMotion ? 0.2 : 0.6, update: { t in
            self.ps2Open = self.mix(start, 1, t)
            self.layout()
        }, completion: {
            self.ps2Open = 1
            self.mode = .caseOpen
            self.layout()
            completion?()
        })
    }

    /// Closes the open case; `step` (±1) then scrolls to the neighbouring game.
    func closePS2Case(thenStep step: Int? = nil) {
        guard mode == .caseOpen, ps2 != nil else { return }
        mode = .caseClosing
        PS2Feedback.shared.prepare()
        animate(duration: reduceMotion ? 0.2 : 0.5, update: { t in
            self.ps2Open = 1 - t
            self.layout()
        }, completion: {
            PS2Feedback.shared.playCaseClose()
            self.finishPS2Close()
            if let step, self.owner.allowsSelection, !self.cards.isEmpty {
                let target = self.isCircular ? self.wrappedIndex(self.selection + step)
                    : min(max(self.selection + step, 0), self.cards.count - 1)
                if target != self.selection { self.settleSelection(to: target) }
            }
        })
    }

    private func finishPS2Close() {
        ps2?.remove()
        ps2 = nil
        ps2Open = 0
        ps2Tray = nil
        pull = 0
        mode = .idle
        layout()
    }

    /// Vertical drag in the PS2 branch. On a closed case it opens it; on an open case it starts
    /// pulling the disc or memory card under the finger. True when a pull started.
    func beginPS2Pull(from point: CGPoint, in view: SCNView) -> Bool {
        if mode == .idle, beginBarePS2Stage(), let ps2 {
            // Bare disc: straight into the pull, no case to open.
            ps2.target = .disc
            PS2Feedback.shared.prepare()
            mode = .pull
            return true
        }
        if mode == .idle { openPS2Case(); return false }
        guard mode == .caseOpen, let ps2, let target = ps2.caseStage.pullTarget(at: point, in: view) else { return false }
        ps2.target = target
        PS2Feedback.shared.prepare()
        mode = .pull
        return true
    }

    /// Latched: the disc seats on the tray and the console loads it, or the card seats in slot 1
    /// and the save page opens.
    func completePS2Latch() {
        guard mode == .latching, let ps2, let game = selectedPS2Game else { return }
        pull = 1
        layout()
        switch ps2.target {
        case .disc:
            mode = .opening
            PS2Feedback.shared.playDiscLatch()
            ps2Tray = 1
            PS2Feedback.shared.playTrayRetract()
            animate(duration: reduceMotion ? 0.3 : 0.9, update: { t in
                self.ps2Tray = 1 - t
                self.layout()
            }, completion: {
                self.ps2Tray = 0
                self.layout()
                ps2.setPowerLight(.on)
                ps2.blinkEject(duration: self.reduceMotion ? 0.4 : 1.2) {
                    guard self.mode == .opening else { return }
                    self.mode = .finished
                    self.owner.onInserted(game)
                    self.enterPS2Game(stage: ps2)
                }
            })
        case .memoryCard:
            mode = .browsing
            PS2Feedback.shared.playMemoryCardInsert()
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.3)) {
                guard self.mode == .browsing, let view = self.view else { return }
                PS2InsertionStage.presentSaveBrowser(for: game, from: view) { self.withdrawPS2MemoryCard() }
            }
        }
    }

    /// Save page closed: the card leaves the slot, the door closes, the console sinks and the
    /// card drops back into the case holder.
    func withdrawPS2MemoryCard() {
        guard mode == .browsing else { return }
        mode = .returning
        PS2Feedback.shared.prepare()
        PS2Feedback.shared.playMemoryCardWithdraw()
        animate(duration: reduceMotion ? 0.3 : 0.8, update: { t in
            self.pull = 1 - t
            self.layout()
        }, completion: {
            self.pull = 0
            self.mode = .caseOpen
            self.layout()
        })
    }

    /// Leaving the game. Normally the game screen has already switched off and flown the disc up to
    /// the camera (`PS2RuntimeModel.playExit`); the view then pans up with it into the open case
    /// and the lid snaps shut. Reduce Motion: the case appears with the disc inside and closes.
    /// Without a game-screen handoff: the library's own console ejects the disc (basic reverse).
    func reversePS2Insertion() {
        guard mode == .finished, let ps2 else { return }
        if let runtime = PS2RuntimeModel.active, runtime.exitReady {
            if !reduceMotion, let view, let handoff = runtime.makeExitHandoff(), let pose = handoff.discPose {
                panPS2Exit(handoff: handoff, pose: pose, stage: ps2, in: view)
            } else {
                closePS2CaseAfterExit(stage: ps2)
            }
            return
        }
        mode = .closing
        pull = 1
        ps2Open = 1
        ps2Tray = 0
        layout()
        PS2Feedback.shared.prepare()
        PS2Feedback.shared.playTrayEject()
        ps2.setEjectLight(true)
        animate(duration: reduceMotion ? 0.3 : 0.9, update: { t in
            self.ps2Tray = t
            self.layout()
        }, completion: {
            ps2.setEjectLight(false)
            self.ps2Tray = nil
            self.mode = .ejecting
            // The disc lifts off the tray, which then follows it back in (from pull 0.7).
            PS2Feedback.shared.playDiscLift()
            var retracting = false
            self.animate(duration: self.reduceMotion ? 0.35 : 1.0, update: { t in
                self.pull = 1 - t
                if !retracting, self.pull < 0.7 {
                    retracting = true
                    PS2Feedback.shared.playTrayRetract()
                }
                self.layout()
            }, completion: {
                self.pull = 0
                self.mode = .caseClosing
                self.animate(duration: self.reduceMotion ? 0.2 : 0.5, update: { t in
                    self.ps2Open = 1 - t
                    self.layout()
                }, completion: {
                    PS2Feedback.shared.playCaseClose()
                    self.returnPS2ToCoverFlow()
                })
            })
        })
    }

    /// Into the game in one shot: the game screen is set up underneath (console, TV and controller
    /// hidden), the library turns transparent over it, and the console turns and shrinks onto the
    /// game screen's console while the case lifts away and the TV and controller fade in. Then
    /// the game's own console takes over in the same frame.
    private func enterPS2Game(stage ps2: PS2InsertionStage) {
        guard !reduceMotion, let view else { owner.onFinished(); return }
        var attempts = 0
        func begin() {
            // The game screen needs a layout pass before its console rect is known.
            guard let model = PS2RuntimeModel.active, let rect = model.consoleWindowRect, rect.width > 1 else {
                attempts += 1
                if attempts < 90 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: begin)
                } else {
                    owner.onFinished()
                }
                return
            }
            let unitsPerPoint = fullHeight / Float(max(1, view.bounds.height))
            guard let pose = ps2.entryPose(fitting: view.convert(rect, from: nil), in: view, unitsPerPoint: unitsPerPoint) else {
                owner.onFinished()
                return
            }
            model.beginEntry()
            // One frame for the hidden game state to render before the library turns transparent.
            DispatchQueue.main.async {
                view.backgroundColor = .clear
                view.isOpaque = false
                ps2.entry = (pose, 0)
                self.layout()
                var revealed = false
                self.animate(duration: 1.4, update: { t in
                    ps2.entry = (pose, t)
                    model.setEntryBackdrop(progress: CGFloat(t))
                    if t > 0.45, !revealed {
                        revealed = true
                        model.revealForeground()
                    }
                    self.layout()
                }, completion: {
                    model.finishEntry()
                    DispatchQueue.main.async {
                        self.owner.onFinished()
                        // Opaque again once the library has faded out over the game.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            ps2.entry = nil
                            view.backgroundColor = .black
                            view.isOpaque = true
                            self.layout()
                        }
                    }
                })
            }
        }
        begin()
    }

    /// The camera pans up by one screen height with the disc, which starts exactly where the game
    /// screen showed it and settles on the case's disc anchor; the game view pans in step below.
    private func panPS2Exit(handoff: PS2ExitHandoff, pose: PS2ExitDiscPose, stage ps2: PS2InsertionStage, in view: SCNView) {
        mode = .closing
        pull = 0
        ps2Open = 1
        ps2Tray = nil
        ps2StageVisibility = 0
        layout()
        let size = view.bounds.size
        let unitsPerPoint = fullHeight / Float(size.height)
        let baseY = cameraNode.position.y
        let drop = Float(size.height) * unitsPerPoint
        cameraNode.position.y = baseY - drop
        // The library draws over the still-running game view until the pan has moved it away.
        view.backgroundColor = .clear
        view.isOpaque = false
        let center = view.convert(pose.windowCenter, from: nil)
        let rest = ps2.caseStage.discRestTransform
        let position = SIMD3<Float>(cameraNode.position.x + Float(center.x - size.width / 2) * unitsPerPoint,
                                    cameraNode.position.y - Float(center.y - size.height / 2) * unitsPerPoint,
                                    rest.columns.3.z + 3)
        let start = PS2Pose.compose(position, pose.rotation, Float(pose.pointsPerUnit) * unitsPerPoint)
        ps2.discReturn = (start, 0)
        layout()
        // Show the library once it has drawn the disc in place, and retire the game's disc in the
        // same frame (overlapping, the two transparent hubs would flash).
        view.alpha = 0
        let points = size.height
        PS2Feedback.shared.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            view.alpha = 1
            handoff.disc?.isHidden = true
            self.animate(duration: 1.05, update: { t in
                self.cameraNode.position.y = baseY - drop * (1 - t)
                handoff.model.setExitPan(points: points * CGFloat(t), fade: CGFloat(t))
                // The disc's start moves with the camera, so on screen it holds still and then
                // travels straight up into the case (a world-fixed start slid down with the pan
                // first: down, up, down instead of one move).
                let following = simd_float4x4(translation: SIMD3(0, drop * t, 0)) * start
                ps2.discReturn = (following, self.smoothstep(0, 0.82, t))
                self.layout()
            }, completion: {
                self.cameraNode.position.y = baseY
                ps2.discReturn = nil
                view.backgroundColor = .black
                view.isOpaque = true
                self.layout()
                self.closePS2CaseAfterExit(stage: ps2, delay: 0.08)
            })
        }
    }

    /// The open case (disc inside) closes — lid, then spine — and returns to its Cover Flow pose.
    private func closePS2CaseAfterExit(stage ps2: PS2InsertionStage, delay: TimeInterval? = nil) {
        mode = .caseClosing
        pull = 0
        ps2Open = 1
        ps2Tray = nil
        ps2StageVisibility = 0
        layout()
        PS2Feedback.shared.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? 0.3)) {
            self.animate(duration: self.reduceMotion ? 0.25 : 0.55, update: { t in
                self.ps2Open = 1 - t
                self.ps2StageVisibility = t
                self.layout()
            }, completion: {
                PS2Feedback.shared.playCaseClose()
                self.returnPS2ToCoverFlow()
            })
        }
    }

    /// Every PS2 exit path ends here: the case is closed and Cover Flow is idle again (so a
    /// horizontal drag scrolls and a still hold may import) before the app leaves the game.
    private func returnPS2ToCoverFlow() {
        ps2StageVisibility = nil
        finishPS2Close()
        opening = 0
        scroll = Float(selection)
        layout()
        #if DEBUG
        let idle = mode == .idle && pull == 0 && ps2Open == 0 && ps2 == nil && displayLink == nil
        NSLog("DUO_PS2_RETURN %@ mode=%@ pull=%.2f open=%.2f selection=%d", idle ? "idle" : "NOT_IDLE",
              String(describing: mode), pull, ps2Open, selection)
        #endif
        owner.onReturned()
    }

    // MARK: Accessibility

    func accessibleInsertPS2(_ target: PS2PullTarget) -> Bool {
        guard owner.allowsInsertion, selectedPS2Game != nil else { return false }
        func pull() {
            guard mode == .caseOpen, let ps2 else { return }
            ps2.target = target
            mode = .pull
            animate(duration: 0.48, update: { self.pull = $0 * 0.90; self.layout() },
                    completion: { self.snapIntoLatch() })
        }
        switch mode {
        case .idle:
            if target == .disc, beginBarePS2Stage() { pull(); return true }
            if cards.indices.contains(selection), CartridgeSceneFactory.isBarePS2Disc(cards[selection]) { return false }
            openPS2Case(completion: pull)
            return true
        case .caseOpen: pull(); return true
        default: return false
        }
    }

    @objc func accessibleInsertPS2MemoryCard() -> Bool { accessibleInsertPS2(.memoryCard) }

    @objc func accessibleTogglePS2Case() -> Bool {
        guard selectedPS2Game != nil else { return false }
        switch mode {
        case .idle: openPS2Case(); return true
        case .caseOpen: closePS2Case(); return true
        default: return false
        }
    }
}

#if DEBUG
// MARK: - Self-test

extension DragCartridgeSceneView.Coordinator {
    /// `-ps2-hittest-selftest`: inserts up to three PS2 games in turn through the real insertion
    /// path. Each game screen logs what a touch on its console reaches (`DUO_PS2_HITTEST_…`) and
    /// exits; the next game follows once Cover Flow is idle again.
    /// `-ps2-autoplay N` instead inserts only the N-th PS2 game and stays in it (screenshots);
    /// with `-ps2-autoplay-card` it inserts that game's memory card (save browser).
    func runPS2HitTestSelfTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let games = owner.games.indices.filter { owner.games[$0].platform == .ps2 }
        if let i = arguments.firstIndex(of: "-ps2-autoplay"), arguments.indices.contains(i + 1),
           let n = Int(arguments[i + 1]), games.indices.contains(n) {
            settleSelection(to: games[n]) {
                let target: PS2PullTarget = arguments.contains("-ps2-autoplay-card") ? .memoryCard : .disc
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = self.accessibleInsertPS2(target) }
            }
            return
        }
        guard arguments.contains("-ps2-hittest-selftest") else { return }
        runPS2HitTestStep(Array(games.prefix(3)))
    }

    private func runPS2HitTestStep(_ queue: [Int]) {
        guard let index = queue.first else { NSLog("DUO_PS2_HITTEST_DONE"); return }
        settleSelection(to: index) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard self.accessibleInsertPS2(.disc) else {
                    NSLog("DUO_PS2_HITTEST_FAIL could not insert index=%d mode=%@", index, String(describing: self.mode))
                    return
                }
                self.waitForPS2Return(sawGame: false) { self.runPS2HitTestStep(Array(queue.dropFirst())) }
            }
        }
    }

    private func waitForPS2Return(sawGame: Bool, then next: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let saw = sawGame || self.mode == .finished
            guard saw, self.mode == .idle, !self.owner.isExiting else {
                self.waitForPS2Return(sawGame: saw, then: next)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: next)
        }
    }
}
#endif
