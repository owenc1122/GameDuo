import SwiftUI
import SceneKit
import UIKit

// MARK: - Layout

/// Portrait layout shared by every device: game screen on top, distant console in the gap,
/// DualShock 2 (with the flat shoulder row above it) at the bottom. All rects are in
/// PS2GameView coordinates (full screen, safe areas ignored).
struct PS2GameLayout: Equatable {
    var size: CGSize
    var screenRect: CGRect
    var gapRect: CGRect
    var controllerRegion: CGRect
    var bodyRect: CGRect
    /// Controller scale, points per model metre.
    var pointsPerMeter: CGFloat

    init(size: CGSize, topInset: CGFloat, bottomInset: CGFloat, screenAspect: CGFloat,
         footprint: PS2ControllerModel.Footprint) {
        self.size = size
        let width = max(1, size.width)
        let available = max(1, size.height - topInset - bottomInset)
        let margin = max(8, width * 0.02)
        let fullScreenHeight = width / screenAspect
        let fullPPM = (width - 2 * margin) / CGFloat(footprint.width)
        let controllerDepth = CGFloat(footprint.depth) + PS2ControllerMetrics.shoulderRowDepth
        let fullControllerHeight = controllerDepth * fullPPM
        let minimumGap = max(110, available * 0.17)
        let scale = min(1, max(0.2, (available - minimumGap) / (fullScreenHeight + fullControllerHeight)))

        let screenHeight = (fullScreenHeight * scale).rounded()
        let screenWidth = (screenHeight * screenAspect).rounded()
        screenRect = CGRect(x: ((width - screenWidth) / 2).rounded(), y: topInset,
                            width: screenWidth, height: screenHeight)
        pointsPerMeter = fullPPM * scale
        let bodySize = CGSize(width: CGFloat(footprint.width) * pointsPerMeter,
                              height: CGFloat(footprint.depth) * pointsPerMeter)
        bodyRect = CGRect(x: (width - bodySize.width) / 2, y: size.height - bottomInset - bodySize.height,
                          width: bodySize.width, height: bodySize.height)
        let rowHeight = PS2ControllerMetrics.shoulderRowDepth * pointsPerMeter
        controllerRegion = CGRect(x: 0, y: bodyRect.minY - rowHeight, width: width,
                                  height: size.height - (bodyRect.minY - rowHeight))
        gapRect = CGRect(x: 0, y: screenRect.maxY, width: width,
                         height: max(0, controllerRegion.minY - screenRect.maxY))
    }

