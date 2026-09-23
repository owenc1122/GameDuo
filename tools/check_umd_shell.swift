import Foundation
import SceneKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let scene = try SCNScene(url: root.appendingPathComponent("DuoDS/Resources/PSP-UMD-Shell.usdz"))
var meshes = 0
var triangles = 0
scene.rootNode.enumerateChildNodes { node, _ in
    guard let geometry = node.geometry else { return }
    meshes += 1
    // A valid bounding box alone did not detect the original invisible-shell bug.
    precondition(!geometry.elements.isEmpty, "Shell has vertices but no drawable faces")
    precondition(!geometry.materials.isEmpty, "Shell material binding is missing")
    for element in geometry.elements {
        precondition(element.primitiveType == .triangles)
        precondition(element.primitiveCount > 0)
        triangles += element.primitiveCount
    }
    let box = geometry.boundingBox
    precondition(abs(Double(box.max.x - box.min.x) - 0.064) < 0.00001)
    precondition(abs(Double(box.max.y - box.min.y) - 0.065) < 0.00001)
    precondition(abs(Double(box.max.z - box.min.z) - 0.0042) < 0.00001)
}
precondition(meshes == 1 && triangles > 0)
print("UMD_SHELL_PASS: original 64 x 65 x 4.2 mm casing, \(triangles) drawable triangles")
