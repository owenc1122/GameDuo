"""Export the editable closed-console rig for the finger-driven insertion scene."""
import bpy
import math
import runpy
from pathlib import Path

root = Path(__file__).resolve().parents[1]
scene = bpy.context.scene
for obj in list(bpy.data.objects):
    obj.animation_data_clear()
    if obj.type in {'CAMERA', 'LIGHT'} or obj.name in {'Studio ground', 'REFERENCE · supplied photograph'}:
        bpy.data.objects.remove(obj, do_unlink=True)
lid = bpy.data.objects['LID · adjust Opening angle']
lid.rotation_euler.x = math.pi
# The original exterior only marked the rear opening. Give it actual insertion depth.
bpy.ops.mesh.primitive_cube_add(location=(0, 3, .47))
cutter = bpy.context.object
cutter.dimensions = (3.5868, 4.10, .44)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
shell = bpy.data.objects['Lower shell · outer bottom']
bpy.context.view_layer.objects.active = shell
cut = shell.modifiers.new('Rear slot clearance', 'BOOLEAN')
cut.operation = 'DIFFERENCE'
cut.object = cutter
bpy.ops.object.modifier_apply(modifier=cut.name)
bpy.data.objects.remove(cutter, do_unlink=True)
bpy.data.objects['Game card slot · dark well'].location.y = .97
bpy.data.objects['Game card slot · inner lip'].location.z = .23
scene.frame_set(1)
assert abs(lid.rotation_euler.x - math.pi) < 1e-4
scene['Interaction'] = 'Pull card down; closed console rises. Seat, latch, then open toward front. No orbit.'
bpy.ops.wm.save_as_mainfile(filepath=str(root / 'ReferenceModels/3DSXL-drag-insertion.blend'))
bpy.ops.wm.usd_export(filepath=str(root / 'DuoDS/Resources/3DSXL-Cartridge-Open-Transition.usdz'),
                      export_animation=False, export_materials=True, export_lights=False, export_cameras=False)
runpy.run_path(str(root / 'tools/texture_console.py'), run_name='__main__')
