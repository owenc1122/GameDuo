import Foundation
import SceneKit

// MARK: - Scene neutralisation

/// Every user sees the same brand-free media, cases and consoles: no Sony / Nintendo names, logos
/// or model numbers (Handheld_Cases/NEUTRAL_BRANDING_AUDIT.md). These rules strip the prints that
/// are still baked into the USDZ assets until the assets themselves are cleaned.
enum NeutralBranding {
    /// Library media and retail cases, which are built per game: nodes whose names start with one
    /// of these are hidden.
    static let mediumAndCasePrefixes = [
        // Detailed-Cartridges.usdz (every card kind): front "NINTENDO DS" / "NINTENDO 3DS" moulding,
        // back "Nintendo" maker mark, back "NTR-005" / "CTR-005" model number.
        "Front_platform", "Back_maker_mark", "Molded_model_number",
        // PSP-UMD.usdz: "PSP" logo and gamepad mark on the shell, "UMD" lettering on the centre badge.
        "PSP_shell_vector", "Gamepad___photo_traced_shell_mark", "UMD_shell_vector",
        // NDS-Case / 3DS-Case / PSP-UMD-Case.usdz moulded "NINTENDO DS", "Nintendo", "Nintendo 3DS", "UMD".
        "TRADEMARK_PRINTS",
    ]

    static func hideTrademarkNodes(in root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let name = node.name, mediumAndCasePrefixes.contains(where: name.hasPrefix) else { return }
            node.isHidden = true
        }
    }

    // Consoles: one scene serves every game, so the rules are applied once per scene.

    /// 3DSXL-Cartridge-Open-Transition.usdz underside legends: "Nintendo", "NINTENDO 3DS XL",
    /// "SPR-001", battery "SPR-003", ratings.
    private static let consoleHiddenNodes: Set<String> = [
        "Underside_·_Manufacturer", "Underside_·_Model_name", "Underside_·_Model_number",
        "Underside_·_Battery_type", "Underside_·_Power_rating",
    ]

    private struct MaterialSwap {
        /// Materials whose names start with one of these are replaced …
        let from: [String]
        /// … by the material of the same geometry whose name starts with this (skipped when absent),
        /// or, when nil, by an invisible material.
        let to: String?
        /// Only below nodes with these names (nil: anywhere).
        let under: Set<String>?
    }

    private static let consoleSwaps = [
        // PSP2000-UMD-Open-Transition.usdz housing and UMD door: "SONY" (front and back), the
        // PlayStation logo, the "PSP" logo (front and door), "UMD", and the printed small legends
        // (VOL, POWER, HOLD, WLAN / memory icons) that share the same print material.
        MaterialSwap(from: ["Logo___", "Print___"], to: "Shell___Ice_Silver", under: nil),
        // PSP face buttons: the triangle / circle / cross / square glyphs (separate flat shapes inside
        // the clear caps; left out, the caps read as plain buttons).
        MaterialSwap(from: ["Controls___charcoal_original_glyphs"], to: nil,
                     under: ["BUTTON_CROSS", "BUTTON_CIRCLE", "BUTTON_SQUARE", "BUTTON_TRIANGLE"]),
    ]

    private static let invisible: SCNMaterial = {
        let material = SCNMaterial()
        material.name = "DUO_NEUTRAL_INVISIBLE"
        material.transparency = 0
        material.writesToDepthBuffer = false
        material.colorBufferWriteMask = []
        return material
    }()

    private static let stateKey = "duoNeutralBrandingApplied"

    /// Hides the underside legends and repaints the brand prints with the surrounding material.
    /// Cheap when `root` was already neutralised.
    static func applyConsole(to root: SCNNode) {
        if (root.value(forKey: stateKey) as? Bool) == true { return }
        root.setValue(true, forKey: stateKey)
        root.enumerateHierarchy { node, _ in
            if let name = node.name, consoleHiddenNodes.contains(name) { node.isHidden = true }
            guard let geometry = node.geometry,
                  let neutral = neutralMaterials(for: node, geometry: geometry) else { return }
            let copy = geometry.copy() as! SCNGeometry
            copy.materials = neutral
            node.geometry = copy
        }
    }

    /// Forget the cached state of `root` (its children were replaced), so the next
    /// `applyConsole` walks the hierarchy again.
    static func invalidate(_ root: SCNNode) {
        root.setValue(nil, forKey: stateKey)
    }

    private static func neutralMaterials(for node: SCNNode, geometry: SCNGeometry) -> [SCNMaterial]? {
        var materials = geometry.materials
        var changed = false
        for swap in consoleSwaps {
            if let under = swap.under, !hasAncestor(node, named: under) { continue }
            let replacement: SCNMaterial
            if let to = swap.to {
                guard let sibling = materials.first(where: { $0.name?.hasPrefix(to) == true }) else { continue }
                replacement = sibling
            } else {
                replacement = invisible
            }
            for index in materials.indices {
                guard let name = materials[index].name, swap.from.contains(where: name.hasPrefix) else { continue }
                materials[index] = replacement
                changed = true
            }
        }
        return changed ? materials : nil
    }

    private static func hasAncestor(_ node: SCNNode, named names: Set<String>) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, names.contains(name) { return true }
            current = candidate.parent
        }
        return false
    }
}