    /// Where the controller-side cable stub ends, and the cable's on-screen radius there.
    func cableStart(footprint: PS2ControllerModel.Footprint) -> (point: CGPoint, radius: CGFloat) {
        let center = footprint.center
        let exit = PS2ControllerMetrics.cableExit
        let point = CGPoint(x: bodyRect.midX + CGFloat(exit.x - center.x) * pointsPerMeter,
                            y: bodyRect.midY + CGFloat(PS2ControllerMetrics.cableStubEndZ - center.y) * pointsPerMeter)
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
        let key = [size.width, size.height, layout.gapRect.minY, layout.gapRect.height,
                   layout.bodyRect.minY, layout.bodyRect.width]
        guard key != viewportKey else { return }
        viewportKey = key
        viewSize = size
        screenRect = layout.screenRect
        let gap = layout.gapRect
        let f = size.height / 2 / tan(Self.fieldOfView / 2 * .pi / 180)
        focalLength = f
        // Console size in the gap: a fraction of the width, bounded by the gap height.
        let consoleWidth = max(60, min(gap.width * 0.40, gap.height * 1.45, 360))
        let distance = Float(0.301 * f / consoleWidth)
        cameraDistance = distance
        let target = SIMD3<Float>(0.0005, 0.039, 0)
        let elevation: Float = 13 * .pi / 180
        let azimuth: Float = -16 * .pi / 180
        let direction = SIMD3<Float>(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        let anchor = CGPoint(x: gap.midX, y: gap.minY + gap.height * 0.44)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        consoleCameraNode.simdPosition = target + direction * distance
        consoleCameraNode.simdLook(at: target, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        // Turn the camera so the console lands at the gap's anchor instead of the view centre.
        let yaw = Float(atan((anchor.x - size.width / 2) / f))
        let pitch = Float(atan((size.height / 2 - anchor.y) / f))
        consoleCameraNode.simdLocalRotate(by: simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        consoleCameraNode.simdLocalRotate(by: simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0)))
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

    /// A sagging tube from the controller's cable stub to the plug in PORT_CTRL_1. The near end
    /// is placed on the camera ray through the stub's screen point at the depth where a 4 mm
    /// cable has the stub's on-screen width, so both views meet seamlessly.
    private func rebuildCable(layout: PS2GameLayout) {
        guard let port = portNode else { return }
        let start = layout.cableStart(footprint: controller.footprint)
        guard start.radius > 0 else { return }
        let radius = PS2ControllerMetrics.cableRadius
        let nearDepth = radius * Float(focalLength / start.radius)
        let p0 = unproject(start.point, depth: nearDepth)
        let up = consoleCameraNode.simdConvertVector(simd_normalize(SIMD3<Float>(0, 1, -0.8)), to: nil)
        let portPosition = port.simdWorldPosition
        let plugRear = portPosition + SIMD3(0, 0, 0.048)
        let drop = plugRear + SIMD3(0, -0.02, 0.045)
        // Shaped on screen: up from the stub, a gentle S across the gap, onto the floor just
        // in front of the console, then up into the plug. Depth grows monotonically, so the
        // tube thins with distance.
        let gap = layout.gapRect
        let floorY = min(gap.maxY - 6, consoleScreenRect.maxY + max(8, (gap.maxY - consoleScreenRect.maxY) * 0.4))
        var plugFloor = SIMD3<Float>(portPosition.x + 0.025, 0.004, portPosition.z + 0.15)
        var floorProjection = project(plugFloor)
        if floorProjection.point.y > floorY {
            plugFloor = unproject(CGPoint(x: floorProjection.point.x, y: floorY), depth: floorProjection.depth)
            floorProjection = project(plugFloor)
        }
        let s0 = start.point
        let farDepth = floorProjection.depth
        let rise = CGPoint(x: s0.x, y: s0.y - (s0.y - floorY) * 0.4)
        let bend = CGPoint(x: s0.x + (floorProjection.point.x - s0.x) * 0.3 + gap.width * 0.07,
                           y: floorY + (s0.y - floorY) * 0.18)
        let points = [p0 - up * 0.006, p0,
                      unproject(rise, depth: nearDepth * 1.2),
                      unproject(bend, depth: nearDepth + (farDepth - nearDepth) * 0.45),
                      plugFloor, drop, plugRear]
        let path = Self.catmullRom(points, samplesPerSegment: 14)
        let geometry = Self.tube(path, radius: radius, sides: 12)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        material.roughness.contents = 0.38
        material.metalness.contents = 0.0
        geometry.materials = [material]
        cableNode.geometry = geometry
    }

    static func catmullRom(_ points: [SIMD3<Float>], samplesPerSegment: Int) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }
        let extended = [2 * points[0] - points[1]] + points + [2 * points[points.count - 1] - points[points.count - 2]]
        var result: [SIMD3<Float>] = []
        for i in 0..<(points.count - 1) {
            let p0 = extended[i], p1 = extended[i + 1], p2 = extended[i + 2], p3 = extended[i + 3]
            // Centripetal parameterisation avoids loops on uneven spacing.
            let t0: Float = 0
            let t1 = t0 + max(1e-4, sqrt(simd_distance(p0, p1)))
            let t2 = t1 + max(1e-4, sqrt(simd_distance(p1, p2)))
            let t3 = t2 + max(1e-4, sqrt(simd_distance(p2, p3)))
            for s in 0..<samplesPerSegment {
                let t = t1 + (t2 - t1) * Float(s) / Float(samplesPerSegment)
                let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
                let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
                let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
                let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
                let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
                result.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
            }
        }
        result.append(points[points.count - 1])
        return result
    }

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
        // Disc +Y (label) → camera +Z, label top (disc −Z) → camera +Y, then a slight lean back.
        let rotation = simd_quatf(angle: .pi / 2 - 0.2, axis: SIMD3(1, 0, 0))
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
    let title: String
    let cover: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image = feed.image {
                // PS2 output is stretched to the display aspect, like a TV.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                placeholder
            }
        }
        .clipped()
    }

    private var placeholder: some View {
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
                            Text(String(localized: "等待 PS2 内核"))
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
                                           footprint: model.controller.footprint)
                let region = layout.controllerRegion
                ZStack {
                    PS2ConsoleSceneView(model: model, layout: layout, controlsLocked: model.controlsLocked,
                                        onLongPress: onExitRequested)
                        .frame(width: size.width, height: size.height)
                        .position(x: size.width / 2, y: size.height / 2)

                    PS2ScreenView(feed: model.screenFeed, title: title, cover: cover)
                        .ps2CRTShutdown(model.crt)
                        .frame(width: layout.screenRect.width, height: layout.screenRect.height)
                        .position(x: layout.screenRect.midX, y: layout.screenRect.midY)
                        .opacity(model.foregroundHidden ? 0 : 1)
                        .accessibilityLabel(title)

                    PS2ControllerView(model: model.controller, session: session,
                                      bodyRect: layout.bodyRect.offsetBy(dx: -region.minX, dy: -region.minY),
                                      controlsLocked: model.controlsLocked)
                        .frame(width: region.width, height: region.height)
                        .position(x: region.midX, y: region.midY)
                        .opacity(model.foregroundHidden ? 0 : 1)
                        .allowsHitTesting(!model.foregroundHidden)

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
        }
        .onDisappear {
            if PS2RuntimeModel.active === model { PS2RuntimeModel.active = nil }
            session?.releaseAllInputs()
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
