// Load every contract asset in SceneKit the way the app does and check it.
//
//   xcrun swift tools/ps2_blender/verify_scenekit.swift [--contract path/contract.json] [--only Asset ...]
//
// Asset entries are contract.json deep-merged with contract_parts/<name>.json next to it
// (parts win), like common.load_contract. SceneKit keeps USD prim names verbatim and
// ignores upAxis: the tree is <unnamed> > ROOT with transforms exactly as modelled
// (Y up, see common.py). A mesh object with children is node NAME with a geometry child
// NAME_mesh. Lookups use childNode(withName:recursively:) like the app, else NAME_mesh.
// Checks: root and required nodes exist exactly once, geometry has drawable elements,
// vertex bounds in root space match size_mm, and posing each motion's range ends moves
// the node's geometry as expected (loc_*: bounds centre shifts by the value along the
// parent axis; rot_*: vertices rotate about the pivot; rot_* pivots must rest at zero).
import Foundation
import SceneKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let moveTolerance: Float = 0.0001  // metres

var contractArg = "tools/ps2_blender/contract.json"
var onlyAssets = Set<String>()
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let flag = argv.removeFirst()
    guard (flag == "--contract" || flag == "--only"), !argv.isEmpty else {
        print("usage: verify_scenekit.swift [--contract contract.json] [--only Asset ...]")
        exit(2)
    }
    if flag == "--contract" { contractArg = argv.removeFirst() } else { onlyAssets.insert(argv.removeFirst()) }
}

func resolve(_ path: String) -> URL {
    if path.hasPrefix("/") || FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return repo.appendingPathComponent(path)
}

