import SceneKit
import Foundation
import AppKit
let scene = try SCNScene(url: URL(fileURLWithPath: CommandLine.arguments[1]))
var materials = [String: SCNMaterial]()
var lid: SCNNode?
scene.rootNode.enumerateChildNodes { node, _ in
    if node.name?.hasPrefix("LID_") == true { lid = node }
    for material in node.geometry?.materials ?? [] { materials[material.name ?? ""] = material }
}
assert(lid != nil, "Opening pivot lost")
assert(materials.count >= 12, "Separate hardware materials lost")
let normals = materials.values.filter {
    guard let contents = $0.normal.contents else { return false }
    return !(contents is NSNumber) && !(contents is NSColor)
}.count
let roughnessMaps = materials.values.filter { value in
    guard let contents = value.roughness.contents else { return false }
    return !(contents is NSNumber)
}.count
assert(normals >= 5, "Microtexture maps missing")
assert(roughnessMaps >= 5, "Per-material roughness maps missing")
print("CONSOLE_MATERIALS_PASS: \(materials.count) materials, \(normals) normals, \(roughnessMaps) roughness maps, lid pivot retained")
