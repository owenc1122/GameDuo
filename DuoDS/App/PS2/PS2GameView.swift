import SwiftUI
import WebKit
import SceneKit
import UIKit

// MARK: - Layout

/// Portrait layout shared by every device. The top half of the usable height is the TV: the
/// picture is aspect-fit inside it, letterboxed black. The DualShock 2 (with the flat shoulder
/// row above it) is as large as fits in the bottom half. The distant console fills whatever gap
/// is left, down between the shoulder buttons if needed. All rects are in PS2GameView
/// coordinates (full screen, safe areas ignored).
struct PS2GameLayout: Equatable {
    var size: CGSize
    /// The TV: from `topInset` to half the height.
    var screenRegion: CGRect
    /// The picture inside `screenRegion`.
    var screenRect: CGRect
    /// From the TV's bottom edge to the controller body (includes the shoulder row).
    var gapRect: CGRect
    /// Where the distant console is drawn.
    var consoleRect: CGRect
    var controllerRegion: CGRect
    var bodyRect: CGRect
    /// Controller scale, points per model metre.
    var pointsPerMeter: CGFloat

    /// Projected width ÷ height of the console at the game camera's angle.
    static let consoleAspect: CGFloat = 2.55

    /// `shoulderClearance`: `PS2ControllerModel.shoulderClearance` (model metres).
    init(size: CGSize, topInset: CGFloat, bottomInset: CGFloat, screenAspect: CGFloat,
         footprint: PS2ControllerModel.Footprint, shoulderClearance: CGFloat) {
        self.size = size
        let width = max(1, size.width)
        let half = (max(2, size.height) / 2).rounded()
        screenRegion = CGRect(x: 0, y: topInset, width: width, height: max(1, half - topInset))
        let pictureHeight = min(screenRegion.width / screenAspect, screenRegion.height).rounded(.down)
        let pictureWidth = min(width, (pictureHeight * screenAspect).rounded())
        screenRect = CGRect(x: ((width - pictureWidth) / 2).rounded(),
                            y: (screenRegion.midY - pictureHeight / 2).rounded(),
                            width: pictureWidth, height: pictureHeight)

        let margin = max(8, width * 0.02)
        let bottom = size.height - bottomInset
        let controllerDepth = CGFloat(footprint.depth) + PS2ControllerMetrics.shoulderRowDepth
        pointsPerMeter = max(1, min((width - 2 * margin) / CGFloat(footprint.width),
                                    (bottom - half) / controllerDepth))
        let bodySize = CGSize(width: CGFloat(footprint.width) * pointsPerMeter,
                              height: CGFloat(footprint.depth) * pointsPerMeter)
        bodyRect = CGRect(x: (width - bodySize.width) / 2, y: bottom - bodySize.height,
                          width: bodySize.width, height: bodySize.height)
        let rowTop = bodyRect.minY - PS2ControllerMetrics.shoulderRowDepth * pointsPerMeter
        controllerRegion = CGRect(x: 0, y: rowTop, width: width, height: size.height - rowTop)
        gapRect = CGRect(x: 0, y: screenRegion.maxY, width: width,
                         height: max(0, bodyRect.minY - screenRegion.maxY))

        // Either wholly above the shoulder row, or down between the shoulder buttons (narrower),
        // whichever is larger; leave room below it for the cable to reach the controller.
        let pad: CGFloat = 6
        let k = Self.consoleAspect
        let maxWidth = min(width * 0.42, 300)
        let above = max(0, rowTop - gapRect.minY - 2 * pad)
        let aboveWidth = min(above * k, maxWidth)
        let cableRoom = max(16, gapRect.height * 0.28)
        let band = 2 * shoulderClearance * pointsPerMeter - 8
        let inBandWidth = min(band, max(0, gapRect.height - pad - cableRoom) * k, maxWidth)
        let consoleWidth = max(90, aboveWidth, inBandWidth).rounded()
        let consoleHeight = (consoleWidth / k).rounded()
        let centerY = aboveWidth >= inBandWidth
            ? gapRect.minY + (rowTop - gapRect.minY) / 2
            : gapRect.minY + pad + consoleHeight / 2
        consoleRect = CGRect(x: ((width - consoleWidth) / 2).rounded(), y: (centerY - consoleHeight / 2).rounded(),
                             width: consoleWidth, height: consoleHeight)
    }

    /// The centre of the controller boot's end face (where the live cable comes out), and the
    /// cable's on-screen radius there.
    func cableStart(footprint: PS2ControllerModel.Footprint) -> (point: CGPoint, radius: CGFloat) {
        let center = footprint.center
        let exit = PS2ControllerMetrics.cableExit
        let point = CGPoint(x: bodyRect.midX + CGFloat(exit.x - center.x) * pointsPerMeter,
                            y: bodyRect.midY + CGFloat(PS2ControllerMetrics.cableBootEndZ - center.y) * pointsPerMeter)
        return (point, CGFloat(PS2ControllerMetrics.cableRadius) * pointsPerMeter)
    }
}

// MARK: - Screen feed

/// Game frames for the top screen. Kept apart from the runtime model so a 60 Hz feed only
/// redraws the screen view.
@MainActor
final class PS2ScreenFeed: ObservableObject {
    @Published var image: CGImage?
}

enum PS2PowerLight { case off, standby, on }

// MARK: - Runtime model

/// Owns the distant console scene (with the live cable), the controller model, the screen feed
/// and the CRT effect. The exit animation reaches the console through this object
/// (`PS2RuntimeModel.active` or the instance passed to `PS2GameView`).
@MainActor
final class PS2RuntimeModel: ObservableObject {
    /// The model of the PS2GameView currently on screen.
    static weak var active: PS2RuntimeModel?

    let controller = PS2ControllerModel()
    let screenFeed = PS2ScreenFeed()
    let crt = PS2CRTShutdownController()
    /// 4:3 by default; set 16/9 for widescreen output.
    @Published var screenAspect: CGFloat = 4.0 / 3.0
    /// The running PS2 core (Play! in WebKit), created when the game screen appears.
    @Published private(set) var core: PS2WebCore?
    @Published var controlsLocked = false
    /// Fades the top screen and the controller away so the full-screen console view can be
    /// used alone (e.g. the disc flying toward the camera).
    @Published var foregroundHidden = false

    // Console scene, rendered by a full-screen perspective SCNView behind everything.
    let consoleScene: SCNScene
    let consoleCameraNode = SCNNode()
    private(set) var consoleNode: SCNNode?
    /// Slides on local Z: `trayRestPosition.z + 0 … 0.135` m (ejected).
    private(set) var discTray: SCNNode?
    private(set) var trayRestPosition = SCNVector3Zero
    /// Empty node on the tray; seat `PS2_DVD` here with an identity transform.
    private(set) var trayDiscAnchor: SCNNode?
    private(set) var portNode: SCNNode?
    private(set) var cableNode = SCNNode()
    /// Child of `cableNode`, so it fades out with the cable.
    private let cableShadow = SCNNode()
    private(set) var plugNode: SCNNode?
    /// The live console SCNView (full PS2GameView bounds).
    weak var consoleView: SCNView?
    /// Top game screen and projected console bounds, in PS2GameView coordinates.
    private(set) var screenRect: CGRect = .zero
    private(set) var consoleScreenRect: CGRect = .zero
    var renderRequest: ((TimeInterval) -> Void)?

