import SceneKit
import UIKit

/// The PS2 case the carousel has opened: hinge angles, and the disc and memory card that live
/// inside it. The case itself is the selected Cover Flow card (`cartridgeModel` → `PS2_CASE`);
/// the disc and card are separate root-level nodes so they can fly to the console, and while
/// resting they are posed from the case every layout pass (`discRestTransform`, `memoryCardRestTransform`).
@MainActor
final class PS2CaseStage {
    enum Target { case lid, tray, disc, memoryCard }

    let caseNode: SCNNode
    let disc: SCNNode
    let memoryCard: SCNNode
    private let spine: SCNNode?
    private let lid: SCNNode?
    private let discAnchor: SCNNode?

    /// Memory card root in `PS2_CASE` space, lying flat in the holder (contract
    /// `memory_card_holder`: centre (−5, 159.5) mm, 56.5 mm along X, floor −5.7 mm, card raised
    /// 0.2 mm over the embosses). The connector points at the spine (the embossed arrow),
    /// the label faces the lid.
    static let holderTransform: simd_float4x4 = {
        let halfThickness: Float = 0.00375
        let centre = SIMD3<Float>(-0.005, 0.1595, -0.0057 + 0.0002 + halfThickness)
        // Card axes → case axes: +X → +Y, +Y (label) → +Z, +Z (away from the connector) → +X.
        var m = simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1)))
        let connector = centre - SIMD3<Float>(0.02825, 0, 0)
        m.columns.3 = SIMD4(connector, 1)
        return m
    }()

    init?(card: SCNNode, game: GameLibraryItem, parent: SCNNode) {
        guard let caseNode = card.childNode(withName: "PS2_CASE", recursively: true),
              let dvd = Self.makeDisc(for: game),
              let memoryCard = PS2StageAssets.memoryCard?.clone() else { return nil }
        self.caseNode = caseNode
        spine = caseNode.childNode(withName: "CASE_SPINE", recursively: true)
        lid = caseNode.childNode(withName: "CASE_LID", recursively: true)
        discAnchor = caseNode.childNode(withName: "CASE_DISC_ANCHOR", recursively: true)
        disc = dvd
        self.memoryCard = memoryCard
        memoryCard.name = "DUO_PS2_MEMORY_CARD"
        parent.addChildNode(disc)
        parent.addChildNode(memoryCard)
    }

    /// `spine`, `lid`: 0 (closed) … 1 (π/2 each; tray | spine | lid lie flat).
    func setHinges(spine spineProgress: Float, lid lidProgress: Float) {
        spine?.eulerAngles.y = .pi / 2 * spineProgress
        lid?.eulerAngles.y = .pi / 2 * lidProgress
    }

    /// Centre of the case's bounding box along X, relative to the closed case, in metres:
    /// 0 closed, −7 mm with only the spine open, −74.5 mm fully open.
    static func openCentreShift(spine: Float, lid: Float) -> Float {
        -0.007 * spine - 0.0675 * lid
    }

    var discRestTransform: simd_float4x4 {
        discAnchor?.simdWorldTransform ?? caseNode.simdWorldTransform
    }

    var memoryCardRestTransform: simd_float4x4 {
        caseNode.simdWorldTransform * Self.holderTransform
    }

    /// The front-most case part under `point`.
    func target(at point: CGPoint, in view: SCNView) -> Target? {
        let results = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for result in results {
            var node: SCNNode? = result.node
            while let current = node {
                if current === disc { return .disc }
                if current === memoryCard { return .memoryCard }
                if current === lid { return .lid }
                if current === caseNode { return .tray }
                node = current.parent
            }
        }
        return nil
    }

    /// The pull target a drag starting at `point` means: a direct hit on the disc or card, else
    /// whichever of the two is clearly nearest (the models are small touch targets).
    func pullTarget(at point: CGPoint, in view: SCNView) -> PS2PullTarget? {
        switch target(at: point, in: view) {
        case .disc: return .disc
        case .memoryCard: return .memoryCard
        default: break
        }
        func normalisedDistance(_ transform: simd_float4x4, radius: Float) -> CGFloat {
            let centre = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let scale = simd_length(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
            let a = view.projectPoint(SCNVector3(centre))
            let b = view.projectPoint(SCNVector3(centre + SIMD3<Float>(radius * scale, 0, 0)))
            let r = max(1, hypot(CGFloat(b.x - a.x), CGFloat(b.y - a.y)))
            return hypot(point.x - CGFloat(a.x), point.y - CGFloat(a.y)) / r
        }
        let discDistance = normalisedDistance(disc.simdWorldTransform, radius: 0.06)
        // The card root is its connector end; measure from the card's centre instead.
        let cardCentre = memoryCard.simdWorldTransform * simd_float4x4(translation: SIMD3(0, 0, 0.02825))
        let cardDistance = normalisedDistance(cardCentre, radius: 0.028)
        let best = min(discDistance, cardDistance)
        guard best < 1.35 else { return nil }
        return discDistance <= cardDistance ? .disc : .memoryCard
    }

    func remove() {
        setHinges(spine: 0, lid: 0)
        disc.removeFromParentNode()
        memoryCard.removeFromParentNode()
    }

    // MARK: Materials

    /// A `PS2_DVD` clone printed with the game's label (the case's disc and the game screen's exit disc).
    static func makeDisc(for game: GameLibraryItem) -> SCNNode? {
        guard let disc = PS2StageAssets.dvd?.clone() else { return nil }
        disc.name = "DUO_PS2_DISC"
        applyDiscLabel(discLabelTexture(for: game), to: disc)
        applyDiscPrintRule(to: disc, hasCover: game.icon?.cgImage != nil)
        return disc
    }

    /// Like `applyBannerRule`: a label printed from the real cover already has its own artwork,
    /// so the model's default label prints (PS logo box, "PlayStation 2" wordmark) are hidden;
    /// the blank title label keeps them. The hub holograms on the data side always stay.
    nonisolated static func applyDiscPrintRule(to disc: SCNNode, hasCover: Bool) {
        for name in ["LABEL_PS_LOGO_BOX", "LABEL_WORDMARK"] {
            disc.childNode(withName: name, recursively: true)?.isHidden = hasCover
        }
    }

    /// Real covers (downloaded or local scans) already print the top "PlayStation 2" banner, so the
    /// model's lid banner is hidden then; a blank insert keeps it. Spine prints always stay.
    nonisolated static func applyBannerRule(to caseNode: SCNNode, hasCover: Bool) {
        caseNode.childNode(withName: "TRADEMARK_PRINTS_LID", recursively: true)?.isHidden = hasCover
    }

    private static func applyDiscLabel(_ texture: UIImage, to disc: SCNNode) {
        guard let label = disc.childNode(withName: "DISC_LABEL", recursively: true) else { return }
        let targets = [label] + label.childNodes.filter { $0.name == "DISC_LABEL_mesh" }
        for target in targets {
            guard let geometry = target.geometry?.copy() as? SCNGeometry else { continue }
            geometry.materials = geometry.materials.map { original in
                let material = original.copy() as! SCNMaterial
                material.diffuse.contents = texture
                return material
            }
            target.geometry = geometry
        }
    }

    private static let labelCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    /// Square label image spanning the 120 mm disc (only the 24–117 mm ring shows): the cover,
    /// centre-cropped to a square; without a cover, a white label with the title.
    static func discLabelTexture(for game: GameLibraryItem) -> UIImage {
        let key = "\(game.id)|\(game.appearanceRevision)" as NSString
        if let cached = labelCache.object(forKey: key) { return cached }
        let side = 1024
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return UIImage() }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        UIColor(white: 0.95, alpha: 1).setFill()
        ctx.fill(bounds)
        if let cover = game.icon?.cgImage {
            let edge = min(cover.width, cover.height)
            let crop = CGRect(x: (cover.width - edge) / 2, y: (cover.height - edge) / 2, width: edge, height: edge)
            if let square = cover.cropping(to: crop) { UIImage(cgImage: square).draw(in: bounds) }
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (game.title as NSString).draw(
                in: CGRect(x: 220, y: 190, width: 584, height: 220),
                withAttributes: [.font: UIFont.systemFont(ofSize: 58, weight: .bold),
                                 .foregroundColor: UIColor(white: 0.18, alpha: 1),
                                 .paragraphStyle: paragraph])
        }
        UIGraphicsPopContext()
        guard let rendered = ctx.makeImage() else { return UIImage() }
        let texture = UIImage(cgImage: rendered)
        labelCache.setObject(texture, forKey: key)
        return texture
    }
}

