import SceneKit
import UIKit

// MARK: - Case kinds and assets

/// The retail case a library game is shown in. nil (tutorial cards, N64, PS2, or the
/// "不显示卡带盒" setting) keeps the bare cartridge / UMD card and the original insertion.
enum HandheldCaseKind {
    case nds, threeDS, psp

    init?(game: GameLibraryItem) {
        guard game.url.scheme != "duo-tutorial", !HandheldCaseSettings.casesHidden else { return nil }
        switch game.platform {
        case .nds: self = .nds
        case .threeDS: self = .threeDS
        case .psp: self = .psp
        default: return nil
        }
    }

    var resource: String {
        switch self {
        case .nds: "NDS-Case"
        case .threeDS: "3DS-Case"
        case .psp: "PSP-UMD-Case"
        }
    }

    /// Units per metre of the library medium model: DS / 3DS cards are millimetres, the UMD
    /// assembly is authored in metres and shown at 700× (`CartridgeSceneFactory.umdScene`).
    var mediumUnitsPerMetre: Float { self == .psp ? 700 : 1000 }
}

/// The three case assets (`Handheld_Cases/CONTRACT.md`), loaded once and cloned per game.
/// Everything is found by name and measured from the loaded file, so the stand-ins (copies of
/// `PS2-Case.usdz`) and the real models work alike.
enum HandheldCaseAssets {
    static let rootNames = ["NDS_CASE", "CTR_CASE", "UMD_CASE", "PS2_CASE"]
    static let anchorNames = ["CASE_MEDIUM_ANCHOR", "CASE_DISC_ANCHOR"]
    /// Carousel units per metre of a case: as the PS2 case (a 190 mm case is 47 units tall), and
    /// never taller than `maximumShelfHeight` units so a case clears the text under the shelf.
    static func caseUnitsPerMetre(height: Float) -> Float {
        min(CartridgeSceneFactory.ps2CaseUnitsPerMetre, maximumShelfHeight / max(height, 0.001))
    }
    static let maximumShelfHeight: Float = 47

    struct Template {
        let root: SCNNode
        /// Closed case bounding box in metres (root space).
        let min: SIMD3<Float>
        let max: SIMD3<Float>
        var size: SIMD3<Float> { max - min }
        var centre: SIMD3<Float> { (min + max) / 2 }
    }

    private static let nds = load(.nds)
    private static let threeDS = load(.threeDS)
    private static let psp = load(.psp)

    static func template(_ kind: HandheldCaseKind) -> Template? {
        switch kind {
        case .nds: nds
        case .threeDS: threeDS
        case .psp: psp
        }
    }

    private static func load(_ kind: HandheldCaseKind) -> Template? {
        guard let url = Bundle.main.url(forResource: kind.resource, withExtension: "usdz"),
              let scene = try? SCNScene(url: url) else { return nil }
        var found: SCNNode?
        for name in rootNames {
            if let node = scene.rootNode.childNode(withName: name, recursively: true) { found = node; break }
        }
        guard let root = found else { return nil }
        root.enumerateHierarchy { node, _ in node.removeAllAnimations() }
        root.simdTransform = matrix_identity_float4x4
        let (a, b) = root.boundingBox
        let lo = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
        let hi = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
        guard hi.x > lo.x, hi.y > lo.y, hi.z > lo.z else { return nil }
        return Template(root: root, min: lo, max: hi)
    }

