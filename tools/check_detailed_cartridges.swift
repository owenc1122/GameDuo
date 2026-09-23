import SceneKit
import Foundation
let scene = try SCNScene(url: URL(fileURLWithPath: CommandLine.arguments[1]))
for name in ["ndsStandard", "ndsInfrared", "dsiEnhanced", "dsiExclusive", "threeDS"] {
    guard let model = scene.rootNode.childNode(withName: name, recursively: true) else { fatalError("Missing \(name)") }
    var contacts = 0, vertices = 0, microNormals = 0
    model.enumerateChildNodes { node, _ in
        if node.name?.hasPrefix("Gold_contact_") == true { contacts += 1 }
        vertices += node.geometry?.sources(for: .vertex).first?.vectorCount ?? 0
        microNormals += node.geometry?.materials.filter { $0.normal.contents != nil }.count ?? 0
    }
    assert(contacts == 17, "\(name): \(contacts) contacts")
    assert(vertices > 10000, "Detailed geometry missing")
    assert(microNormals > 0, "Plastic normal texture not exported")
    print("PASS \(name): \(contacts) contacts, \(vertices) vertices, \(microNormals) textured surfaces")
}
