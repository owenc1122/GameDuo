// Load every contract asset in SceneKit the way the app does and check it.
//
//   xcrun swift tools/ps2_blender/verify_scenekit.swift [contract.json] [AssetName ...]
//
// SceneKit keeps USD prim names verbatim and ignores upAxis: the tree is
// <unnamed> > ROOT with the transforms exactly as modelled (Y up, see common.py).
// A mesh object with children is node NAME with a geometry child NAME_mesh.
// Nodes are matched on "NAME" or "NAME.*", outermost (breadth-first) first, else
// "NAME_mesh". Checks: root and required nodes exist, geometry has drawable
// elements, the vertex bounds in root space match size_mm, and every motion's
// extreme values can be written to and read back from the node.
import Foundation
import SceneKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())
let contractArg = args.first ?? "tools/ps2_blender/contract.json"
let onlyAssets = Set(args.dropFirst())

func resolve(_ path: String) -> URL {
    if path.hasPrefix("/") || FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return repo.appendingPathComponent(path)
}

func findNode(_ name: String, in root: SCNNode) -> SCNNode? {
    for wanted in [name, name + "_mesh"] {
        var queue = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if let n = node.name, n == wanted || n.hasPrefix(wanted + ".") { return node }
            queue += node.childNodes
        }
    }
    return nil
}

func descendants(_ node: SCNNode) -> [SCNNode] {
    [node] + node.childNodes.flatMap(descendants)
}

/// Min/max of the vertex positions under `root`, in root space, skipping `excluded` subtrees.
func worldBounds(_ root: SCNNode, excluding excluded: Set<ObjectIdentifier>) -> (SIMD3<Float>, SIMD3<Float>)? {
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    let toRoot = root.simdWorldTransform.inverse
    func visit(_ node: SCNNode) {
        if excluded.contains(ObjectIdentifier(node)) { return }
        if let source = node.geometry?.sources(for: .vertex).first,
           source.usesFloatComponents, source.bytesPerComponent == 4 {
            let world = toRoot * node.simdWorldTransform
            source.data.withUnsafeBytes { raw in
                for i in 0..<source.vectorCount {
                    let at = source.dataOffset + i * source.dataStride
                    let p = SIMD3<Float>(raw.load(fromByteOffset: at, as: Float.self),
                                         raw.load(fromByteOffset: at + 4, as: Float.self),
                                         raw.load(fromByteOffset: at + 8, as: Float.self))
                    let w = world * SIMD4<Float>(p, 1)
                    lo = simd_min(lo, SIMD3(w.x, w.y, w.z))
                    hi = simd_max(hi, SIMD3(w.x, w.y, w.z))
                }
            }
        }
        node.childNodes.forEach(visit)
    }
    visit(root)
    return lo.x <= hi.x ? (lo, hi) : nil
}

func checkMotion(_ motion: [String: Any], on node: SCNNode) -> String? {
    guard let axis = motion["axis"] as? String,
          let range = (motion["range_m"] ?? motion["range_rad"]) as? [Double] else {
        return "malformed motion \(motion)"
    }
    let parts = axis.split(separator: "_").map(String.init)
    guard parts.count == 2, let index = ["x", "y", "z"].firstIndex(of: parts[1]) else {
        return "bad axis \(axis)"
    }
    let isLoc = parts[0] == "loc"
    let base = isLoc ? node.simdPosition : node.simdEulerAngles
    defer { if isLoc { node.simdPosition = base } else { node.simdEulerAngles = base } }
    for value in range {
        var target = base
        target[index] += Float(value)
        if isLoc { node.simdPosition = target } else { node.simdEulerAngles = target }
        let read = isLoc ? node.simdPosition : node.simdEulerAngles
        if abs(read[index] - target[index]) > 1e-5 {
            return "\(axis)=\(value) read back \(read[index])"
        }
    }
    return nil
}

func verify(_ name: String, _ spec: [String: Any], tolerance: Double) -> [String] {
    guard let file = spec["file"] as? String, let rootName = spec["root"] as? String else {
        return ["contract entry needs file and root"]
    }
    let url = resolve(file)
    guard FileManager.default.fileExists(atPath: url.path) else { return ["file not found: \(file)"] }
    let scene: SCNScene
    do { scene = try SCNScene(url: url, options: nil) } catch { return ["load failed: \(error)"] }
    guard let root = findNode(rootName, in: scene.rootNode) else { return ["missing root \(rootName)"] }

    var reasons: [String] = []
    let missing = (spec["nodes"] as? [String] ?? []).filter { findNode($0, in: root) == nil }
    if !missing.isEmpty { reasons.append("missing nodes: " + missing.joined(separator: ", ")) }

    let meshes = descendants(root).filter { $0.geometry != nil }
    let empty = meshes.filter { $0.geometry!.elements.allSatisfy { $0.primitiveCount == 0 } }
    if meshes.isEmpty { reasons.append("no geometry under \(rootName)") }
    if !empty.isEmpty {
        reasons.append("no drawable elements: " + empty.map { $0.name ?? "?" }.joined(separator: ", "))
    }

    let excluded = Set((spec["size_excludes"] as? [String] ?? [])
        .compactMap { findNode($0, in: root) }.map(ObjectIdentifier.init))
    if let (lo, hi) = worldBounds(root, excluding: excluded) {
        let size = (hi - lo) * 1000
        let sizeText = String(format: "[%.3f, %.3f, %.3f]", size.x, size.y, size.z)
        print("  \(name) root-space bounds min \(lo) max \(hi) size_mm \(sizeText)")
        if let target = spec["size_mm"] as? [Double], target.count == 3,
           (0..<3).contains(where: { abs(Double(size[$0]) - target[$0]) > tolerance }) {
            reasons.append("size_mm \(sizeText) vs target \(target)")
        }
    }

    for motion in spec["motions"] as? [[String: Any]] ?? [] {
        let nodeName = motion["node"] as? String ?? "?"
        guard let node = findNode(nodeName, in: root) else {
            reasons.append("motion node not found: \(nodeName)")
            continue
        }
        if let problem = checkMotion(motion, on: node) { reasons.append("motion \(nodeName): \(problem)") }
    }
    return reasons
}

let contractURL = resolve(contractArg)
guard let data = try? Data(contentsOf: contractURL),
      let contract = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let assets = contract["assets"] as? [String: [String: Any]] else {
    print("ERROR cannot read contract: \(contractURL.path)")
    exit(2)
}
let tolerance = contract["tolerance_mm"] as? Double ?? 0.5
let unknown = onlyAssets.subtracting(assets.keys)
if !unknown.isEmpty {
    print("ERROR unknown asset(s): \(unknown.sorted().joined(separator: ", "))")
    exit(2)
}
var failed = 0
for name in assets.keys.sorted() where onlyAssets.isEmpty || onlyAssets.contains(name) {
    let reasons = verify(name, assets[name]!, tolerance: tolerance)
    if reasons.isEmpty {
        print("OK \(name)")
    } else {
        failed += 1
        print("FAIL \(name): " + reasons.joined(separator: "; "))
    }
}
exit(failed == 0 ? 0 : 1)