    private var powerMaterials: [SCNMaterial] = []
    private var ejectMaterials: [SCNMaterial] = []
    private let powerGlow = SCNNode()
    private let ejectGlow = SCNNode()
    private var powerLight = PS2PowerLight.on
    private var powerBlinking = false
    private var ejectLit = false
    private var powerBlinkTask: Task<Void, Never>?
    private var ejectBlinkTask: Task<Void, Never>?
    private var viewportKey: [CGFloat] = []
    private var focalLength: CGFloat = 1
    private var viewSize: CGSize = .zero
    /// Camera → console target distance (m), from the last viewport update.
    private var cameraDistance: Float = 1
    // Exit sequence state.
    private var exitStarted = false
    /// True once the game-screen part of the exit (CRT, eject, disc flight) has finished and
    /// the library may take over (`makeExitHandoff()`).
    private(set) var exitReady = false
    private(set) var exitDisc: SCNNode?
    private var exitDiscFlown = false
    private var exitAnimation: PS2FrameAnimation?
    private var exitCameraBase: simd_float4x4?

    static let backgroundColor = UIColor(red: 0.035, green: 0.038, blue: 0.047, alpha: 1)
    private static let green = UIColor(red: 0.235, green: 1, blue: 0.42, alpha: 1)   // #3CFF6B
    private static let red = UIColor(red: 1, green: 0.165, blue: 0.1, alpha: 1)      // #FF2A1A
    private static let blue = UIColor(red: 0.227, green: 0.482, blue: 1, alpha: 1)   // #3A7BFF
    private static let fieldOfView: CGFloat = 30

    init() {
        if let url = Bundle.main.url(forResource: "PS2-Console", withExtension: "usdz"),
           let loaded = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            consoleScene = loaded
        } else {
            consoleScene = SCNScene()
        }
        let root = consoleScene.rootNode
        root.enumerateChildNodes { node, _ in node.removeAllAnimations() }
        NeutralBranding.hidePS2Prints(in: root)
        consoleNode = root.childNode(withName: "PS2_CONSOLE", recursively: true)
        discTray = root.childNode(withName: "DISC_TRAY", recursively: true)
        trayRestPosition = discTray?.position ?? SCNVector3Zero
        trayDiscAnchor = root.childNode(withName: "TRAY_DISC_ANCHOR", recursively: true)
        portNode = root.childNode(withName: "PORT_CTRL_1", recursively: true)
        powerMaterials = Self.bindMaterials(root.childNode(withName: "LED_POWER", recursively: true))
        ejectMaterials = Self.bindMaterials(root.childNode(withName: "LED_EJECT", recursively: true))
        #if DEBUG
        let found = [consoleNode, discTray, trayDiscAnchor, portNode].compactMap { $0 }.count
        print(found == 4 && !powerMaterials.isEmpty && !ejectMaterials.isEmpty
              ? "DUO_PS2_CONSOLE_RIG_PASS" : "DUO_PS2_CONSOLE_RIG_FAIL: nodes=\(found)")
        #endif