    /// The closed case, centred on its bounding box and scaled to carousel units, wrapped in a
    /// `HandheldCaseStage.wrapperName` node; `medium` (a library `cartridgeModel`) rests in its holder.
    /// `reviewSafe`: an App Review test game (`ReviewSafeGames`); the moulded brand prints are hidden.
    static func makeCase(_ kind: HandheldCaseKind, insert: UIImage, medium: SCNNode?, reviewSafe: Bool = false) -> SCNNode? {
        guard let template = template(kind) else { return nil }
        let root = template.root.clone()
        let wrapper = SCNNode()
        wrapper.name = HandheldCaseStage.wrapperName
        let units = caseUnitsPerMetre(height: template.size.y)
        wrapper.simdScale = SIMD3(repeating: units)
        wrapper.simdPosition = -template.centre * units
        wrapper.addChildNode(root)
        CartridgeSceneFactory.applyPS2CoverInsert(insert, to: root)
        // The insert's unprinted reverse (seen through the open clear UMD case) is off-white paper;
        // pure white blows out under the stage lights.
        root.enumerateHierarchy { node, _ in
            guard node.name?.hasPrefix("INSERT_REVERSE") == true, let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.map { original in
                let material = original.copy() as! SCNMaterial
                material.diffuse.contents = UIColor(white: 0.74, alpha: 1)
                material.roughness.contents = 0.85
                return material
            }
            node.geometry = geometry
        }
        if reviewSafe { ReviewSafeScene.hideTrademarkNodes(in: root) }
        if root.name == "PS2_CASE" {
            // Stand-in asset: its PlayStation prints do not belong on a Nintendo / PSP case.
            root.enumerateHierarchy { node, _ in
                if node.name?.hasPrefix("TRADEMARK_PRINTS") == true { node.isHidden = true }
            }
        }
        guard let medium else { return wrapper }
        var anchor: SCNNode?
        for name in anchorNames {
            if let node = root.childNode(withName: name, recursively: true) { anchor = node; break }
        }
        let holder = SCNNode()
        holder.name = HandheldCaseStage.holderName
        if let anchor {
            anchor.addChildNode(holder)
            if anchor.name != "CASE_MEDIUM_ANCHOR" {
                // `CASE_DISC_ANCHOR` (PS2 stand-in) is the DVD's frame (its +Y is the disc normal).
                // Keep only its position and lay the medium flat on the tray, label up (+Z).
                let inRoot = anchor.simdConvertTransform(matrix_identity_float4x4, to: root)
                let rotation = simd_float3x3(
                    simd_normalize(SIMD3(inRoot.columns.0.x, inRoot.columns.0.y, inRoot.columns.0.z)),
                    simd_normalize(SIMD3(inRoot.columns.1.x, inRoot.columns.1.y, inRoot.columns.1.z)),
                    simd_normalize(SIMD3(inRoot.columns.2.x, inRoot.columns.2.y, inRoot.columns.2.z)))
                holder.simdOrientation = simd_quatf(rotation.transpose)
            }
        } else {
            // No anchor at all: the centre of the tray, just above its floor.
            holder.simdPosition = SIMD3(template.centre.x + template.size.x * 0.1, template.centre.y, 0)
            root.addChildNode(holder)
        }
        medium.name = HandheldCaseStage.mediumName
        medium.eulerAngles = SCNVector3Zero
        medium.opacity = 1
        // Hidden while the case is closed on the shelf: it cannot be seen through the lid (its
        // depth-less title plate would print through it) and it keeps Cover Flow's draw calls down.
        medium.isHidden = true
        // The anchor is the centre of the medium's body (contract): a card's origin is its label
        // plane, 1.9 mm above the body centre; the UMD's origin is its disc centre. The stand-in
        // anchor only marks a spot on the tray, so the model's bounds are centred on it.
        let centre: SIMD3<Float>
        if anchor?.name == "CASE_MEDIUM_ANCHOR" {
            centre = kind == .psp ? .zero : SIMD3(0, 0, -1.9)
        } else {
            let (a, b) = medium.boundingBox
            centre = SIMD3<Float>(Float(a.x + b.x), Float(a.y + b.y), Float(a.z + b.z)) / 2
        }
        let s = 1 / kind.mediumUnitsPerMetre
        var rest = matrix_identity_float4x4
        rest.columns.0.x = s
        rest.columns.1.y = s
        rest.columns.2.z = s
        rest.columns.3 = SIMD4(-centre * s, 1)
        medium.simdTransform = rest
        holder.addChildNode(medium)
        return wrapper
    }

    /// Camera and lights for a stand-alone view of the scene (the appearance editor preview).
    static func addPreviewRig(to scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 39
        camera.zNear = 1
        camera.zFar = 300
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 130)
        scene.rootNode.addChildNode(cameraNode)
        let key = SCNLight()
        key.type = .area
        key.intensity = 1_900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-34, 44, 84)
        keyNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(keyNode)
        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 950
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(36, -24, 60)
        scene.rootNode.addChildNode(fillNode)
    }
}

// MARK: - Insert sheet

