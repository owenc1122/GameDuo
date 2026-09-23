import SwiftUI
import SceneKit
import UIKit

enum PS2Shoulder: CaseIterable {
    case l1, l2, r1, r2

    var joypadID: Int {
        switch self {
        case .l1: 10
        case .r1: 11
        case .l2: 12
        case .r2: 13
        }
    }

    var label: String {
        switch self {
        case .l1: "L1"
        case .l2: "L2"
        case .r1: "R1"
        case .r2: "R2"
        }
    }

    var isLeft: Bool { self == .l1 || self == .l2 }
    var isTrigger: Bool { self == .l2 || self == .r2 }
}

/// Model-space (metre) numbers for the top-down DualShock 2 layout. See PS2_Model/README.md.
enum PS2ControllerMetrics {
    /// Space reserved above the body for the flat L1/L2/R1/R2 buttons.
    static let shoulderRowDepth: CGFloat = 0.028
    static let cableRadius: Float = 0.002
    static let cableExit = SIMD3<Float>(0, 0.0385, -0.033)
    /// The model's ribbed strain-relief boot (`CABLE` mesh): (offset along the cable from
    /// `cableExit.z`, radius) in metres, from inside the body out to the boot's end face.
    static let bootProfile: [(z: Float, r: Float)] = [
        (0.004, 0.00475), (0, 0.00475), (-0.0003, 0.00452), (-0.0009, 0.00407), (-0.0023, 0.00407),
        (-0.0029, 0.00367), (-0.0037, 0.00367), (-0.0043, 0.00362), (-0.0049, 0.00326), (-0.0057, 0.00326),
        (-0.0063, 0.00317), (-0.0069, 0.00285), (-0.008, 0.00285), (-0.008, 0)
    ]
    /// Model Z of the boot's end face, where the live cable comes out.
    static let cableBootEndZ: Float = cableExit.z - 0.008
    static let stickTilt: Float = 0.4363
    static let stickPress: Float = 0.0008
    static let dpadTilt: Float = 0.0873
    static let buttonTravel: [String: Float] = [
        "BTN_TRIANGLE": 0.002, "BTN_CIRCLE": 0.002, "BTN_CROSS": 0.002, "BTN_SQUARE": 0.002,
        "BTN_SELECT": 0.001, "BTN_START": 0.001, "BTN_ANALOG": 0.0008
    ]
    /// libretro joypad ids for the face/system buttons.
    static let buttonIDs: [String: Int] = [
        "BTN_CROSS": 0, "BTN_SQUARE": 1, "BTN_SELECT": 2, "BTN_START": 3,
        "BTN_CIRCLE": 8, "BTN_TRIANGLE": 9
    ]
    static let dpadIDs = (up: 4, down: 5, left: 6, right: 7)

    /// Matte black PVC with a soft sheen, shared by the boot and the live cable.
    @MainActor static func cableMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.105, green: 0.105, blue: 0.112, alpha: 1)
        material.roughness.contents = 0.34
        material.metalness.contents = 0.0
        return material
    }
    static let l3 = 14
    static let r3 = 15
}

/// The DualShock 2 scene seen straight down with an orthographic camera.
@MainActor
final class PS2ControllerModel {
    struct Footprint {
        var minX: Float = -0.0785, maxX: Float = 0.0785, minZ: Float = -0.0474, maxZ: Float = 0.0475
        var width: Float { maxX - minX }
        var depth: Float { maxZ - minZ }
        var center: SIMD2<Float> { SIMD2((minX + maxX) / 2, (minZ + maxZ) / 2) }
    }

    let scene: SCNScene
    let cameraNode = SCNNode()
    private(set) var footprint = Footprint()
    /// The model's own plug, detached so the console scene can seat it in `PORT_CTRL_1`.
    private(set) var plugTemplate: SCNNode?
    private(set) var analogMode = true
    var onVisualChange: (() -> Void)?
    private var nodes: [String: SCNNode] = [:]
    private var rest: [String: SCNVector3] = [:]
    private var shadeMaterials: [String: [SCNMaterial]] = [:]
    private var ledMaterials: [SCNMaterial] = []
    private var ledOffDiffuse: Any?
    /// Current mapping from model XZ to view points (set by `updateViewport`).
    private(set) var bodyRect: CGRect = .zero
    private(set) var pointsPerMeter: CGFloat = 1

    static let movableNames = [
        "DPAD", "BTN_TRIANGLE", "BTN_CIRCLE", "BTN_CROSS", "BTN_SQUARE", "BTN_SELECT", "BTN_START",
        "BTN_ANALOG", "STICK_L", "STICK_R", "L1", "R1", "L2", "R2"
    ]

