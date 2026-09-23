import SceneKit
let scene = try SCNScene(url: URL(fileURLWithPath: CommandLine.arguments[1]))
for n in scene.rootNode.childNodes { print("ROOT", n.name ?? "", n.transform) }
scene.rootNode.enumerateChildNodes { node, _ in
    if (node.name ?? "").contains("LID") || (node.name ?? "").contains("outer_bottom") {
        print(node.name ?? "", "parent", node.parent?.name ?? "", "position", node.position, "angles", node.eulerAngles, "world", node.worldPosition)
    }
}