extension CartridgeSceneFactory {
    private static let handheldInsertCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    /// The case's paper insert, laid out `back | spine | front` as seen from outside (contract UV),
    /// painted by `HandheldCaseInsert` from the game's box art (`caseArt`: GameTDB wrap scan, front,
    /// back); without art, its generated placeholder with the platform banner and title.
    static func handheldInsertTexture(for game: GameLibraryItem) -> UIImage {
        guard let kind = HandheldCaseKind(game: game) ?? fallbackKind(game),
              let template = HandheldCaseAssets.template(kind) else { return UIImage() }
        // App Review test games (`ReviewSafeGames`) get the plain placeholder: no scans (a homebrew
        // product code can match a retail game) and no platform banners.
        let reviewSafe = ReviewSafeGames.isReviewSafe(game)
        let key = "\(game.id)|\(game.appearanceRevision)|\(kind)|\(reviewSafe)" as NSString
        if let cached = handheldInsertCache.object(forKey: key) { return cached }
        let platform: HandheldCasePlatform = switch kind {
        case .nds: .nds
        case .threeDS: .threeDS
        case .psp: .psp
        }
        // The real case's UVs follow the published insert size; a stand-in case (a copy of the
        // PS2 case) maps the sheet over its own bounds.
        let layout = template.root.name == "PS2_CASE"
            ? HandheldCaseInsertLayout(back: CGFloat(template.size.x * 1000), spine: CGFloat(template.size.z * 1000),
                                       front: CGFloat(template.size.x * 1000), height: CGFloat(template.size.y * 1000))
            : HandheldCaseInsertLayout.standard(for: platform)
        let art = reviewSafe ? nil : game.caseArt
        guard let sheet = HandheldCaseInsert.render(
            platform: platform, layout: layout, full: art?.full?.cgImage,
            front: art?.front?.cgImage, back: art?.back?.cgImage,
            title: game.title, subtitle: nil, pixelsPerMM: 6, neutral: reviewSafe) else { return UIImage() }
        let texture = UIImage(cgImage: sheet)
        handheldInsertCache.setObject(texture, forKey: key)
        return texture
    }

    private static func fallbackKind(_ game: GameLibraryItem) -> HandheldCaseKind? {
        switch game.platform {
        case .nds: .nds
        case .threeDS: .threeDS
        case .psp: .psp
        default: nil
        }
    }
}

// MARK: - Stage

/// The handheld case the carousel has opened, generalising `PS2CaseStage` / `PS2InsertionStage`:
/// hinge angles, the open presentation facing the camera, and the medium that rests in its holder.
/// The case is the selected Cover Flow card (`cartridgeModel` → `wrapperName`). While a stage
/// exists its medium is a root-level node: it rests on the case's anchor every layout pass and,
/// once pulled, blends from there into the pose the existing DS/3DS/PSP insertion gives the
/// selected card, reaching it exactly when the approach ends (`pull` 0.68).
@MainActor
final class HandheldCaseStage {
    enum Target { case lid, tray, medium }

    struct Frame {
        var cameraY: Float
        var shelfY: Float
        var fullHeight: Float
        var width: Float
        /// Insertion pull (0 unless the insertion is active).
        var pull: Float
        /// Console opening into gameplay 0…1: the case lifts out of the shot.
        var opening: Float
    }

    static let wrapperName = "DUO_HANDHELD_CASE"
    static let holderName = "DUO_CASE_MEDIUM_HOLDER"
    static let mediumName = "DUO_CASE_MEDIUM"

    let caseNode: SCNNode
    let medium: SCNNode
    /// Closed case size in metres (W, H, T).
    let size: SIMD3<Float>
    /// Presentation: 0 closed in Cover Flow … 1 open facing the camera.
    var open: Float = 0
    private var holderClicks = CaseHolderClicks()
    private let holder: SCNNode
    private let restLocal: simd_float4x4
    private let spine: SCNNode?
    private let lid: SCNNode?

    static func hasCase(_ card: SCNNode) -> Bool {
        card.childNode(withName: wrapperName, recursively: false) != nil
    }