    init() {
        if let url = Bundle.main.url(forResource: "PS2-DualShock2", withExtension: "usdz"),
           let loaded = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            scene = loaded
        } else {
            scene = SCNScene()
        }
        scene.rootNode.enumerateChildNodes { node, _ in node.removeAllAnimations() }
        for name in Self.movableNames {
            guard let node = scene.rootNode.childNode(withName: name, recursively: true) else { continue }
            nodes[name] = node
            rest[name] = node.position
            // Private material copies so one pressed key can be shaded on its own.
            var materials: [SCNMaterial] = []
            func bind(_ candidate: SCNNode) {
                guard let geometry = candidate.geometry else { return }
                let copies = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
                geometry.materials = copies
                materials.append(contentsOf: copies)
            }
            bind(node)
            node.enumerateChildNodes { child, _ in bind(child) }
            shadeMaterials[name] = materials
        }
        // The static cable and plug are replaced by the live cable to the console.
        scene.rootNode.childNode(withName: "CABLE", recursively: true)?.isHidden = true
        if let plug = scene.rootNode.childNode(withName: "CTRL_PLUG", recursively: true) {
            plugTemplate = plug.clone()
            (plug.parent ?? plug).isHidden = true
        }
        #if DEBUG
        let missing = Self.movableNames.filter { nodes[$0] == nil }
        print(missing.isEmpty ? "DUO_PS2_DS2_RIG_PASS: \(Self.movableNames.count) movable parts"
                              : "DUO_PS2_DS2_RIG_FAIL: missing=\(missing.joined(separator: ","))")
        #endif
        measureFootprint()
        bindLED()
        addCableBoot()
        setAnalogMode(true)

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 0.06
        camera.zNear = 0.05
        camera.zFar = 1
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.5, 0)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(cameraNode)

        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, at position: SCNVector3? = nil) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.intensity = intensity
            if let position {
                node.position = position
                node.look(at: SCNVector3(0, 0.03, 0))
            }
            scene.rootNode.addChildNode(node)
        }
        light(.directional, 850, at: SCNVector3(-0.12, 0.35, 0.18))
        light(.directional, 380, at: SCNVector3(0.2, 0.25, -0.15))
        light(.ambient, 260)
    }

    private func measureFootprint() {
        guard let root = scene.rootNode.childNode(withName: "DUALSHOCK2", recursively: true) else { return }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        func visit(_ node: SCNNode) {
            if node.isHidden || node.name == "CABLE" || node.name == "CTRL_PLUG_MOUNT" { return }
            if node.geometry != nil {
                let (a, b) = node.boundingBox
                for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                    let p = node.simdConvertPosition(SIMD3(x, y, z), to: nil)
                    minimum = simd_min(minimum, p)
                    maximum = simd_max(maximum, p)
                } } }
            }
            node.childNodes.forEach(visit)
        }
        visit(root)
        guard minimum.x < maximum.x else { return }
        footprint = Footprint(minX: minimum.x, maxX: maximum.x, minZ: minimum.z, maxZ: maximum.z)
    }

    private func bindLED() {
        guard let led = scene.rootNode.childNode(withName: "LED_ANALOG", recursively: true) else { return }
        func bind(_ node: SCNNode) {
            guard let geometry = node.geometry else { return }
            let copies = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            geometry.materials = copies
            ledMaterials.append(contentsOf: copies)
        }
        bind(led)
        led.enumerateChildNodes { child, _ in bind(child) }
        ledOffDiffuse = ledMaterials.first?.diffuse.contents
    }

    /// The ribbed strain-relief boot at the cable exit (the live cable to the console leaves
    /// its end face, drawn by the console scene), lathed from the model's profile.
    private func addCableBoot() {
        let exit = PS2ControllerMetrics.cableExit
        let sides = 28
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        let profile = PS2ControllerMetrics.bootProfile
        for (a, b) in zip(profile, profile.dropFirst()) {
            // Flat-shaded per profile segment, so the ribs read as crisp steps.
            let dz = b.z - a.z, dr = b.r - a.r
            let length = max(1e-6, hypot(dz, dr))
            let (nr, nz) = (-dz / length, dr / length)
            let base = UInt32(vertices.count)
            for point in [a, b] {
                for j in 0...sides {
                    let angle = Float(j) / Float(sides) * 2 * .pi
                    vertices.append(SCNVector3(exit.x + point.r * cos(angle), exit.y + point.r * sin(angle), exit.z + point.z))
                    normals.append(SCNVector3(nr * cos(angle), nr * sin(angle), nz))
                }
            }
            let ring = UInt32(sides + 1)
            for j in 0..<UInt32(sides) {
                indices += [base + j, base + j + 1, base + ring + j, base + j + 1, base + ring + j + 1, base + ring + j]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [PS2ControllerMetrics.cableMaterial()]
        geometry.firstMaterial?.isDoubleSided = true
        let boot = SCNNode(geometry: geometry)
        boot.name = "DUO_CABLE_BOOT"
        scene.rootNode.addChildNode(boot)
    }

    // MARK: Viewport

    /// Fits the measured body into `bodyRect` (view points) of a view of `size`.
    func updateViewport(size: CGSize, bodyRect: CGRect) {
        guard size.width > 0, size.height > 0, bodyRect.width > 0 else { return }
        let ppm = bodyRect.width / CGFloat(footprint.width)
        guard ppm != pointsPerMeter || bodyRect != self.bodyRect || size.height != lastHeight else { return }
        pointsPerMeter = ppm
        self.bodyRect = bodyRect
        lastHeight = size.height
        let center = footprint.center
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.camera?.orthographicScale = Double(size.height / ppm / 2)
        cameraNode.position.x = center.x - Float((bodyRect.midX - size.width / 2) / ppm)
        cameraNode.position.z = center.y - Float((bodyRect.midY - size.height / 2) / ppm)
        SCNTransaction.commit()
        onVisualChange?()
    }
    private var lastHeight: CGFloat = 0

    /// Top-down projection of a model-space XZ point into view points.
    func viewPoint(x: Float, z: Float) -> CGPoint {
        let center = footprint.center
        return CGPoint(x: bodyRect.midX + CGFloat(x - center.x) * pointsPerMeter,
                       y: bodyRect.midY + CGFloat(z - center.y) * pointsPerMeter)
    }

    /// Rest position in model space (L1/R1 sit under rotated *_MOUNT nodes).
    func restPoint(_ name: String) -> CGPoint {
        guard let position = rest[name], let node = nodes[name] else { return .zero }
        let world = node.parent?.convertPosition(position, to: nil) ?? position
        return viewPoint(x: world.x, z: world.z)
    }

    func points(millimetres: CGFloat) -> CGFloat { millimetres / 1000 * pointsPerMeter }

    /// Clear half-width (model metres, from the body centre) between the flat shoulder buttons'
    /// touch areas (22 mm wide, +3 mm slop), where the distant console may sit.
    var shoulderClearance: CGFloat {
        let offsets = ["L1", "R1"].compactMap { name -> Float? in
            guard let position = rest[name], let node = nodes[name] else { return nil }
            let world = node.parent?.convertPosition(position, to: nil) ?? position
            return abs(world.x - footprint.center.x)
        }
        guard let nearest = offsets.min() else { return 0.03 }
        return max(0.01, CGFloat(nearest) - 0.014)
    }

    // MARK: Motion

    /// On-demand rendering may stop before an implicit animation's last frame; render once
    /// more when it completes.
    private var settleRender: () -> Void {
        { [weak self] in DispatchQueue.main.async { self?.onVisualChange?() } }
    }

    private func animate(_ pressed: Bool, _ changes: () -> Void) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = pressed ? 0.045 : 0.09
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: pressed ? .easeIn : .easeOut)
        SCNTransaction.completionBlock = settleRender
        changes()
        SCNTransaction.commit()
        onVisualChange?()
    }

    /// Seen straight down, millimetres of travel are invisible; a slight sink scale and
    /// darkening make the (real) travel read.
    private func shade(_ name: String, _ amount: CGFloat) {
        let color = UIColor(white: 1 - amount, alpha: 1)
        shadeMaterials[name]?.forEach { $0.multiply.contents = color }
    }

    func setButton(_ name: String, pressed: Bool) {
        guard let node = nodes[name], let rest = rest[name] else { return }
        let travel = PS2ControllerMetrics.buttonTravel[name] ?? 0.001
        let sink: Float = pressed ? 0.94 : 1
        animate(pressed) {
            node.position = SCNVector3(rest.x, rest.y - (pressed ? travel : 0), rest.z)
            node.scale = SCNVector3(sink, 1, sink)
            shade(name, pressed ? 0.3 : 0)
        }
    }

    /// dx: −1 left … 1 right, dy: −1 up (toward the shoulders) … 1 down.
    func setDpad(dx: Int, dy: Int) {
        guard let node = nodes["DPAD"] else { return }
        let scale: Float = dx != 0 && dy != 0 ? 0.75 : 1
        let tilt = PS2ControllerMetrics.dpadTilt * scale
        animate(dx != 0 || dy != 0) {
            node.eulerAngles = SCNVector3(Float(dy) * tilt, 0, -Float(dx) * tilt)
            shade("DPAD", dx != 0 || dy != 0 ? 0.18 : 0)
        }
    }

    /// x, y ∈ −1…1 in screen directions (+y toward the grips).
    func setStick(_ stick: EmulatorSession.PS2Stick, x: CGFloat, y: CGFloat, pressedIn: Bool, animated: Bool) {
        let name = stick == .left ? "STICK_L" : "STICK_R"
        guard let node = nodes[name], let rest = rest[name] else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.12 : 0.02
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        SCNTransaction.completionBlock = settleRender
        node.eulerAngles = SCNVector3(Float(y) * PS2ControllerMetrics.stickTilt, 0,
                                      -Float(x) * PS2ControllerMetrics.stickTilt)
        node.position = SCNVector3(rest.x, rest.y - (pressedIn ? PS2ControllerMetrics.stickPress : 0), rest.z)
        let sink: Float = pressedIn ? 0.95 : 1
        node.scale = SCNVector3(sink, 1, sink)
        shade(name, pressedIn ? 0.3 : 0)
        SCNTransaction.commit()
        onVisualChange?()
    }

    func setShoulder(_ shoulder: PS2Shoulder, pressed: Bool) {
        let name = shoulder.label
        guard let node = nodes[name], let rest = rest[name] else { return }
        animate(pressed) {
            if shoulder.isTrigger {
                node.eulerAngles.x = pressed ? -0.1396 : 0
            } else {
                node.position = SCNVector3(rest.x, rest.y - (pressed ? 0.002 : 0), rest.z)
            }
        }
    }

    func setAnalogMode(_ on: Bool) {
        analogMode = on
        let red = UIColor(red: 1, green: 0.17, blue: 0.11, alpha: 1)
        for material in ledMaterials {
            material.diffuse.contents = on ? red : (ledOffDiffuse ?? UIColor(red: 0.29, green: 0.055, blue: 0.047, alpha: 1))
            material.emission.contents = on ? red : UIColor.black
            material.emission.intensity = on ? 1.3 : 0
        }
        onVisualChange?()
    }

    func releaseAllVisuals() {
        for name in PS2ControllerMetrics.buttonTravel.keys { setButton(name, pressed: false) }
        setDpad(dx: 0, dy: 0)
        setStick(.left, x: 0, y: 0, pressedIn: false, animated: true)
        setStick(.right, x: 0, y: 0, pressedIn: false, animated: true)
        PS2Shoulder.allCases.forEach { setShoulder($0, pressed: false) }
    }
}