func deepMerge(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] {
    var out = base
    for (key, value) in extra {
        if let a = out[key] as? [String: Any], let b = value as? [String: Any] {
            out[key] = deepMerge(a, b)
        } else {
            out[key] = value
        }
    }
    return out
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func descendants(_ node: SCNNode) -> [SCNNode] {
    [node] + node.childNodes.flatMap(descendants)
}

/// Every node under `root` answering to `name`: exact name, else the NAME_mesh node.
func matches(_ name: String, in root: SCNNode) -> [SCNNode] {
    for wanted in [name, name + "_mesh"] {
        let found = descendants(root).filter { $0.name == wanted }
        if !found.isEmpty { return found }
    }
    return []
}

func findNode(_ name: String, in root: SCNNode) -> SCNNode? {
    root.childNode(withName: name, recursively: true)
        ?? root.childNode(withName: name + "_mesh", recursively: true)
}

/// Vertex positions under `node` (skipping `excluded` subtrees) in the space of `space`.
func vertices(_ node: SCNNode, in space: SCNNode, excluding excluded: Set<ObjectIdentifier> = []) -> [SIMD3<Float>] {
    let toSpace = space.simdWorldTransform.inverse
    var out: [SIMD3<Float>] = []
    func visit(_ n: SCNNode) {
        if excluded.contains(ObjectIdentifier(n)) { return }
        n.childNodes.forEach(visit)
        guard let source = n.geometry?.sources(for: .vertex).first,
              source.usesFloatComponents, source.bytesPerComponent == 4 else { return }
        let m = toSpace * n.simdWorldTransform
        source.data.withUnsafeBytes { raw in
            for i in 0..<source.vectorCount {
                let at = source.dataOffset + i * source.dataStride
                let p = SIMD4<Float>(raw.load(fromByteOffset: at, as: Float.self),
                                     raw.load(fromByteOffset: at + 4, as: Float.self),
                                     raw.load(fromByteOffset: at + 8, as: Float.self), 1)
                out.append(xyz(m * p))
            }
        }
    }
    visit(node)
    return out
}

func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

func bounds(_ points: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>)? {
    guard let first = points.first else { return nil }
    return points.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
}

func mm(_ v: SIMD3<Float>) -> String { String(format: "[%.3f, %.3f, %.3f]", v.x * 1000, v.y * 1000, v.z * 1000) }

/// Pose `node` at each range end and compare its geometry with where it should be.
func checkMotion(_ motion: [String: Any], node: SCNNode, root: SCNNode, label: String) -> [String] {
    guard let axis = motion["axis"] as? String,
          let range = (motion["range_m"] ?? motion["range_rad"]) as? [Double],
          let parent = node.parent else {
        return ["malformed motion \(motion)"]
    }
    let parts = axis.split(separator: "_").map(String.init)
    guard parts.count == 2, ["loc", "rot"].contains(parts[0]),
          let index = ["x", "y", "z"].firstIndex(of: parts[1]) else {
        return ["bad axis \(axis)"]
    }
    let isLoc = parts[0] == "loc"
    if !isLoc, simd_length(node.simdEulerAngles) > 1e-6 {
        return ["rest rotation \(node.simdEulerAngles) must be zero for a rot_* pivot (Euler order differs from Blender)"]
    }
    let rest = vertices(node, in: root)
    guard let (restLo, restHi) = bounds(rest) else { return ["no geometry under \(node.name ?? "?")"] }
    let parentToRoot = root.simdWorldTransform.inverse * parent.simdWorldTransform
    var unit = SIMD3<Float>(0, 0, 0)
    unit[index] = 1
    let basePosition = node.simdPosition, baseEuler = node.simdEulerAngles
    defer { node.simdPosition = basePosition; node.simdEulerAngles = baseEuler }

    var problems: [String] = []
    for value in range {
        let v = Float(value)
        let expected: simd_float4x4
        if isLoc {
            node.simdPosition = basePosition + unit * v
            var shift = matrix_identity_float4x4
            shift.columns.3 = SIMD4(unit * v, 1)
            expected = parentToRoot * shift * parentToRoot.inverse
        } else {
            var euler = baseEuler
            euler[index] += v
            node.simdEulerAngles = euler
            var toPivot = matrix_identity_float4x4, back = matrix_identity_float4x4
            toPivot.columns.3 = SIMD4(basePosition, 1)
            back.columns.3 = SIMD4(-basePosition, 1)
            let spin = simd_float4x4(simd_quatf(angle: v, axis: unit))
            expected = parentToRoot * toPivot * spin * back * parentToRoot.inverse
        }
        let moved = vertices(node, in: root)
        let (lo, hi) = bounds(moved)!
        let worst = zip(rest, moved).map { simd_length(xyz(expected * SIMD4($0, 1)) - $1) }.max() ?? 0
        let worstText = String(format: "%.4f", worst * 1000)
        if isLoc {
            let shift = (lo + hi) / 2 - (restLo + restHi) / 2
            let wanted = xyz(parentToRoot * SIMD4(unit * v, 0))
            print("  \(label) \(axis)=\(value): centre moved \(mm(shift)) mm, expected \(mm(wanted)), max vertex error \(worstText) mm")
            if simd_length(shift - wanted) > moveTolerance {
                problems.append("\(axis)=\(value) moved centre \(mm(shift)) mm, expected \(mm(wanted))")
            }
        } else {
            print("  \(label) \(axis)=\(value): bounds \(mm(lo))..\(mm(hi)) mm (rest \(mm(restLo))..\(mm(restHi))), max vertex error \(worstText) mm")
        }
        if worst > moveTolerance {
            problems.append("\(axis)=\(value) geometry off by \(String(format: "%.3f", worst * 1000)) mm")
        }
    }
    return problems
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
    let required = spec["nodes"] as? [String] ?? []
    let missing = required.filter { findNode($0, in: root) == nil }
    if !missing.isEmpty { reasons.append("missing nodes: " + missing.joined(separator: ", ")) }
    let motions = spec["motions"] as? [[String: Any]] ?? []
    var referenced = [rootName] + required + (spec["size_excludes"] as? [String] ?? [])
    referenced += motions.flatMap { [$0["node"] as? String ?? "?"] + ($0["allow_touch"] as? [String] ?? []) }
    for ref in NSOrderedSet(array: referenced).array as! [String] {
        let count = matches(ref, in: scene.rootNode).count
        if count > 1 { reasons.append("ambiguous name \(ref): \(count) nodes") }
    }

    let meshes = descendants(root).filter { $0.geometry != nil }
    let empty = meshes.filter { $0.geometry!.elements.allSatisfy { $0.primitiveCount == 0 } }
    if meshes.isEmpty { reasons.append("no geometry under \(rootName)") }
    if !empty.isEmpty {
        reasons.append("no drawable elements: " + empty.map { $0.name ?? "?" }.joined(separator: ", "))
    }

    let excluded = Set((spec["size_excludes"] as? [String] ?? [])
        .compactMap { findNode($0, in: root) }.map(ObjectIdentifier.init))
    let target = spec["size_mm"] as? [Double]
    if let (lo, hi) = bounds(vertices(root, in: root, excluding: excluded)) {
        let size = hi - lo
        print("  \(name) root-space bounds \(mm(lo))..\(mm(hi)) size_mm \(mm(size))")
        if let target, target.count == 3,
           (0..<3).contains(where: { abs(Double(size[$0]) * 1000 - target[$0]) > tolerance }) {
            reasons.append("size_mm \(mm(size)) vs target \(target)")
        }
    } else if target != nil {
        reasons.append("size_mm set but no vertex bounds could be computed")
    }

    for motion in motions {
        let nodeName = motion["node"] as? String ?? "?"
        guard let node = findNode(nodeName, in: root) else {
            reasons.append("motion node not found: \(nodeName)")
            continue
        }
        let label = "\(name) \(nodeName)"
        reasons += checkMotion(motion, node: node, root: root, label: label).map { "motion \(nodeName): \($0)" }
    }
    return reasons
}

let contractURL = resolve(contractArg)
guard let contract = readJSON(contractURL), let assets = contract["assets"] as? [String: [String: Any]] else {
    print("ERROR cannot read contract: \(contractURL.path)")
    exit(2)
}
let tolerance = contract["tolerance_mm"] as? Double ?? 0.5
let unknown = onlyAssets.subtracting(assets.keys)
if !unknown.isEmpty {
    print("ERROR unknown asset(s): \(unknown.sorted().joined(separator: ", "))")
    exit(2)
}
let partsDir = contractURL.deletingLastPathComponent().appendingPathComponent("contract_parts")
var failed = 0
for name in assets.keys.sorted() where onlyAssets.isEmpty || onlyAssets.contains(name) {
    var spec = assets[name]!
    let partURL = partsDir.appendingPathComponent("\(name).json")
    if FileManager.default.fileExists(atPath: partURL.path) {
        if let part = readJSON(partURL) {
            spec = deepMerge(spec, part)
        } else {
            print("FAIL \(name): unreadable \(partURL.path)")
            failed += 1
            continue
        }
    }
    let reasons = verify(name, spec, tolerance: tolerance)
    if reasons.isEmpty {
        print("OK \(name)")
    } else {
        failed += 1
        print("FAIL \(name): " + reasons.joined(separator: "; "))
    }
}
exit(failed == 0 ? 0 : 1)