    init?(card: SCNNode, parent: SCNNode) {
        guard let wrapper = card.childNode(withName: Self.wrapperName, recursively: false),
              let medium = wrapper.childNode(withName: Self.mediumName, recursively: true),
              let holder = medium.parent,
              let root = wrapper.childNodes.first else { return nil }
        caseNode = wrapper
        self.medium = medium
        self.holder = holder
        restLocal = medium.simdTransform
        spine = wrapper.childNode(withName: "CASE_SPINE", recursively: true)
        lid = wrapper.childNode(withName: "CASE_LID", recursively: true)
        let world = medium.simdWorldTransform
        medium.removeFromParentNode()
        let (a, b) = root.boundingBox
        size = SIMD3(Float(b.x - a.x), Float(b.y - a.y), Float(b.z - a.z))
        parent.addChildNode(medium)
        medium.simdTransform = world
        medium.isHidden = false
    }

    func setHinges(spine spineProgress: Float, lid lidProgress: Float) {
        spine?.eulerAngles.y = .pi / 2 * spineProgress
        lid?.eulerAngles.y = .pi / 2 * lidProgress
    }

    /// The medium's resting world pose in the holder.
    var mediumRestTransform: simd_float4x4 { holder.simdWorldTransform * restLocal }

    /// Poses the selected case `card` (its Cover Flow pose, just set by the caller, is the closed
    /// pose this blends from) and the medium. `insertion`: the caller has just given the medium
    /// the existing insertion pose for the current `pull`; it is blended in from the holder.
    func layout(card: SCNNode, frame f: Frame, insertion: Bool) {
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let units = HandheldCaseAssets.caseUnitsPerMetre(height: size.y)
        holderClicks.update(pull: f.pull)
        let approach = min(f.pull / 0.68, 1)
        let lift = smooth(0, 1, approach)
        let (w, h, t) = (size.x, size.y, size.z)

        let spineOpen = smooth(0, 0.62, open)
        let lidOpen = smooth(0.3, 1, open)
        setHinges(spine: spineOpen, lid: lidOpen)
        // Open flat (tray | spine | lid) the case is 2W + T wide.
        let fitUnits = min(f.width * 0.94 / (2 * w + t), f.fullHeight * 0.40 / h)
        // While the medium is out the case waits at the top, small enough to clear the console.
        let pulledUnits = min(fitUnits * 0.86, f.fullHeight * 0.27 / h)
        let presentedUnits = mix(fitUnits, pulledUnits, lift)
        let openY = f.shelfY + f.fullHeight * 0.03
        let pulledY = f.cameraY + f.fullHeight * 0.5 - h * presentedUnits * 0.5 - f.fullHeight * 0.05
        let closedPosition = card.simdPosition
        let closedScale = card.scale.x
        let scale = mix(closedScale, presentedUnits / units, open)
        // Centre of the open bounding box: the spine and lid swing out on −X.
        let centreShift = (t / 2 * spineOpen + w / 2 * lidOpen) * units * scale
        card.simdPosition = SIMD3(mix(closedPosition.x, 0, open) + centreShift,
                                  mix(closedPosition.y, mix(openY, pulledY, lift), open),
                                  closedPosition.z)
        card.scale = SCNVector3(scale, scale, scale)
        let swing = sin(.pi * open)
        card.eulerAngles = SCNVector3(-0.10 * swing, 0.28 * swing, 0)
        // Into the game the case slides up out of the shot; on exit it comes back down. (No fade:
        // a translucent case would show its insert through the plastic.)
        let away = smooth(0, 0.55, f.opening)
        card.simdPosition.y += away * f.fullHeight * 0.9
        card.opacity = 1
        card.isHidden = away >= 1

        let rest = mediumRestTransform
        if insertion {
            var pose = PS2Pose.blend(rest, medium.simdTransform, lift)
            // Lift it off the tray toward the camera while it travels.
            pose.columns.3.z += sin(.pi * approach) * 2
            medium.simdTransform = pose
        } else {
            medium.simdTransform = rest
            medium.opacity = 1
        }
        medium.isHidden = false
    }

    /// The front-most case part under `point`.
    func target(at point: CGPoint, in view: SCNView) -> Target? {
        let results = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for result in results {
            var node: SCNNode? = result.node
            while let current = node {
                if current === medium { return .medium }
                if current === lid { return .lid }
                if current === caseNode { return .tray }
                node = current.parent
            }
        }
        return nil
    }