        let camera = SCNCamera()
        camera.fieldOfView = Self.fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = 0.05
        camera.zFar = 30
        consoleCameraNode.camera = camera
        consoleCameraNode.name = "DUO_PS2_GAME_CAMERA"
        root.addChildNode(consoleCameraNode)
        // Background and fog go through the same colour pipeline, so fogged geometry melts into it.
        consoleScene.background.contents = Self.backgroundColor
        consoleScene.fogColor = Self.backgroundColor
        consoleScene.fogDensityExponent = 1

        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, from position: SIMD3<Float>? = nil) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.intensity = intensity
            if let position {
                node.simdPosition = position
                node.simdLook(at: SIMD3(0, 0.03, 0))
            }
            root.addChildNode(node)
        }
        light(.directional, 950, from: SIMD3(0.8, 1.4, 1.2))
        light(.directional, 420, from: SIMD3(-1.2, 0.6, 0.8))
        light(.directional, 650, from: SIMD3(-0.4, 0.9, -1.4))   // rim, separates the black body
        light(.ambient, 180)

        addFloor()
        addGlow(powerGlow, parent: root.childNode(withName: "BTN_RESET", recursively: true),
                at: SIMD3(0.1404, 0.0717, 0.0912))
        addGlow(ejectGlow, parent: root.childNode(withName: "BTN_EJECT", recursively: true),
                at: SIMD3(0.1402, 0.0422, 0.0912))
        if let template = controller.plugTemplate, let port = portNode {
            let plug = template.flattenedClone()
            plug.simdTransform = matrix_identity_float4x4
            port.addChildNode(plug)
            plugNode = plug
        }
        cableNode.name = "DUO_PS2_CABLE"
        cableShadow.renderingOrder = -1
        cableShadow.castsShadow = false
        cableNode.addChildNode(cableShadow)
        root.addChildNode(cableNode)
        setPowerLight(.on)
        setEjectLight(false)
    }

    private static func bindMaterials(_ node: SCNNode?) -> [SCNMaterial] {
        guard let node else { return [] }
        var materials: [SCNMaterial] = []
        func bind(_ candidate: SCNNode) {
            guard let geometry = candidate.geometry else { return }
            let copies = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            geometry.materials = copies
            materials.append(contentsOf: copies)
        }
        bind(node)
        node.enumerateChildNodes { child, _ in bind(child) }
        return materials
    }

    private static func radialImage(size: CGFloat, stops: [(UIColor, CGFloat)]) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let colors = stops.map { $0.0.cgColor } as CFArray
            let locations = stops.map { $0.1 }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: locations) else { return }
            let c = CGPoint(x: size / 2, y: size / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c,
                                                 endRadius: size / 2, options: [])
        }
    }

    /// A soft contact shadow grounds the console without a visible floor edge.
    private func addFloor() {
        func decal(width: CGFloat, depth: CGFloat, image: UIImage, y: Float, order: Int) {
            let plane = SCNPlane(width: width, height: depth)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(0, y, 0.05)
            node.renderingOrder = order
            node.castsShadow = false
            consoleScene.rootNode.addChildNode(node)
        }
        decal(width: 0.46, depth: 0.3, image: Self.radialImage(size: 128, stops: [
            (UIColor(white: 0, alpha: 0.85), 0), (UIColor(white: 0, alpha: 0.5), 0.55), (UIColor(white: 0, alpha: 0), 1)
        ]), y: 0.0004, order: -1)
    }

    /// Far away, a 1.6 mm lens is sub-pixel; a small additive billboard stands in for its glow.
    private func addGlow(_ node: SCNNode, parent: SCNNode?, at position: SIMD3<Float>) {
        let plane = SCNPlane(width: 0.02, height: 0.02)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Self.radialImage(size: 64, stops: [
            (UIColor(white: 1, alpha: 1), 0), (UIColor(white: 1, alpha: 0.55), 0.18),
            (UIColor(white: 1, alpha: 0.12), 0.5), (UIColor(white: 1, alpha: 0), 1)
        ])
        material.blendMode = .add
        material.writesToDepthBuffer = false
        plane.materials = [material]
        node.geometry = plane
        node.constraints = [SCNBillboardConstraint()]
        node.renderingOrder = 10
        node.isHidden = true
        guard let parent else { return }
        node.simdPosition = parent.simdConvertPosition(position, from: nil)
        parent.addChildNode(node)
    }

    // MARK: Lights

    private func paint(_ materials: [SCNMaterial], glow: SCNNode, color: UIColor?) {
        for material in materials {
            material.emission.contents = color ?? UIColor.black
            material.emission.intensity = color == nil ? 0 : 2
            if let color { material.diffuse.contents = color }
        }
        glow.isHidden = color == nil
        glow.geometry?.firstMaterial?.multiply.contents = color ?? UIColor.clear
        renderRequest?(0.05)
    }

    func setPowerLight(_ light: PS2PowerLight) {
        powerLight = light
        guard !powerBlinking else { return }
        paint(powerMaterials, glow: powerGlow, color: Self.color(for: light))
    }

    private static func color(for light: PS2PowerLight) -> UIColor? {
        switch light {
        case .off: nil
        case .standby: red
        case .on: green
        }
    }

    /// Fast power-lens blink while the exit long-press is held.
    func setPowerBlinking(_ active: Bool) {
        guard active != powerBlinking else { return }
        powerBlinkTask?.cancel()
        powerBlinking = active
        guard active else {
            paint(powerMaterials, glow: powerGlow, color: Self.color(for: powerLight))
            return
        }
        powerBlinkTask = Task { @MainActor [weak self] in
            var lit = false
            while !Task.isCancelled {
                guard let self, self.powerBlinking else { return }
                self.paint(self.powerMaterials, glow: self.powerGlow, color: lit ? Self.color(for: self.powerLight) : nil)
                lit.toggle()
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    func setEjectLight(_ on: Bool) {
        ejectBlinkTask?.cancel()
        ejectBlinkTask = nil
        ejectLit = on
        paint(ejectMaterials, glow: ejectGlow, color: on ? Self.blue : nil)
    }

    /// Blue disc-access blink ("reading"); `duration` nil blinks until stopped.
    func setEjectBlinking(_ active: Bool, duration: TimeInterval? = nil) {
        ejectBlinkTask?.cancel()
        guard active else { setEjectLight(false); return }
        ejectBlinkTask = Task { @MainActor [weak self] in
            let end = duration.map { Date().addingTimeInterval($0) }
            var lit = true
            while !Task.isCancelled {
                guard let self else { return }
                if let end, Date() >= end { self.paint(self.ejectMaterials, glow: self.ejectGlow, color: nil); return }
                self.paint(self.ejectMaterials, glow: self.ejectGlow, color: lit ? Self.blue : nil)
                lit.toggle()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    // MARK: Tray

    /// 0 = closed, 1 = fully ejected (0.135 m along local Z).
    func setTrayOpen(_ progress: CGFloat, duration: TimeInterval = 0) {
        guard let tray = discTray else { return }
        let offset = Float(min(1, max(0, progress))) * 0.135
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tray.position = SCNVector3(trayRestPosition.x, trayRestPosition.y, trayRestPosition.z + offset)
        SCNTransaction.commit()
        renderRequest?(duration + 0.1)
    }

    // MARK: Frames

    /// Hook for the PS2 core: present a finished frame on the top screen (nil = placeholder).
    func presentFrame(_ image: CGImage?) {
        guard image !== screenFeed.image else { return }
        screenFeed.image = image
    }

    // MARK: Viewport

    /// World ↔ view mapping for the full-screen console view (valid after `updateConsoleViewport`).
    func project(_ world: SIMD3<Float>) -> (point: CGPoint, depth: Float) {
        let local = consoleCameraNode.simdConvertPosition(world, from: nil)
        let depth = max(0.0001, -local.z)
        let f = Float(focalLength)
        return (CGPoint(x: viewSize.width / 2 + CGFloat(f * local.x / depth),
                        y: viewSize.height / 2 - CGFloat(f * local.y / depth)), depth)
    }

    func unproject(_ point: CGPoint, depth: Float) -> SIMD3<Float> {
        let f = Float(focalLength)
        let local = SIMD3<Float>(Float(point.x - viewSize.width / 2) / f * depth,
                                 -Float(point.y - viewSize.height / 2) / f * depth, -depth)
        return consoleCameraNode.simdConvertPosition(local, to: nil)
    }

    func updateConsoleViewport(size: CGSize, layout: PS2GameLayout) {
        guard size.width > 0, size.height > 0 else { return }
        let target = layout.consoleRect
        let key = [size.width, size.height, target.minX, target.minY, target.width,
                   layout.bodyRect.minY, layout.bodyRect.width]
        guard key != viewportKey else { return }
        viewportKey = key
        viewSize = size
        screenRect = layout.screenRect
        let f = size.height / 2 / tan(Self.fieldOfView / 2 * .pi / 180)
        focalLength = f
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        // Aim at the console's centre, then correct once so its projected bounds land on
        // `layout.consoleRect` (perspective makes the two differ slightly).
        var width = target.width
        var anchor = CGPoint(x: target.midX, y: target.midY)
        for _ in 0..<2 {
            placeCamera(consoleWidth: width, anchor: anchor, size: size)
            let rect = projectedConsoleRect()
            guard rect.width > 1 else { break }
            width *= target.width / rect.width
            anchor.x += target.midX - rect.midX
            anchor.y += target.midY - rect.midY
        }
        placeCamera(consoleWidth: width, anchor: anchor, size: size)
        let distance = cameraDistance
        consoleScene.fogStartDistance = CGFloat(distance * 0.35)
        consoleScene.fogEndDistance = CGFloat(distance * 3.2)
        let glowSize = CGFloat(10 * distance) / f
        for glow in [powerGlow, ejectGlow] {
            (glow.geometry as? SCNPlane)?.width = glowSize
            (glow.geometry as? SCNPlane)?.height = glowSize
        }
        SCNTransaction.commit()
        consoleScreenRect = projectedConsoleRect()
        rebuildCable(layout: layout)
        renderRequest?(0.1)
    }

    /// Camera at the fixed viewing angle, at the distance where the console is `consoleWidth`
    /// points wide, turned so the console's centre lands on `anchor`.
    private func placeCamera(consoleWidth: CGFloat, anchor: CGPoint, size: CGSize) {
        let f = focalLength
        let distance = Float(0.301 * f / max(20, consoleWidth))
        cameraDistance = distance
        let target = SIMD3<Float>(0.0005, 0.039, 0)
        let elevation: Float = 13 * .pi / 180
        let azimuth: Float = -16 * .pi / 180
        let direction = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        consoleCameraNode.simdPosition = target + direction * distance
        consoleCameraNode.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        let yaw = Float(atan((anchor.x - size.width / 2) / f))
        let pitch = Float(atan((size.height / 2 - anchor.y) / f))
        consoleCameraNode.simdLocalRotate(by: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        consoleCameraNode.simdLocalRotate(by: simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0)))
    }

    private func projectedConsoleRect() -> CGRect {
        guard let body = consoleScene.rootNode.childNode(withName: "BODY", recursively: true) else { return .zero }
        let (a, b) = body.boundingBox
        var rect = CGRect.null
        for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
            let p = project(body.simdConvertPosition(SIMD3(x, y, z), to: nil)).point
            rect = rect.union(CGRect(origin: p, size: .zero))
        } } }
        return rect.isNull ? .zero : rect
    }

    // MARK: Cable

    /// The live cable: a 4 mm tube in the console scene from the controller's boot to the plug in
    /// PORT_CTRL_1. Near end: on the camera ray through the boot's end face, at the depth where the
    /// tube has the boot view's cable width, heading away from the viewer (straight up on screen),
    /// so the orthographic controller and the perspective scene meet seamlessly. From the hand it
    /// sags onto the floor in front of the console (with a soft contact shadow), runs back along
    /// it and rises into the plug. Constant radius in 3D: it thins and fogs with distance.
    private func rebuildCable(layout: PS2GameLayout) {
        guard let port = portNode else { return }
        let start = layout.cableStart(footprint: controller.footprint)
        guard start.radius > 0 else { return }
        let r = PS2ControllerMetrics.cableRadius
        let nearDepth = r * Float(focalLength / start.radius)
        let eye = consoleCameraNode.simdWorldPosition
        /// Depth at which the ray through `point` meets the plane `y = height` (nil above the horizon).
        func floorDepth(_ point: CGPoint, height: Float) -> Float? {
            let direction = unproject(point, depth: 1) - eye
            guard direction.y < -1e-5 else { return nil }
            return (height - eye.y) / direction.y
        }

        // Landing: on the floor just in front of the port, visible below the console's base.
        let s0 = start.point
        let portPosition = port.simdWorldPosition
        let plugRear = portPosition + SIMD3(0, 0, 0.048)
        var landing = SIMD3<Float>(portPosition.x + 0.012, r, portPosition.z + 0.075)
        var landingPoint = project(landing).point
        let highest = consoleScreenRect.maxY + 3, lowest = s0.y - 12
        let clampedY = min(max(landingPoint.y, highest), max(highest, lowest))
        if clampedY != landingPoint.y, let depth = floorDepth(CGPoint(x: landingPoint.x, y: clampedY), height: r) {
            landing = unproject(CGPoint(x: landingPoint.x, y: clampedY), depth: depth)
            landingPoint = project(landing).point
        }
        let landingDepth = project(landing).depth

        // Hand → floor on screen: straight up out of the boot while the cable is still thick, then
        // curving over to the landing, heading for the plug, once it has thinned (one cubic
        // Hermite arc). Depth follows the screen length with 1/depth linear (as for a cable lying
        // straight back in depth), so the width shrinks evenly from the boot's scale to the
        // console's; the cable is kept on or above the floor.
        let plugPoint = project(plugRear).point
        func unit(_ v: CGPoint) -> CGPoint { let l = max(1e-6, hypot(v.x, v.y)); return CGPoint(x: v.x / l, y: v.y / l) }
        let towardPlug = unit(CGPoint(x: plugPoint.x - landingPoint.x, y: min(-6, plugPoint.y - landingPoint.y)))
        let chord = hypot(landingPoint.x - s0.x, landingPoint.y - s0.y)
        let m0 = CGPoint(x: 0, y: -1.25 * chord)
        let m1 = CGPoint(x: towardPlug.x * 0.7 * chord, y: towardPlug.y * 0.7 * chord)
        var screen: [CGPoint] = []
        var lengths: [CGFloat] = [0]
        for i in 0...64 {
            let t = CGFloat(i) / 64, t2 = t * t, t3 = t2 * t
            let a = 2 * t3 - 3 * t2 + 1, b = t3 - 2 * t2 + t, c = -2 * t3 + 3 * t2, d = t3 - t2
            let point = CGPoint(x: a * s0.x + b * m0.x + c * landingPoint.x + d * m1.x,
                                y: a * s0.y + b * m0.y + c * landingPoint.y + d * m1.y)
            if let last = screen.last { lengths.append(lengths[lengths.count - 1] + hypot(point.x - last.x, point.y - last.y)) }
            screen.append(point)
        }
        let total = max(1, lengths[lengths.count - 1])
        var path: [SIMD3<Float>] = []
        for (point, length) in zip(screen, lengths) {
            let u = Float(length / total)
            var depth = 1 / (1 / nearDepth + (1 / landingDepth - 1 / nearDepth) * u)
            if let floor = floorDepth(point, height: r) {
                // Smooth minimum: the cable settles onto the floor instead of creasing into it.
                let k = 0.02 * landingDepth
                depth = -k * log(exp(-depth / k) + exp(-floor / k))
            }
            path.append(unproject(point, depth: depth))
        }
        // Hidden under the boot: continue a few millimetres back so the open end never shows.
        if path.count > 1 {
            path.insert(path[0] - simd_normalize(path[1] - path[0]) * 0.006, at: 0)
        }

        // Floor → plug: a Hermite curve leaving the landing in the same direction and entering
        // the plug along −Z, kept on or above the floor.
        let p0 = path[path.count - 1]
        let incoming = simd_normalize(p0 - path[path.count - 2])
        let span = simd_distance(p0, plugRear)
        let t0 = incoming * span * 1.1
        let t1 = SIMD3<Float>(0, 0, -1) * span * 1.3
        for i in 1...24 {
            let t = Float(i) / 24
            let t2 = t * t, t3 = t2 * t
            var point = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * t0
                + (-2 * t3 + 3 * t2) * plugRear + (t3 - t2) * t1
            point.y = max(point.y, r)
            path.append(point)
        }
        let geometry = Self.tube(path, radius: r, sides: 16)
        geometry.materials = [PS2ControllerMetrics.cableMaterial()]
        cableNode.geometry = geometry
        cableShadow.geometry = Self.contactShadow(path, cableRadius: r)
    }

    /// A soft dark ribbon on the floor under the parts of `path` that rest on or near it.
    private static func contactShadow(_ path: [SIMD3<Float>], cableRadius r: Float) -> SCNGeometry? {
        var vertices: [SCNVector3] = []
        var coordinates: [CGPoint] = []
        var indices: [UInt32] = []
        let halfWidth: Float = r * 2.4
        for (i, point) in path.enumerated() {
            let ahead = path[min(path.count - 1, i + 1)], behind = path[max(0, i - 1)]
            var tangent = SIMD3<Float>(ahead.x - behind.x, 0, ahead.z - behind.z)
            guard simd_length(tangent) > 1e-6 else { continue }
            tangent = simd_normalize(tangent)
            let side = SIMD3<Float>(-tangent.z, 0, tangent.x) * halfWidth
            // v: 0 = resting on the floor … 1 = 12 mm above it (no shadow).
            let v = CGFloat(min(1, max(0, (point.y - r) / 0.012)))
            let base = SIMD3<Float>(point.x, 0.0006, point.z)
            let count = UInt32(vertices.count)
            vertices += [SCNVector3(base - side), SCNVector3(base + side)]
            coordinates += [CGPoint(x: 0, y: v), CGPoint(x: 1, y: v)]
            if count >= 2 { indices += [count - 2, count, count - 1, count - 1, count, count + 1] }
        }
        guard !indices.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                             SCNGeometrySource(textureCoordinates: coordinates)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = shadowTexture
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        material.blendMode = .alpha
        geometry.materials = [material]
        return geometry
    }

    /// Across (u): soft falloff from the cable's centre line; down (v): fades with height.
    private static let shadowTexture: UIImage = {
        let size = CGSize(width: 64, height: 32)
        return UIGraphicsImageRenderer(size: size).image { context in
            for y in 0..<Int(size.height) {
                let contact = 1 - CGFloat(y) / (size.height - 1)
                for x in 0..<Int(size.width) {
                    let across = abs(CGFloat(x) / (size.width - 1) * 2 - 1)
                    let alpha = 0.62 * pow(contact, 1.6) * pow(max(0, 1 - across * across), 1.8)
                    UIColor(white: 0, alpha: alpha).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()

    static func tube(_ path: [SIMD3<Float>], radius: Float, sides: Int) -> SCNGeometry {
        guard path.count > 1 else { return SCNGeometry() }
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        let count = path.count
        var tangent = simd_normalize(path[1] - path[0])
        var normal = simd_normalize(simd_cross(tangent, abs(tangent.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)))
        for i in 0..<count {
            let ahead = path[min(count - 1, i + 1)], behind = path[max(0, i - 1)]
            let next = simd_normalize(ahead - behind)
            // Parallel transport keeps the ring frame from twisting along the curve.
            normal = simd_normalize(normal - simd_dot(normal, next) * next)
            tangent = next
            let binormal = simd_cross(tangent, normal)
            for j in 0..<sides {
                let angle = Float(j) / Float(sides) * 2 * .pi
                let n = cos(angle) * normal + sin(angle) * binormal
                let v = path[i] + n * radius
                vertices.append(SCNVector3(v.x, v.y, v.z))
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
        }
        for i in 0..<(count - 1) {
            for j in 0..<sides {
                let a = UInt32(i * sides + j), b = UInt32(i * sides + (j + 1) % sides)
                let c = a + UInt32(sides), d = b + UInt32(sides)
                indices += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    // MARK: Exit

    /// The game-screen half of leaving a game: the top screen switches off like an old TV, the
    /// distant console ejects its tray and the disc lifts off and flies up to the camera. Then
    /// `completion` runs and the library continues from `makeExitHandoff()` (the view pans up
    /// with the disc into its case). With Reduce Motion only the TV switches off.
    func playExit(reduceMotion: Bool, completion: @escaping () -> Void) {
        guard !exitStarted else { return }
        exitStarted = true
        controlsLocked = true
        // Pause the VM and flush its memory card while the TV switches off.
        core?.stop {}
        PS2Feedback.shared.prepare()
        crt.play { [weak self] in
            guard let self else { return }
            guard !reduceMotion, let disc = self.exitDisc, self.consoleView != nil else {
                self.exitReady = true
                completion()
                return
            }
            self.ejectDisc(disc, completion: completion)
        }
    }

    /// Boots the game in the PS2 core. DEBUG: `-ps2-core-elf <folder>` boots the first ELF in
    /// that folder instead (its files are mounted as `host:`); `-ps2-core-disc <image>` boots that
    /// disc image.
    func startCore(for game: GameLibraryItem?) {
        guard core == nil else { return }
        var content: PS2WebCore.Content?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-ps2-core-elf"), arguments.indices.contains(i + 1) {
            let folder = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
            let elf = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .first { $0.lowercased().hasSuffix(".elf") }
            let card = ROMFiles.supportDirectory().appendingPathComponent("PS2/MemoryCards/QA-ELF", isDirectory: true)
            content = PS2WebCore.Content(disc: nil, elfFolder: folder, elfName: elf, memoryCard: card)
        } else if let i = arguments.firstIndex(of: "-ps2-core-disc"), arguments.indices.contains(i + 1) {
            let card = ROMFiles.supportDirectory().appendingPathComponent("PS2/MemoryCards/QA-DISC", isDirectory: true)
            content = PS2WebCore.Content(disc: URL(fileURLWithPath: arguments[i + 1]), elfFolder: nil, elfName: nil, memoryCard: card)
        }
        #endif
        if content == nil, let game {
            content = PS2WebCore.Content(disc: game.url, elfFolder: nil, elfName: nil,
                                         memoryCard: GameLibraryStore.ps2MemoryCardRoot(for: game))
        }
        guard let content else { return }
        let core = PS2WebCore(content: content)
        self.core = core
        core.start()
    }

    func tearDownCore() {
        core?.tearDown()
    }

    /// Puts the game's disc on the closed tray, inside the console (it is drawn, and its
    /// materials compiled, from the first frame, so the eject never stalls).
    func seatDisc(for game: GameLibraryItem?) {
        guard exitDisc == nil, let game, let anchor = trayDiscAnchor,
              let disc = PS2CaseStage.makeDisc(for: game) else { return }
        disc.simdTransform = matrix_identity_float4x4
        anchor.addChildNode(disc)
        exitDisc = disc
    }

    private func ejectDisc(_ disc: SCNNode, completion: @escaping () -> Void) {
        renderRequest?(4)
        setEjectBlinking(true)
        PS2Feedback.shared.playTrayEject()
        setTrayOpen(1, duration: 0.9)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.95))
            guard let self else { return }
            self.setEjectBlinking(false)
            self.flyDisc(disc, completion: completion)
        }
    }

    /// Where the flight ends, in camera space: large, in the upper middle of the view, label
    /// upright and leaning back slightly (seen a little from above, as it left the tray).
    private func exitFlightTarget(scale: Float) -> simd_float4x4 {
        let diameter = Float(min(viewSize.width * 0.64, viewSize.height * 0.42))
        let f = Float(focalLength)
        let depth = 0.12 * scale * f / max(1, diameter)
        let point = CGPoint(x: viewSize.width / 2, y: viewSize.height * 0.36)
        let local = SIMD3<Float>(Float(point.x - viewSize.width / 2) / f * depth,
                                 -Float(point.y - viewSize.height / 2) / f * depth, -depth)
        // Disc +Y (label) → camera +Z, label top (disc −Z) → camera +Y: square to the camera, so
        // the library's orthographic camera draws it identically at the hand-off (a lean made the
        // perspective and orthographic outlines differ, a visible jump).
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        return PS2Pose.compose(local, rotation, scale)
    }

    private func flyDisc(_ disc: SCNNode, completion: @escaping () -> Void) {
        let camera = consoleCameraNode
        let start = disc.simdWorldTransform
        disc.removeFromParentNode()
        disc.simdTransform = start
        consoleScene.rootNode.addChildNode(disc)
        let (_, _, scale) = PS2Pose.decompose(start)
        let lifted = simd_float4x4(translation: SIMD3(0, 0.035, 0)) * start
        let liftedLocal = camera.simdWorldTransform.inverse * lifted
        let target = exitFlightTarget(scale: scale)
        let (p0, r0, _) = PS2Pose.decompose(liftedLocal)
        let (p1, r1, _) = PS2Pose.decompose(target)
        let d0 = max(0.001, -p0.z), d1 = max(0.001, -p1.z)
        // Screen position and log-depth are interpolated, so the disc grows at an even rate.
        let s0 = SIMD2(p0.x / d0, p0.y / d0), s1 = SIMD2(p1.x / d1, p1.y / d1)
        let liftDuration = 0.28, flightDuration = 0.95
        PS2Feedback.shared.playDiscLift()
        renderRequest?(liftDuration + flightDuration + 0.3)
        exitAnimation = PS2FrameAnimation(duration: liftDuration + flightDuration, update: { [weak self] elapsed in
            guard let self else { return }
            if elapsed < liftDuration {
                let t = Float(Self.smooth(elapsed / liftDuration))
                disc.simdWorldTransform = PS2Pose.blend(start, lifted, t)
                return
            }
            if !self.foregroundHidden {
                self.foregroundHidden = true
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.3
                self.cableNode.opacity = 0
                SCNTransaction.commit()
            }
            let t = Float(Self.smooth((elapsed - liftDuration) / flightDuration))
            let depth = d0 * pow(d1 / d0, t)
            let screen = s0 + (s1 - s0) * t
            // A little arc: the disc rises above the straight line before settling.
            let arc = sin(.pi * t) * 0.05
            let position = SIMD3<Float>(screen.x * depth, (screen.y + arc) * depth, -depth)
            let local = PS2Pose.compose(position, simd_slerp(r0, r1, t), scale)
            disc.simdWorldTransform = camera.simdWorldTransform * local
        }, completion: { [weak self] in
            guard let self else { return }
            self.exitAnimation = nil
            self.exitDiscFlown = true
            self.exitReady = true
            self.renderRequest?(30)
            completion()
        })
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Entry (library → game in one shot)

    /// The console's projected bounds in window coordinates (nil before the first layout).
    var consoleWindowRect: CGRect? {
        guard let view = consoleView, view.window != nil, consoleScreenRect.width > 1 else { return nil }
        return view.convert(consoleScreenRect, to: nil)
    }

    /// Hides the console, the cable, the TV and the controller, and blacks out the backdrop,
    /// while the library's camera move brings its own console here.
    func beginEntry() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { foregroundHidden = true }
        consoleNode?.isHidden = true
        cableNode.isHidden = true
        setEntryBackdrop(progress: 0)
    }

    /// Backdrop from black (0) to its normal colour (1).
    func setEntryBackdrop(progress: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        Self.backgroundColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = min(max(progress, 0), 1)
        let color = UIColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
        consoleScene.background.contents = color
        consoleScene.fogColor = color
        renderRequest?(0.2)
    }

    func revealForeground() {
        withAnimation(.easeInOut(duration: 0.6)) { foregroundHidden = false }
    }

    /// The library's console has arrived: the game's own console and cable take over.
    func finishEntry() {
        consoleNode?.isHidden = false
        cableNode.isHidden = false
        setEntryBackdrop(progress: 1)
    }

    /// Library pan: moves the camera up so everything at the console's depth slides down by
    /// `points`, and fades the backdrop to black. The exit disc stays where it is on screen.
    func setExitPan(points: CGFloat, fade: CGFloat) {
        if exitCameraBase == nil {
            exitCameraBase = consoleCameraNode.simdTransform
            if let disc = exitDisc {
                let world = disc.simdWorldTransform
                consoleCameraNode.addChildNode(disc)
                disc.simdWorldTransform = world
            }
        }
        guard let base = exitCameraBase else { return }
        let rise = Float(points) * cameraDistance / Float(max(1, focalLength))
        consoleCameraNode.simdTransform = base * simd_float4x4(translation: SIMD3(0, rise, 0))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        Self.backgroundColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = 1 - min(max(fade, 0), 1)
        let color = UIColor(red: r * k, green: g * k, blue: b * k, alpha: 1)
        consoleScene.background.contents = color
        consoleScene.fogColor = color
        renderRequest?(0.2)
    }

    // MARK: Exit hand-off

    func makeExitHandoff() -> PS2ExitHandoff? {
        guard let view = consoleView, let console = consoleNode, let tray = discTray,
              let anchor = trayDiscAnchor else { return nil }
        return PS2ExitHandoff(model: self, view: view, scene: consoleScene, cameraNode: consoleCameraNode,
                              console: console, discTray: tray, trayRestPosition: trayRestPosition,
                              trayDiscAnchor: anchor, disc: exitDisc,
                              screenRect: view.convert(screenRect, to: nil),
                              consoleRect: view.convert(consoleScreenRect, to: nil))
    }

    /// The exit disc as the camera sees it: window position of its centre, points per local
    /// unit at its depth, and its orientation relative to the camera.
    fileprivate func exitDiscPose() -> PS2ExitDiscPose? {
        guard exitDiscFlown, let disc = exitDisc, let view = consoleView, !disc.isHidden else { return nil }
        let world = disc.simdWorldTransform
        let local = consoleCameraNode.simdWorldTransform.inverse * world
        let (position, rotation, scale) = PS2Pose.decompose(local)
        let depth = -position.z
        guard depth > 0.001 else { return nil }
        let center = project(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)).point
        return PS2ExitDiscPose(windowCenter: view.convert(center, to: nil),
                               pointsPerUnit: CGFloat(scale) * focalLength / CGFloat(depth),
                               rotation: rotation)
    }
}

#if DEBUG
extension PS2RuntimeModel {
    /// `-ps2-hittest-selftest`: what a touch on the distant console would reach.
    func logConsoleHitTest(title: String) {
        guard let view = consoleView, let window = view.window else {
            NSLog("DUO_PS2_HITTEST_FAIL game=%@ no console view in a window", title)
            return
        }
        let rect = consoleScreenRect
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        var chain: [String] = []
        var hit = window.hitTest(point, with: nil)
        let reachesConsole = hit === view || (hit as? PS2ConsolePressForwarder)?.console === view
        while let current = hit, chain.count < 8 {
            chain.append(String(describing: type(of: current)).prefix(60).description)
            hit = current.superview
        }
        NSLog("DUO_PS2_HITTEST_%@ game=%@ point=%@ consoleRect=%@ chain=%@", reachesConsole ? "PASS" : "FAIL",
              title, NSCoder.string(for: point), NSCoder.string(for: view.convert(rect, to: nil)),
              chain.joined(separator: " < "))
    }
}
#endif

/// The flying exit disc in screen terms, so an orthographic scene can draw it identically.
struct PS2ExitDiscPose {
    var windowCenter: CGPoint
    /// Screen points per disc-local unit (metre).
    var pointsPerUnit: CGFloat
    /// Orientation relative to the camera (camera looks down −Z, +Y up).
    var rotation: simd_quatf
}

/// Drives a closure every display frame for `duration` seconds (elapsed time, not eased).
@MainActor
final class PS2FrameAnimation: NSObject {
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private let duration: Double
    private let update: (Double) -> Void
    private let completion: () -> Void

    init(duration: Double, update: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.update = update
        self.completion = completion
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        update(0)
    }

    @objc private func tick() {
        let elapsed = min(CACurrentMediaTime() - start, duration)
        update(elapsed)
        guard elapsed >= duration else { return }
        link?.invalidate()
        link = nil
        completion()
    }

    func cancel() {
        link?.invalidate()
        link = nil
    }
}

/// What the exit animation needs from the game screen. The console view stays live and
/// covers the whole PS2GameView, so the disc can be animated in `scene` right up to the
/// camera; set `model.foregroundHidden = true` to fade the screen and controller away.
@MainActor
struct PS2ExitHandoff {
    let model: PS2RuntimeModel
    let view: SCNView
    let scene: SCNScene
    let cameraNode: SCNNode
    let console: SCNNode
    let discTray: SCNNode
    let trayRestPosition: SCNVector3
    let trayDiscAnchor: SCNNode
    /// The disc that flew out of the tray (nil when the flight was skipped).
    let disc: SCNNode?
    /// Top game screen and projected console bounds, in window coordinates.
    let screenRect: CGRect
    let consoleRect: CGRect

    /// The exit disc's current on-screen pose (nil without a visible disc).
    var discPose: PS2ExitDiscPose? { model.exitDiscPose() }

    func windowPoint(of world: SCNVector3) -> CGPoint {
        let p = view.projectPoint(world)
        return view.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: nil)
    }
}

// MARK: - Console view

@MainActor
final class PS2ConsoleSCNView: SCNView {
    weak var runtime: PS2RuntimeModel?
    var layoutSpec: PS2GameLayout? {
        didSet { if layoutSpec != oldValue { setNeedsLayout() } }
    }
    var onLongPress: (() -> Void)?
    var controlsLocked = false {
        didSet { if controlsLocked { cancelPress() } }
    }
    private let ring = CAShapeLayer()
    private var pressTouch: ObjectIdentifier?
    private var pressOrigin = CGPoint.zero
    private var pressTask: Task<Void, Never>?
    private var idleWork: DispatchWorkItem?
    static let holdDuration: TimeInterval = 1.0

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        isMultipleTouchEnabled = true
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 0
        ring.opacity = 0
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "远处的 PS2 主机")
        accessibilityHint = String(localized: "长按 1 秒退出游戏")
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "退出游戏")) { [weak self] _ in
            self?.onLongPress?()
            return true
        }]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        pressTask?.cancel()
        idleWork?.cancel()
    }

    func requestRender(for duration: TimeInterval) {
        idleWork?.cancel()
        isPlaying = true
        rendersContinuously = true
        let work = DispatchWorkItem { [weak self] in
            self?.rendersContinuously = false
            self?.isPlaying = false
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, duration), execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let spec = layoutSpec, let runtime else { return }
        runtime.updateConsoleViewport(size: bounds.size, layout: spec)
        let rect = runtime.consoleScreenRect.insetBy(dx: -12, dy: -10)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath
        CATransaction.commit()
    }

    private var pressTarget: CGRect {
        (runtime?.consoleScreenRect ?? .zero).insetBy(dx: -18, dy: -18)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !controlsLocked, pressTouch == nil,
              let touch = touches.first(where: { pressTarget.contains($0.location(in: self)) }) else { return }
        pressTouch = ObjectIdentifier(touch)
        pressOrigin = touch.location(in: self)
        UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred(intensity: 0.5, at: pressOrigin)
        runtime?.setPowerBlinking(true)
        requestRender(for: Self.holdDuration + 0.2)
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = Self.holdDuration
        ring.removeAllAnimations()
        ring.strokeEnd = 1
        ring.opacity = 1
        ring.add(animation, forKey: "progress")
        pressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard let self, !Task.isCancelled, self.pressTouch != nil else { return }
            UINotificationFeedbackGenerator(view: self).notificationOccurred(.success, at: self.pressOrigin)
            self.finishPress()
            self.onLongPress?()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let id = pressTouch, let touch = touches.first(where: { ObjectIdentifier($0) == id }) else { return }
        let p = touch.location(in: self)
        if hypot(p.x - pressOrigin.x, p.y - pressOrigin.y) > 24 { cancelPress() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endPress(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endPress(touches) }

    private func endPress(_ touches: Set<UITouch>) {
        guard let id = pressTouch, touches.contains(where: { ObjectIdentifier($0) == id }) else { return }
        cancelPress()
    }

    private func finishPress() {
        pressTask = nil
        pressTouch = nil
        runtime?.setPowerBlinking(false)
        ring.removeAllAnimations()
        ring.opacity = 0
        ring.strokeEnd = 0
    }

    func cancelPress() {
        pressTask?.cancel()
        finishPress()
    }
}

/// Forwards touches over the distant console to `PS2ConsoleSCNView`, which measures them in
/// its own coordinates (`UITouch.location(in:)`) and runs the 1 s hold.
final class PS2ConsolePressForwarder: UIView {
    weak var console: PS2ConsoleSCNView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { console?.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { console?.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { console?.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { console?.touchesCancelled(touches, with: event) }
}

private struct PS2ConsolePressArea: UIViewRepresentable {
    let model: PS2RuntimeModel

    func makeUIView(context: Context) -> PS2ConsolePressForwarder {
        let view = PS2ConsolePressForwarder(frame: .zero)
        view.console = model.consoleView as? PS2ConsoleSCNView
        return view
    }

    func updateUIView(_ view: PS2ConsolePressForwarder, context: Context) {
        view.console = model.consoleView as? PS2ConsoleSCNView
    }
}

private struct PS2ConsoleSceneView: UIViewRepresentable {
    let model: PS2RuntimeModel
    let layout: PS2GameLayout
    let controlsLocked: Bool
    let onLongPress: () -> Void

    func makeUIView(context: Context) -> PS2ConsoleSCNView {
        let view = PS2ConsoleSCNView(frame: .zero)
        view.scene = model.consoleScene
        view.pointOfView = model.consoleCameraNode
        view.runtime = model
        view.backgroundColor = PS2RuntimeModel.backgroundColor
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        model.consoleView = view
        model.renderRequest = { [weak view] duration in view?.requestRender(for: duration) }
        update(view)
        return view
    }

    func updateUIView(_ view: PS2ConsoleSCNView, context: Context) { update(view) }

    private func update(_ view: PS2ConsoleSCNView) {
        view.layoutSpec = layout
        view.controlsLocked = controlsLocked
        view.onLongPress = onLongPress
    }
}

// MARK: - Top screen

private struct PS2ScreenView: View {
    @ObservedObject var feed: PS2ScreenFeed
    let core: PS2WebCore?
    let title: String
    let cover: CGImage?
    /// The picture inside this (whole TV region) view. The core's page draws a blurred copy of
    /// the picture around it, so the picture fades into its surroundings instead of ending at a
    /// hard edge against the black.
    let pictureRect: CGRect

    var body: some View {
        ZStack {
            Color.black
            if let core {
                PS2CoreScreen(core: core, pictureRect: pictureRect,
                              placeholder: { status in AnyView(inPicture(placeholder(status: status))) })
            } else if let image = feed.image {
                // PS2 output is stretched to the display aspect, like a TV.
                inPicture(Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium))
            } else {
                inPicture(placeholder(status: String(localized: "等待 PS2 内核")))
            }
        }
        .clipped()
        // Display only. `clipped()` does not clip hit-testing: the scaled-to-fill cover backdrop
        // would otherwise claim touches far below this frame, over the console's long-press.
        .allowsHitTesting(false)
    }

    private func inPicture(_ content: some View) -> some View {
        content
            .frame(width: pictureRect.width, height: pictureRect.height)
            .clipped()
            .position(x: pictureRect.midX, y: pictureRect.midY)
    }

    private func placeholder(status: String) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let coverHeight = size.height * 0.68
            ZStack {
                if let cover {
                    Image(decorative: cover, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 26)
                        .opacity(0.6)
                        .clipped()
                }
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: size.width * 0.05) {
                    Group {
                        if let cover {
                            Image(decorative: cover, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.12))
                                .aspectRatio(129.5 / 183, contentMode: .fit)
                                .overlay(Image(systemName: "opticaldisc").foregroundStyle(.white.opacity(0.4)))
                        }
                    }
                    .frame(maxWidth: size.width * 0.4, maxHeight: coverHeight)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 4)

                    VStack(alignment: .leading, spacing: size.height * 0.04) {
                        Text(title)
                            .font(.system(size: max(13, min(24, size.height * 0.075)), weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.6)
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white.opacity(0.7))
                            Text(status)
                                .font(.system(size: max(11, min(15, size.height * 0.05)), weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: size.width * 0.42, alignment: .leading)
                }
                .padding(.horizontal, size.width * 0.06)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// The PS2 core's WebKit view once it has drawn a frame; the cover placeholder with the boot
/// status before that (or the error when the core stopped).
private struct PS2CoreScreen: View {
    @ObservedObject var core: PS2WebCore
    let pictureRect: CGRect
    let placeholder: (String) -> AnyView

    var body: some View {
        ZStack {
            PS2CoreWebView(webView: core.webView)
                .opacity(core.hasFrame ? 1 : 0)
                .onAppear { core.setPicture(pictureRect) }
                .onChange(of: pictureRect) { _, rect in core.setPicture(rect) }
            if !core.hasFrame {
                placeholder(status)
            } else if case .failed(let message) = core.state {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var status: String {
        if case .failed(let message) = core.state { return message }
        return String(localized: "正在启动…")
    }
}

private struct PS2CoreWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        if webView.superview !== view {
            webView.frame = view.bounds
            view.addSubview(webView)
        }
    }
}

/// Forwards `session.topImage` to the screen until the PS2 core presents frames directly
/// through `PS2RuntimeModel.presentFrame(_:)`.
private struct PS2SessionFrameForwarder: View {
    @ObservedObject var session: EmulatorSession
    let model: PS2RuntimeModel

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { forward() }
            .onReceive(session.objectWillChange) { _ in
                DispatchQueue.main.async { forward() }
            }
    }

    private func forward() {
        guard !session.isPSP, !session.isN64 else { return }
        model.presentFrame(session.topImage)
    }
}

// MARK: - Game view

/// PS2 game screen: top 4:3 (or 16:9) picture, the distant console in the gap (long-press 1 s
/// to exit), the DualShock 2 at the bottom with a live cable to the console.
struct PS2GameView: View {
    private let session: EmulatorSession?
    private let game: GameLibraryItem?
    private let title: String
    private let cover: CGImage?
    private let onExitRequested: () -> Void
    @StateObject private var model: PS2RuntimeModel

    /// `game` prints the disc that sits in the console and flies back to its case on exit.
    init(session: EmulatorSession?, game: GameLibraryItem? = nil, title: String, cover: CGImage?,
         model: PS2RuntimeModel? = nil, onExitRequested: @escaping () -> Void) {
        self.session = session
        self.game = game
        self.title = title
        self.cover = cover
        self.onExitRequested = onExitRequested
        _model = StateObject(wrappedValue: model ?? PS2RuntimeModel())
    }

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { proxy in
                let size = proxy.size
                // iPhone Duo ignores its camera; elsewhere keep clear of the island/notch.
                let top = DuoOrientation.isDuoDevice ? 0 : insets.top
                let bottom = DuoOrientation.isDuoDevice ? 4 : max(4, insets.bottom * 0.4)
                let layout = PS2GameLayout(size: size, topInset: top, bottomInset: bottom,
                                           screenAspect: model.screenAspect,
                                           footprint: model.controller.footprint,
                                           shoulderClearance: model.controller.shoulderClearance)
                let region = layout.controllerRegion
                ZStack {
                    PS2ConsoleSceneView(model: model, layout: layout, controlsLocked: model.controlsLocked,
                                        onLongPress: onExitRequested)
                        .frame(width: size.width, height: size.height)
                        .position(x: size.width / 2, y: size.height / 2)

                    // The TV's letterbox around the picture.
                    Color.black
                        .frame(width: layout.screenRegion.width, height: layout.screenRegion.height)
                        .position(x: layout.screenRegion.midX, y: layout.screenRegion.midY)
                        .opacity(model.foregroundHidden ? 0 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    PS2ScreenView(feed: model.screenFeed, core: model.core, title: title, cover: cover,
                                  pictureRect: layout.screenRect.offsetBy(dx: -layout.screenRegion.minX,
                                                                          dy: -layout.screenRegion.minY))
                        .ps2CRTShutdown(model.crt)
                        .frame(width: layout.screenRegion.width, height: layout.screenRegion.height)
                        .position(x: layout.screenRegion.midX, y: layout.screenRegion.midY)
                        .opacity(model.foregroundHidden ? 0 : 1)
                        .accessibilityLabel(title)

                    PS2ControllerView(model: model.controller, session: model.core ?? session,
                                      bodyRect: layout.bodyRect.offsetBy(dx: -region.minX, dy: -region.minY),
                                      controlsLocked: model.controlsLocked)
                        .frame(width: region.width, height: region.height)
                        .position(x: region.midX, y: region.midY)
                        .opacity(model.foregroundHidden ? 0 : 1)
                        .allowsHitTesting(!model.foregroundHidden)

                    // Above the controller: SwiftUI hands a touch to the topmost representable
                    // whose frame contains it, and the controller's frame reaches past the console.
                    let press = layout.consoleRect.insetBy(dx: -18, dy: -18)
                    PS2ConsolePressArea(model: model)
                        .frame(width: press.width, height: press.height)
                        .position(x: press.midX, y: press.midY)
                        .allowsHitTesting(!model.foregroundHidden && !model.controlsLocked)
                        .accessibilityHidden(true)

                    if let session {
                        PS2SessionFrameForwarder(session: session, model: model)
                            .frame(width: 0, height: 0)
                    }
                }
                .frame(width: size.width, height: size.height)
                .animation(.easeInOut(duration: 0.25), value: model.foregroundHidden)
            }
            .ignoresSafeArea()
        }
        .background(Color(PS2RuntimeModel.backgroundColor).ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            PS2RuntimeModel.active = model
            model.seatDisc(for: game)
            if session == nil { model.startCore(for: game) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ps2-hittest-selftest") {
                Task { @MainActor in
                    // After the entry camera move (~1.4 s) has handed over to this screen.
                    try? await Task.sleep(for: .seconds(3))
                    model.logConsoleHitTest(title: title)
                    try? await Task.sleep(for: .seconds(0.3))
                    onExitRequested()
                }
            }
            #endif
        }
        .onDisappear {
            if PS2RuntimeModel.active === model { PS2RuntimeModel.active = nil }
            session?.releaseAllInputs()
            model.tearDownCore()
        }
    }
}

// MARK: - Debug preview

#if DEBUG
/// Stand-alone PS2 game screen for previews and the `-ps2-game-preview` launch argument.
/// Extra arguments: `-ps2-preview-widescreen`, `-ps2-preview-crt` (freezes the CRT line),
/// `-ps2-preview-pose` (presses a few controls), `-ps2-controls-test` (hit-test self check).
struct PS2GameViewPreviewHost: View {
    @StateObject private var model = PS2RuntimeModel()

    var body: some View {
        PS2GameView(session: nil, title: "Duo Demo Disc", cover: Self.sampleCover, model: model) {
            model.controlsLocked = true
            model.crt.play {
                model.setTrayOpen(1, duration: 0.9)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    model.setTrayOpen(0, duration: 0.9)
                    model.crt.reset()
                    model.controlsLocked = false
                }
            }
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ps2-preview-widescreen") { model.screenAspect = 16.0 / 9.0 }
            if arguments.contains("-ps2-preview-crt") { model.crt.debugElapsed = 0.2 }
            if arguments.contains("-ps2-preview-eject") { model.setEjectBlinking(true) }
        }
    }

    static let sampleCover: CGImage? = {
        let size = CGSize(width: 518, height: 732)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.1, green: 0.2, blue: 0.55, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.1, blue: 0.35, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.black.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 58))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 88, weight: .heavy), .foregroundColor: UIColor.white
            ]
            ("DUO\nDEMO" as NSString).draw(in: CGRect(x: 40, y: 220, width: 440, height: 260), withAttributes: attributes)
        }
        return image.cgImage
    }()
}

#Preview("PS2 Game") {
    PS2GameViewPreviewHost()
}
#endif