/// Runtime PS2 models, loaded once (off the main thread via `preload()` when a PS2 game is listed)
/// and cloned per use.
enum PS2StageAssets {
    static let dvd: SCNNode? = load("PS2-DVD", root: "PS2_DVD")
    static let memoryCard: SCNNode? = load("PS2-MemoryCard", root: "PS2_MEMORY_CARD")
    static let console: SCNNode? = load("PS2-Console", root: "PS2_CONSOLE")

    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = (dvd, memoryCard, console) }
    }

    private static func load(_ resource: String, root: String) -> SCNNode? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "usdz"),
              let scene = try? SCNScene(url: url),
              let node = scene.rootNode.childNode(withName: root, recursively: true) else { return nil }
        node.enumerateHierarchy { child, _ in child.removeAllAnimations() }
        return node
    }
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}

/// Interpolation between two world poses with uniform scale (every PS2 node is uniformly scaled).
enum PS2Pose {
    static func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        let (ta, ra, sa) = decompose(a)
        let (tb, rb, sb) = decompose(b)
        return compose(simd_mix(ta, tb, SIMD3(repeating: t)), simd_slerp(ra, rb, t), sa + (sb - sa) * t)
    }

    static func decompose(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf, Float) {
        let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let s = max(simd_length(c0), 1e-6)
        let rotation = simd_quatf(simd_float3x3(c0 / s, c1 / s, c2 / s))
        return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), rotation, s)
    }

    static func compose(_ t: SIMD3<Float>, _ r: simd_quatf, _ s: Float) -> simd_float4x4 {
        var m = simd_float4x4(r)
        m.columns.0 *= s
        m.columns.1 *= s
        m.columns.2 *= s
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}