    /// Whether `point` is on the medium or close to it (it is a small touch target).
    func isNearMedium(_ point: CGPoint, in view: SCNView) -> Bool {
        if target(at: point, in: view) == .medium { return true }
        let (a, b) = medium.boundingBox
        let centre = medium.simdConvertPosition(SIMD3(Float(a.x + b.x), Float(a.y + b.y), Float(a.z + b.z)) / 2, to: nil)
        let edge = medium.simdConvertPosition(SIMD3(Float(b.x), Float(a.y + b.y) / 2, Float(a.z + b.z) / 2), to: nil)
        let c = view.projectPoint(SCNVector3(centre))
        let e = view.projectPoint(SCNVector3(edge))
        let radius = max(24, hypot(CGFloat(e.x - c.x), CGFloat(e.y - c.y)) * 1.8)
        return hypot(point.x - CGFloat(c.x), point.y - CGFloat(c.y)) <= radius
    }

    /// Closes the hinges and puts the medium back into the case's holder.
    func remove() {
        setHinges(spine: 0, lid: 0)
        medium.removeFromParentNode()
        medium.opacity = 1
        medium.isHidden = true
        holder.addChildNode(medium)
        medium.simdTransform = restLocal
    }
}

// MARK: - Carousel state machine (handheld case branch)

extension DragCartridgeSceneView.Coordinator {
    private var caseReduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The selected Cover Flow card is a DS / 3DS / PSP retail case.
    var selectedHasHandheldCase: Bool {
        cards.indices.contains(selection) && owner.games.indices.contains(selection)
            && owner.games[selection].platform != .ps2 && HandheldCaseStage.hasCase(cards[selection])
    }

    /// The library's only tap: the selected DS / 3DS / PSP case, else the PS2 case.
    @objc func tapCase(_ gesture: UITapGestureRecognizer) {
        if selectedHasHandheldCase { tapHandheldCase(gesture) } else { tapPS2Case(gesture) }
    }

    /// Tap: the selected closed case opens; on the open case the lid closes it and the medium
    /// is inserted.
    func tapHandheldCase(_ gesture: UITapGestureRecognizer) {
        guard let view, gesture.state == .ended, selectedHasHandheldCase else { return }
        let point = gesture.location(in: view)
        switch mode {
        case .idle:
            if owner.allowsInsertion, pointHitsSelectedCard(point, in: view) { openHandheldCase() }
        case .caseOpen:
            guard let stage = handheldCase else { return }
            if stage.isNearMedium(point, in: view) {
                _ = accessibleInsertHandheld()
            } else if stage.target(at: point, in: view) == .lid {
                closeHandheldCase()
            }
        default:
            break
        }
    }

    func openHandheldCase(completion: (() -> Void)? = nil) {
        guard mode == .idle, selectedHasHandheldCase else { return }
        if handheldCase == nil {
            handheldCase = HandheldCaseStage(card: cards[selection], parent: scene.rootNode)
        }
        guard let stage = handheldCase else { return }
        mode = .caseOpening
        PS2Feedback.shared.prepare()
        PS2Feedback.shared.playCaseOpen()
        CartridgeFeedback.shared.prepare()
        let start = stage.open
        animate(duration: caseReduceMotion ? 0.2 : 0.6, update: { t in
            stage.open = self.mix(start, 1, t)
            self.layout()
        }, completion: {
            stage.open = 1
            self.mode = .caseOpen
            self.layout()
            completion?()
        })
    }

    /// Closes whichever case is open (PS2 or handheld); `step` (±1) then scrolls on.
    func closeOpenCase(thenStep step: Int? = nil) {
        if handheldCase != nil { closeHandheldCase(thenStep: step) } else { closePS2Case(thenStep: step) }
    }

    func closeHandheldCase(thenStep step: Int? = nil, completion: (() -> Void)? = nil) {
        guard mode == .caseOpen || mode == .ejecting, let stage = handheldCase else { return }
        mode = .caseClosing
        PS2Feedback.shared.prepare()
        let start = stage.open
        animate(duration: caseReduceMotion ? 0.2 : 0.5, update: { t in
            stage.open = start * (1 - t)
            self.layout()
        }, completion: {
            PS2Feedback.shared.playCaseClose()
            self.finishHandheldClose()
            completion?()
            if let step, self.owner.allowsSelection, !self.cards.isEmpty {
                let target = self.isCircular ? self.wrappedIndex(self.selection + step)
                    : min(max(self.selection + step, 0), self.cards.count - 1)
                if target != self.selection { self.settleSelection(to: target) }
            }
        })
    }

    func finishHandheldClose() {
        handheldCase?.remove()
        handheldCase = nil
        pull = 0
        mode = .idle
        layout()
    }

