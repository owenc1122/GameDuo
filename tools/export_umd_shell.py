"""Run in Blender with UMD_Model/PSP_UMD.blend open; never alter the source file.

The original material subsets import into SceneKit with vertices but zero draw
elements. Keep the evaluated casing, triangulate it and bind one complete material.
"""
from pathlib import Path
import bpy

root = Path(__file__).resolve().parent.parent
source = bpy.data.objects['White shell | continuous moulded frame']
depsgraph = bpy.context.evaluated_depsgraph_get()
mesh = bpy.data.meshes.new_from_object(source.evaluated_get(depsgraph), depsgraph=depsgraph)
shell = bpy.data.objects.new('UMD_Exact_White_Shell', mesh)
shell.matrix_world = source.matrix_world.copy()
bpy.context.scene.collection.objects.link(shell)
material = bpy.data.materials.new('UMD_Moulded_White_ABS_Runtime')
material.diffuse_color = (.88, .88, .88, 1)
material.use_nodes = True
shader = material.node_tree.nodes.get('Principled BSDF')
shader.inputs['Base Color'].default_value = (.88, .88, .88, 1)
shader.inputs['Roughness'].default_value = .31
mesh.materials.clear()
mesh.materials.append(material)
for polygon in mesh.polygons:
    polygon.material_index = 0
shell.modifiers.new('Runtime triangulation', 'TRIANGULATE')
shell.hide_set(False)
shell.hide_render = False
bpy.ops.object.select_all(action='DESELECT')
shell.select_set(True)
bpy.context.view_layer.objects.active = shell
bpy.ops.wm.usd_export(
    filepath=str(root / 'DuoDS/Resources/PSP-UMD-Shell.usdz'),
    selected_objects_only=True, export_materials=True,
    relative_paths=True, evaluation_mode='RENDER',
)