// MARK: - Touch surface

/// The controller region: live SceneKit DualShock 2 plus flat L1/L2/R1/R2 buttons above it.
/// All touches are handled here so sticks and buttons work simultaneously.
@MainActor
final class PS2ControllerTouchView: UIView {
    let model: PS2ControllerModel
    weak var session: EmulatorSession?
    var controlsLocked = false {
        didSet { if controlsLocked && !oldValue { cancelAllControls() } }
    }
    /// Body rectangle in this view's coordinates; the shoulder row sits above it.
    var bodyRect: CGRect = .zero {
        didSet { if bodyRect != oldValue { setNeedsLayout() } }
    }

    private let sceneView = SCNView(frame: .zero, options: nil)
    private var shoulderViews: [PS2Shoulder: PS2ShoulderButtonView] = [:]
    private lazy var pressFeedback = UIImpactFeedbackGenerator(style: .rigid, view: self)
    private lazy var releaseFeedback = UIImpactFeedbackGenerator(style: .soft, view: self)
    private lazy var ringFeedback = UIImpactFeedbackGenerator(style: .medium, view: self)
    private var idleWork: DispatchWorkItem?

    private enum Control: Equatable {
        case button(String)
        case dpad
        case stick(EmulatorSession.PS2Stick)
        case shoulder(PS2Shoulder)
    }