    /// Vertical drag on a case: a closed case opens; on an open case the medium is pulled.
    /// True when a pull started.
    func beginHandheldCasePull() -> Bool {
        if mode == .idle { openHandheldCase(); return false }
        guard mode == .caseOpen, handheldCase != nil else { return false }
        CartridgeFeedback.shared.prepare()
        mode = .pull
        return true
    }

    /// Automatic insertion (accessibility, `-cartridge-autoplay`): open, take out, insert.
    func accessibleInsertHandheld() -> Bool {
        guard owner.allowsInsertion, selectedHasHandheldCase else { return false }
        func pull() {
            guard mode == .caseOpen, handheldCase != nil else { return }
            mode = .pull
            animate(duration: 0.62, update: { self.pull = $0 * 0.90; self.layout() },
                    completion: { self.snapIntoLatch() })
        }
        switch mode {
        case .idle:
            openHandheldCase {
                DispatchQueue.main.asyncAfter(deadline: .now() + (self.caseReduceMotion ? 0 : 0.18)) { pull() }
            }
            return true
        case .caseOpen:
            pull()
            return true
        default:
            return false
        }
    }

    @objc func accessibleToggleHandheldCase() -> Bool {
        guard selectedHasHandheldCase else { return false }
        switch mode {
        case .idle: openHandheldCase(); return true
        case .caseOpen: closeHandheldCase(); return true
        default: return false
        }
    }

    /// The "不显示卡带盒" setting changed: rebuild the cards once Cover Flow is idle.
    @objc func handheldCaseSettingsChanged() {
        DispatchQueue.main.async {
            guard HandheldCaseSettings.casesHidden != self.builtCasesHidden, self.owner.isVisible else { return }
            self.reloadIfNeeded()
        }
    }

    #if DEBUG
    /// `-case-game <title>`: the game selected when the cards are built.
    func debugCaseGameIndex() -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-case-game"), arguments.indices.contains(i + 1) else { return nil }
        let title = arguments[i + 1]
        return owner.games.firstIndex { $0.title.localizedCaseInsensitiveContains(title) }
    }

    /// `-case-preview <open 0…1> [pull 0…1]`: freezes the selected case half/fully open, or its
    /// medium part-way out (screenshots). `-case-animate` instead opens it with the real animation.
    func runHandheldCasePreviewIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if debugCaseGameIndex() != nil, ids.indices.contains(selection) {
            lastObservedSelectionID = ids[selection]
            owner.onSelect(ids[selection])
        }
        if arguments.contains("-case-toggle-test") {
            // Flip "不显示卡带盒" while idle: the cards must rebuild both ways (cases ⇄ bare media).
            let key = HandheldCaseSettings.hideCasesKey
            let original = HandheldCaseSettings.casesHidden
            func state() -> (cases: Int, bareDiscs: Int) {
                (cards.filter(HandheldCaseStage.hasCase).count, cards.filter(CartridgeSceneFactory.isBarePS2Disc).count)
            }
            let before = state()
            UserDefaults.standard.set(!original, forKey: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let flipped = state()
                UserDefaults.standard.set(original, forKey: key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let restored = state()
                    let hiddenState = original ? before : flipped
                    let shownState = original ? flipped : before
                    let pass = hiddenState.cases == 0 && shownState.cases > 0 && restored == before
                        && (hiddenState.bareDiscs > 0) == self.owner.games.contains { $0.platform == .ps2 }
                        && shownState.bareDiscs == 0
                    print("\(pass ? "DUO_CASE_TOGGLE_PASS" : "DUO_CASE_TOGGLE_FAIL") shown=\(shownState) hidden=\(hiddenState) restored=\(restored)")
                    fflush(stdout)
                }
            }
            return
        }
        if arguments.contains("-case-animate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.openHandheldCase() }
            return
        }
        guard let i = arguments.firstIndex(of: "-case-preview"), arguments.indices.contains(i + 1),
              let open = Float(arguments[i + 1]) else { return }
        guard selectedHasHandheldCase, mode == .idle else {
            print("DUO_CASE_PREVIEW_FAIL selection=\(selection) mode=\(mode)")
            return
        }
        handheldCase = HandheldCaseStage(card: cards[selection], parent: scene.rootNode)
        handheldCase?.open = min(max(open, 0), 1)
        mode = open >= 1 ? .caseOpen : .caseOpening
        if arguments.indices.contains(i + 2), let pull = Float(arguments[i + 2]), pull > 0 {
            mode = .pull
            self.pull = min(pull, 1)
        }
        layout()
        print("DUO_CASE_PREVIEW open=\(open) pull=\(pull) game=\(owner.games[selection].title)")
        fflush(stdout)
    }
    #endif
}

// MARK: - PS2 without its case

extension CartridgeSceneFactory {
    static let ps2BareDiscName = "DUO_PS2_BARE_DISC"
    /// Carousel units per metre of the bare PS2 disc: its 120 mm are about as wide as a shelf UMD.
    static let ps2BareDiscUnitsPerMetre: Float = 375

    /// With `HandheldCaseSettings.casesHidden`: the bare PS2 disc, label to the camera, as the
    /// Cover Flow card. `PS2CaseStage(bareDiscCard:)` flies a copy of it to the console.
    /// The library builds its cards on the main thread; elsewhere this returns nil (→ the case).
    static func ps2DiscScene(for game: GameLibraryItem) -> SCNScene? {
        guard Thread.isMainThread,
              let disc = MainActor.assumeIsolated({ PS2CaseStage.makeDisc(for: game) }) else { return nil }
        disc.name = ps2BareDiscName
        disc.simdScale = SIMD3(repeating: ps2BareDiscUnitsPerMetre)
        // The DVD's label normal is its +Y (as on `CASE_DISC_ANCHOR`): turn it to face +Z.
        disc.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        let scene = SCNScene()
        scene.rootNode.name = game.id
        let model = SCNNode()
        model.name = "cartridgeModel"
        model.eulerAngles = SCNVector3(-0.05, -0.08, 0)
        model.addChildNode(disc)
        scene.rootNode.addChildNode(model)
        HandheldCaseAssets.addPreviewRig(to: scene)
        return scene
    }

    static func isBarePS2Disc(_ card: SCNNode) -> Bool {
        card.childNode(withName: ps2BareDiscName, recursively: false) != nil
    }
}

extension DragCartridgeSceneView.Coordinator {
    /// Bare-disc mode: puts the PS2 stage (console, travelling disc) in place for the selected disc
    /// card, ready to pull (`.caseOpen` = stage ready). False when the selection is not a bare disc.
    func beginBarePS2Stage() -> Bool {
        guard mode == .idle, ps2 == nil, cards.indices.contains(selection), owner.games.indices.contains(selection),
              owner.games[selection].platform == .ps2, CartridgeSceneFactory.isBarePS2Disc(cards[selection]),
              let stage = PS2InsertionStage(card: cards[selection], game: owner.games[selection],
                                            parent: scene.rootNode) else { return false }
        ps2 = stage
        ps2Open = 0
        ps2Tray = nil
        stage.target = .disc
        mode = .caseOpen
        layout()
        return true
    }
}

#if DEBUG
extension DragCartridgeSceneView.Coordinator {
    /// `-case-tap-test`: for each cased game (PS2 / DS / 3DS / PSP), selects it, checks that a tap on
    /// the centre of the closed case hits it, and opens it the way the tap does; logs
    /// DUO_CASE_TAP_HIT / MISS per game.
    func runCaseTapTestIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-case-tap-test") else { return }
        let indices = owner.games.indices.filter { [.ps2, .nds, .threeDS, .psp].contains(owner.games[$0].platform) }
        func step(_ remaining: ArraySlice<Int>) {
            guard let index = remaining.first else { print("DUO_CASE_TAP_DONE"); fflush(stdout); return }
            settleSelection(to: index) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let view = self.view, self.cards.indices.contains(self.selection) else { return }
                    let centre = self.cards[self.selection].presentation.boundingSphere.center
                    let projected = view.projectPoint(self.cards[self.selection].presentation.convertPosition(centre, to: nil))
                    let point = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                    let hit = self.pointHitsSelectedCard(point, in: view)
                    let first = view.hitTest(point, options: nil).first?.node.name ?? "nothing"
                    print("DUO_CASE_TAP_\(hit ? "HIT" : "MISS") \(self.owner.games[index].title) first=\(first)")
                    fflush(stdout)
                    step(remaining.dropFirst())
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step(indices[...]) }
    }
}
#endif