    private struct TouchState {
        var control: Control
        var origin: CGPoint
        var began: TimeInterval
        var moved = false
        var ringArmed = true
        var clickHeld = false
        var dpad = (dx: 0, dy: 0)
    }

    private var touches: [ObjectIdentifier: TouchState] = [:]
    private var idCounts: [Int: Int] = [:]
    private var holdTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(model: PS2ControllerModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        sceneView.scene = model.scene
        sceneView.pointOfView = model.cameraNode
        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.isUserInteractionEnabled = false
        addSubview(sceneView)
        for shoulder in PS2Shoulder.allCases {
            let view = PS2ShoulderButtonView(shoulder: shoulder)
            shoulderViews[shoulder] = view
            addSubview(view)
        }
        model.onVisualChange = { [weak self] in self?.animateModel() }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelAllControls),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        idleWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelAllControls() }
        #if DEBUG
        if window != nil, ProcessInfo.processInfo.arguments.contains("-ps2-controls-test") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.verifyControls()
            }
        }
        if window != nil, ProcessInfo.processInfo.arguments.contains("-ps2-preview-pose") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.applyDebugPose()
            }
        }
        #endif
    }

    private func animateModel() {
        idleWork?.cancel()
        sceneView.isPlaying = true
        sceneView.rendersContinuously = true
        let work = DispatchWorkItem { [weak self] in
            self?.sceneView.rendersContinuously = false
            self?.sceneView.isPlaying = false
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sceneView.frame = bounds
        guard bodyRect.width > 0 else { return }
        model.updateViewport(size: bounds.size, bodyRect: bodyRect)
        for (shoulder, view) in shoulderViews { view.frame = shoulderRect(shoulder) }
    }

    /// Flat buttons laid out above the shoulders at the real L/R x positions.
    private func shoulderRect(_ shoulder: PS2Shoulder) -> CGRect {
        let mm = model.points(millimetres:)
        let x = model.restPoint(shoulder.isLeft ? "L1" : "R1").x
        let width = mm(22)
        let l1Bottom = bodyRect.minY - mm(1.5)
        if shoulder.isTrigger {
            let height = mm(11)
            let bottom = l1Bottom - mm(9.5) - mm(2.5)
            return CGRect(x: x - width / 2, y: bottom - height, width: width, height: height)
        }
        let height = mm(9.5)
        return CGRect(x: x - width / 2, y: l1Bottom - height, width: width, height: height)
    }

    // MARK: Hit testing

    private static let faceNames = ["BTN_TRIANGLE", "BTN_CIRCLE", "BTN_CROSS", "BTN_SQUARE"]

    private func faceButton(at point: CGPoint) -> String? {
        let limit = model.points(millimetres: 8)
        let nearest = Self.faceNames.map { ($0, distance(point, model.restPoint($0))) }.min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= limit else { return nil }
        return nearest.0
    }

    private func control(at point: CGPoint) -> Control? {
        let mm = model.points(millimetres:)
        for shoulder in PS2Shoulder.allCases {
            if shoulderRect(shoulder).insetBy(dx: -mm(3), dy: -mm(1.2)).contains(point) { return .shoulder(shoulder) }
        }
        for stick in [EmulatorSession.PS2Stick.left, .right] {
            let center = model.restPoint(stick == .left ? "STICK_L" : "STICK_R")
            if distance(point, center) <= mm(15) { return .stick(stick) }
        }
        if let face = faceButton(at: point) { return .button(face) }
        if distance(point, model.restPoint("DPAD")) <= mm(17.5) { return .dpad }
        let small: [(String, CGSize)] = [("BTN_SELECT", CGSize(width: 6.5, height: 5.5)),
                                         ("BTN_START", CGSize(width: 6.5, height: 5.5)),
                                         ("BTN_ANALOG", CGSize(width: 6.5, height: 4.5))]
        for (name, half) in small {
            let c = model.restPoint(name)
            if abs(point.x - c.x) <= mm(half.width), abs(point.y - c.y) <= mm(half.height) { return .button(name) }
        }
        return nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Input plumbing

    private func pressID(_ id: Int) {
        let count = idCounts[id, default: 0]
        idCounts[id] = count + 1
        if count == 0 { session?.setPS2Button(id, pressed: true) }
    }

    private func releaseID(_ id: Int) {
        let count = idCounts[id, default: 0]
        guard count > 0 else { return }
        idCounts[id] = count - 1
        if count == 1 { session?.setPS2Button(id, pressed: false) }
    }

    private func isHeld(_ control: Control, except id: ObjectIdentifier) -> Bool {
        touches.contains { $0.key != id && $0.value.control == control }
    }

    private func pressHaptic(at point: CGPoint, intensity: CGFloat = 0.85) {
        pressFeedback.impactOccurred(intensity: intensity, at: point)
        Self.logHaptic("press", intensity, point)
    }

    private func releaseHaptic(at point: CGPoint) {
        releaseFeedback.impactOccurred(intensity: 0.5, at: point)
        Self.logHaptic("release", 0.5, point)
    }

    /// DEBUG trace so haptics can be verified on the simulator, which has no Taptic Engine.
    static func logHaptic(_ kind: String, _ intensity: CGFloat, _ point: CGPoint) {
        #if DEBUG
        NSLog("DUO_PS2_HAPTIC %@ intensity=%.2f at=(%.0f,%.0f)", kind, intensity, point.x, point.y)
        #endif
    }

    private func beginButton(_ name: String, at point: CGPoint) {
        model.setButton(name, pressed: true)
        if name == "BTN_ANALOG" {
            model.setAnalogMode(!model.analogMode)
        } else if let id = PS2ControllerMetrics.buttonIDs[name] {
            pressID(id)
        }
        pressHaptic(at: point)
    }

    private func endButton(_ name: String, at point: CGPoint) {
        model.setButton(name, pressed: false)
        if let id = PS2ControllerMetrics.buttonIDs[name] { releaseID(id) }
        releaseHaptic(at: point)
    }

    private static func dpadIDs(_ d: (dx: Int, dy: Int)) -> Set<Int> {
        var ids = Set<Int>()
        if d.dy < 0 { ids.insert(PS2ControllerMetrics.dpadIDs.up) }
        if d.dy > 0 { ids.insert(PS2ControllerMetrics.dpadIDs.down) }
        if d.dx < 0 { ids.insert(PS2ControllerMetrics.dpadIDs.left) }
        if d.dx > 0 { ids.insert(PS2ControllerMetrics.dpadIDs.right) }
        return ids
    }

    private func dpadDirection(at point: CGPoint) -> (dx: Int, dy: Int) {
        let center = model.restPoint("DPAD")
        let v = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let length = hypot(v.x, v.y)
        guard length > model.points(millimetres: 2.5) else { return (0, 0) }
        let threshold: CGFloat = 0.47 // sin 28°: cardinal sectors 56°, diagonals 34°
        let dx = v.x > threshold * length ? 1 : (v.x < -threshold * length ? -1 : 0)
        let dy = v.y > threshold * length ? 1 : (v.y < -threshold * length ? -1 : 0)
        return (dx, dy)
    }

    private func updateDpad(_ state: inout TouchState, to next: (dx: Int, dy: Int), at point: CGPoint) {
        let before = Self.dpadIDs(state.dpad)
        let after = Self.dpadIDs(next)
        guard before != after else { return }
        state.dpad = next
        after.subtracting(before).forEach(pressID)
        before.subtracting(after).forEach(releaseID)
        model.setDpad(dx: next.dx, dy: next.dy)
        if !after.subtracting(before).isEmpty { pressHaptic(at: point, intensity: 0.75) }
        if !before.subtracting(after).isEmpty { releaseHaptic(at: point) }
    }

    private var stickRing: CGFloat { max(30, model.points(millimetres: 13)) }

    private func stickAxis(_ displacement: CGPoint) -> CGPoint {
        let d = hypot(displacement.x, displacement.y)
        let deadzone: CGFloat = 3
        guard d > deadzone else { return .zero }
        let magnitude = min(1, (d - deadzone) / (stickRing - deadzone))
        return CGPoint(x: displacement.x / d * magnitude, y: displacement.y / d * magnitude)
    }

    private func setStickClick(_ stick: EmulatorSession.PS2Stick, _ pressed: Bool, at point: CGPoint) {
        let id = stick == .left ? PS2ControllerMetrics.l3 : PS2ControllerMetrics.r3
        if pressed { pressID(id); pressHaptic(at: point, intensity: 0.7) } else { releaseID(id); releaseHaptic(at: point) }
    }

    // MARK: Touches

    /// Only the body and the shoulder buttons take touches: the empty strip between the shoulder
    /// buttons lets them through to the distant console behind.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return point.y >= bodyRect.minY || control(at: point) != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !controlsLocked else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            guard let control = control(at: point) else { continue }
            if case .stick = control, isHeld(control, except: id) { continue }
            if control == .dpad, isHeld(control, except: id) { continue }
            var state = TouchState(control: control, origin: point, began: touch.timestamp)
            let shared = isHeld(control, except: id)
            switch control {
            case .button(let name):
                if !shared { beginButton(name, at: point) }
            case .shoulder(let shoulder):
                if !shared {
                    pressID(shoulder.joypadID)
                    shoulderViews[shoulder]?.isPressed = true
                    model.setShoulder(shoulder, pressed: true)
                    pressHaptic(at: point)
                }
            case .dpad:
                updateDpad(&state, to: dpadDirection(at: point), at: point)
            case .stick(let stick):
                model.setStick(stick, x: 0, y: 0, pressedIn: false, animated: false)
                // Holding still for a moment clicks the stick in (L3/R3) until release.
                holdTasks[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard let self, !Task.isCancelled, var current = self.touches[id], !current.moved else { return }
                    current.clickHeld = true
                    self.touches[id] = current
                    self.setStickClick(stick, true, at: point)
                    self.model.setStick(stick, x: 0, y: 0, pressedIn: true, animated: true)
                }
            }
            self.touches[id] = state
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard var state = self.touches[id] else { continue }
            let point = touch.location(in: self)
            switch state.control {
            case .dpad:
                updateDpad(&state, to: dpadDirection(at: point), at: point)
            case .button(let name) where Self.faceNames.contains(name):
                // Rolling the thumb across the face cluster moves the press.
                if let next = faceButton(at: point), next != name, !isHeld(.button(next), except: id) {
                    if !isHeld(state.control, except: id) { endButton(name, at: point) }
                    state.control = .button(next)
                    beginButton(next, at: point)
                }
            case .stick(let stick):
                var latest: CGPoint?
                for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                    let p = sample.location(in: self)
                    let displacement = CGPoint(x: p.x - state.origin.x, y: p.y - state.origin.y)
                    let d = hypot(displacement.x, displacement.y)
                    if d > 8 && !state.moved {
                        state.moved = true
                        holdTasks.removeValue(forKey: id)?.cancel()
                    }
                    // Edge-triggered: one tap on crossing the outer ring, re-armed just inside it.
                    if d > stickRing, state.ringArmed {
                        state.ringArmed = false
                        ringFeedback.impactOccurred(intensity: 0.6, at: model.restPoint(stick == .left ? "STICK_L" : "STICK_R"))
                        Self.logHaptic(stick == .left ? "ring-left" : "ring-right", 0.6, p)
                    } else if d < stickRing * 0.85 {
                        state.ringArmed = true
                    }
                    latest = stickAxis(displacement)
                }
                if let axis = latest {
                    session?.setPS2Analog(stick: stick, x: axis.x, y: axis.y)
                    model.setStick(stick, x: axis.x, y: axis.y, pressedIn: state.clickHeld, animated: false)
                }
            default:
                break
            }
            self.touches[id] = state
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            holdTasks.removeValue(forKey: id)?.cancel()
            guard var state = self.touches.removeValue(forKey: id) else { continue }
            let point = touch.location(in: self)
            let shared = self.touches.values.contains { $0.control == state.control }
            switch state.control {
            case .button(let name):
                if !shared { endButton(name, at: point) }
            case .shoulder(let shoulder):
                if !shared {
                    releaseID(shoulder.joypadID)
                    shoulderViews[shoulder]?.isPressed = false
                    model.setShoulder(shoulder, pressed: false)
                    releaseHaptic(at: point)
                }
            case .dpad:
                updateDpad(&state, to: (0, 0), at: point)
            case .stick(let stick):
                session?.setPS2Analog(stick: stick, x: 0, y: 0)
                model.setStick(stick, x: 0, y: 0, pressedIn: false, animated: true)
                if state.clickHeld {
                    setStickClick(stick, false, at: point)
                } else if !cancelled, !state.moved, touch.timestamp - state.began < 0.32 {
                    tapStick(stick, at: point)
                }
            }
        }
    }

    /// A quick tap on a stick is an L3/R3 click.
    private func tapStick(_ stick: EmulatorSession.PS2Stick, at point: CGPoint) {
        setStickClick(stick, true, at: point)
        model.setStick(stick, x: 0, y: 0, pressedIn: true, animated: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            self.setStickClick(stick, false, at: point)
            self.model.setStick(stick, x: 0, y: 0, pressedIn: false, animated: true)
        }
    }

    @objc func cancelAllControls() {
        holdTasks.values.forEach { $0.cancel() }
        holdTasks.removeAll()
        touches.removeAll()
        for (id, count) in idCounts where count > 0 { session?.setPS2Button(id, pressed: false) }
        idCounts.removeAll()
        session?.setPS2Analog(stick: .left, x: 0, y: 0)
        session?.setPS2Analog(stick: .right, x: 0, y: 0)
        shoulderViews.values.forEach { $0.isPressed = false }
        model.releaseAllVisuals()
    }

    #if DEBUG
    /// Routes each control's on-model centre through the production hit test.
    private func verifyControls() {
        var expected: [(String, CGPoint, Control)] = [
            ("DPAD", model.restPoint("DPAD"), .dpad),
            ("STICK_L", model.restPoint("STICK_L"), .stick(.left)),
            ("STICK_R", model.restPoint("STICK_R"), .stick(.right))
        ]
        for name in Self.faceNames + ["BTN_SELECT", "BTN_START", "BTN_ANALOG"] {
            expected.append((name, model.restPoint(name), .button(name)))
        }
        for shoulder in PS2Shoulder.allCases {
            let r = shoulderRect(shoulder)
            expected.append((shoulder.label, CGPoint(x: r.midX, y: r.midY), .shoulder(shoulder)))
        }
        var failures: [String] = []
        for (name, point, control) in expected where self.control(at: point) != control {
            failures.append(name)
        }
        let dirs = [(CGPoint(x: 0, y: -1), (0, -1)), (CGPoint(x: 1, y: 0), (1, 0)),
                    (CGPoint(x: 0.7, y: 0.7), (1, 1)), (CGPoint(x: -1, y: 0.1), (-1, 0))]
        for (v, want) in dirs {
            let c = model.restPoint("DPAD"), r = model.points(millimetres: 9)
            let got = dpadDirection(at: CGPoint(x: c.x + v.x * r, y: c.y + v.y * r))
            if got.dx != want.0 || got.dy != want.1 { failures.append("DPAD\(want)") }
        }
        print(failures.isEmpty ? "DUO_PS2_CONTROLS_PASS: \(expected.count) controls + 4 dpad sectors"
                               : "DUO_PS2_CONTROLS_FAIL: \(failures)")
    }

    private func applyDebugPose() {
        model.setButton("BTN_CROSS", pressed: true)
        model.setDpad(dx: 1, dy: -1)
        model.setStick(.left, x: 0.8, y: -0.5, pressedIn: false, animated: true)
        model.setStick(.right, x: -0.6, y: 0.7, pressedIn: true, animated: true)
        shoulderViews[.l1]?.isPressed = true
        shoulderViews[.r2]?.isPressed = true
        model.setShoulder(.l1, pressed: true)
        model.setShoulder(.r2, pressed: true)
    }
    #endif
}

// MARK: - Flat shoulder buttons

/// L1/L2/R1/R2 drawn flat, styled like the real matte-black keys with embossed grey letters.
final class PS2ShoulderButtonView: UIView {
    let shoulder: PS2Shoulder
    var isPressed = false {
        didSet { if isPressed != oldValue { updateAppearance(animated: true) } }
    }
    private let body = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let label = CATextLayer()

    init(shoulder: PS2Shoulder) {
        self.shoulder = shoulder
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = shoulder.label
        accessibilityTraits = .button
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.7
        body.mask = bodyMask
        layer.addSublayer(body)
        highlight.fillColor = UIColor.clear.cgColor
        highlight.lineCap = .round
        layer.addSublayer(highlight)
        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.black.withAlphaComponent(0.9).cgColor
        rim.lineWidth = 1
        layer.addSublayer(rim)
        label.string = shoulder.label
        label.alignmentMode = .center
        layer.addSublayer(label)
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func outline(in rect: CGRect) -> UIBezierPath {
        // Triggers have a rounder, taller front edge; L1/R1 are low slim bars.
        let outer: UIRectCorner = shoulder.isLeft ? .topLeft : .topRight
        if shoulder.isTrigger {
            let path = UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight, outer],
                                    cornerRadii: CGSize(width: rect.height * 0.5, height: rect.height * 0.5))
            return path
        }
        return UIBezierPath(roundedRect: rect, byRoundingCorners: .allCorners,
                            cornerRadii: CGSize(width: rect.height * 0.32, height: rect.height * 0.32))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = bounds
        body.frame = rect
        let path = outline(in: rect)
        bodyMask.path = path.cgPath
        rim.path = path.cgPath
        layer.shadowPath = path.cgPath
        let top = UIBezierPath()
        let inset = rect.height * 0.35
        top.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + 1.5))
        top.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + 1.5))
        highlight.path = top.cgPath
        highlight.lineWidth = 1
        let fontSize = max(8, rect.height * 0.46)
        label.contentsScale = traitCollection.displayScale
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        label.fontSize = fontSize
        label.frame = CGRect(x: 0, y: (rect.height - fontSize * 1.2) / 2, width: rect.width, height: fontSize * 1.2)
        CATransaction.commit()
    }

    private func updateAppearance(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? (isPressed ? 0.05 : 0.1) : 0)
        CATransaction.setDisableActions(!animated)
        // Pressed: the gradient flips (concave, lit from below), letters and highlight dim.
        body.colors = isPressed
            ? [UIColor(white: 0.05, alpha: 1).cgColor, UIColor(white: 0.13, alpha: 1).cgColor]
            : [UIColor(white: 0.28, alpha: 1).cgColor, UIColor(white: 0.12, alpha: 1).cgColor]
        highlight.strokeColor = UIColor.white.withAlphaComponent(isPressed ? 0 : 0.2).cgColor
        label.foregroundColor = UIColor(white: isPressed ? 0.33 : 0.62, alpha: 1).cgColor
        layer.shadowOffset = CGSize(width: 0, height: isPressed ? 0 : 2.5)
        layer.shadowRadius = isPressed ? 0.5 : 2.5
        let offset = CGAffineTransform(translationX: 0, y: isPressed ? 1.5 : 0).scaledBy(x: isPressed ? 0.96 : 1,
                                                                                           y: isPressed ? 0.92 : 1)
        layer.setAffineTransform(offset)
        CATransaction.commit()
    }
}

// MARK: - SwiftUI bridge

struct PS2ControllerView: UIViewRepresentable {
    let model: PS2ControllerModel
    let session: EmulatorSession?
    /// Body rectangle in this view's coordinates.
    let bodyRect: CGRect
    var controlsLocked = false

    func makeUIView(context: Context) -> PS2ControllerTouchView {
        let view = PS2ControllerTouchView(model: model)
        view.session = session
        view.bodyRect = bodyRect
        view.controlsLocked = controlsLocked
        view.accessibilityLabel = String(localized: "DualShock 2 手柄")
        return view
    }

    func updateUIView(_ view: PS2ControllerTouchView, context: Context) {
        view.session = session
        view.bodyRect = bodyRect
        view.controlsLocked = controlsLocked
    }

    static func dismantleUIView(_ view: PS2ControllerTouchView, coordinator: ()) {
        view.cancelAllControls()
    }
}
