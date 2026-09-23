"""Build the cartridge insertion shot from the editable local 3DS XL source."""

import bpy
import math
from pathlib import Path
from mathutils import Vector

ROOT = Path("/Users/owen/.codex/.chatgpt-projects/g-p-6aae50355278819184d3cecdd5c348b5")
OUT_BLEND = ROOT / "ReferenceModels/3DSXL-cartridge-insertion.blend"
OUT_USDZ = ROOT / "DuoDS/Resources/3DSXL-Cartridge-Insertion.usdz"
PREVIEW_DIR = ROOT / "ReferenceModels/InsertionPreview"
PREVIEW_DIR.mkdir(parents=True, exist_ok=True)


def material(name, color, metallic=0.0, roughness=0.65):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def cube(name, scale, location, mat, bevel=0.0, parent=None):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    if bevel:
        modifier = obj.modifiers.new("Edge radius", "BEVEL")
        modifier.width = bevel
        modifier.segments = 3
    if parent:
        obj.parent = parent
    return obj


def point_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


def object_fcurves(obj):
    """Return Blender 5.2 layered-action curves for one animated object."""
    animation = obj.animation_data
    action = animation.action
    slot = animation.action_slot
    strip = action.layers[0].strips[0]
    return strip.channelbag(slot).fcurves


# Keep only the real lower rear housing and hinge from the user's editable source.
keep_prefixes = (
    "Lower shell · outer bottom",
    "Lower shell · top deck",
    "Continuous housing seam",
    "Hinge · lower structural bridge",
    "AC charging socket",
    "AC socket",
    "Charging cradle",
    "Infrared transceiver",
    "Wrist strap anchor",
)
for obj in list(bpy.data.objects):
    if obj.type in {"CAMERA", "LIGHT"} or not obj.name.startswith(keep_prefixes):
        bpy.data.objects.remove(obj, do_unlink=True)

shell = material("SPR-001 graphite shell", (0.105, 0.115, 0.12), roughness=0.56)
slot_dark = material("Card slot dark well", (0.018, 0.021, 0.023), roughness=0.82)
slot_lip = material("Card slot lip", (0.07, 0.075, 0.08), roughness=0.60)
card_shell = material("NTR card shell", (0.115, 0.12, 0.125), roughness=0.72)
label_mat = material("Dynamic cartridge label", (0.82, 0.82, 0.80), roughness=0.76)
contact_mat = material("Cartridge contacts", (0.82, 0.57, 0.10), metallic=0.72, roughness=0.25)

# Slot width is the 33 mm card width plus 0.6 mm total mechanical clearance.
card_width = 3.30
card_height = 3.50
card_depth = 0.38
slot_width = 3.36

console_rig = bpy.data.objects.new("Console_Rig", None)
bpy.context.scene.collection.objects.link(console_rig)
for obj in list(bpy.data.objects):
    if obj != console_rig and obj.parent is None and obj.type == "MESH":
        obj.parent = console_rig

# Replace the oversized reference bay with a card-matched opening and visible inner throat.
slot_well = cube("Game_Card_Slot_Well", (slot_width, 0.46, 0.20), (0, 4.54, 0.53), slot_dark, 0.055, console_rig)
slot_throat = cube("Game_Card_Slot_Throat", (slot_width - 0.08, 0.28, 0.42), (0, 4.49, 0.40), slot_dark, 0.035, console_rig)
slot_lip_obj = cube("Game_Card_Slot_Lip", (slot_width + 0.12, 0.12, 0.12), (0, 4.70, 0.58), slot_lip, 0.04, console_rig)

# Stand the real lower housing upright so its rear-edge slot receives a vertical card.
console_rig.rotation_euler.x = math.pi / 2
console_rig.location = (0, 5.0, -3.8)

# One rigid vertical cartridge authored in Blender, including a recessed rear contact bed.
card_rig = bpy.data.objects.new("Cartridge_Rig", None)
bpy.context.scene.collection.objects.link(card_rig)
card_rig.location = (0, 4.20, 3.15)
card_body = cube("Cartridge_Body", (card_width, card_depth, card_height), (0, 0, 0), card_shell, 0.10, card_rig)
label = cube("Cartridge_Label", (2.62, 0.025, 2.24), (0, 0.203, 0.12), label_mat, 0.05, card_rig)
contact_bed = cube("Cartridge_Contact_Bed", (2.72, 0.035, 1.14), (0, -0.202, -0.60), slot_dark, 0.05, card_rig)

contact_count = 17
spacing = 0.135
start = -(contact_count - 1) * spacing / 2
for index in range(contact_count):
    cube(
        f"Cartridge_Contact_{index + 1:02d}",
        (0.072, 0.025, 0.72),
        (start + index * spacing, -0.225, -0.65),
        contact_mat,
        0.01,
        card_rig,
    )

# Parent transforms retain the card's vertical orientation throughout the shot.
card_rig.rotation_euler = (0, 0, 0)
card_rig.keyframe_insert("rotation_euler", frame=1)
card_rig.rotation_euler.z = math.pi
card_rig.keyframe_insert("rotation_euler", frame=42)
card_rig.keyframe_insert("rotation_euler", frame=52)
card_rig.location.z = 3.15
card_rig.keyframe_insert("location", frame=52)
card_rig.location.z = -0.80
card_rig.keyframe_insert("location", frame=82)

# Start fast and settle slowly into the 180-degree rear view.
rotation_curve = next(fc for fc in object_fcurves(card_rig) if fc.data_path == "rotation_euler" and fc.array_index == 2)
for point in rotation_curve.keyframe_points:
    point.interpolation = "BEZIER"
    point.handle_left_type = "FREE"
    point.handle_right_type = "FREE"
rotation_curve.keyframe_points[0].handle_right = (7, math.pi * 0.48)
rotation_curve.keyframe_points[1].handle_left = (29, math.pi * 0.98)
for fc in object_fcurves(card_rig):
    if fc.data_path == "location":
        for point in fc.keyframe_points:
            point.interpolation = "BEZIER"
            point.handle_left_type = "AUTO_CLAMPED"
            point.handle_right_type = "AUTO_CLAMPED"

# The partial console enters while the card turns, then remains fixed as the card drops in.
console_rig.location.z = -5.2
console_rig.keyframe_insert("location", frame=1)
console_rig.location.z = -3.8
console_rig.keyframe_insert("location", frame=34)
for fc in object_fcurves(console_rig):
    for point in fc.keyframe_points:
        point.interpolation = "BEZIER"
        point.handle_left_type = "AUTO_CLAMPED"
        point.handle_right_type = "AUTO_CLAMPED"

scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = 90
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 900
scene.render.resolution_y = 1600
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.film_transparent = True
scene.render.fps = 30

world = scene.world or bpy.data.worlds.new("Insertion world")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.012, 0.014, 0.018, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.28

camera_data = bpy.data.cameras.new("Insertion_Camera")
camera = bpy.data.objects.new("Insertion_Camera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0, 13.2, 2.9)
point_at(camera, (0, 4.55, 1.2))
camera_data.type = "ORTHO"
camera_data.ortho_scale = 6.8
scene.camera = camera

def area(name, location, energy, size, color, target):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "RECTANGLE"
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = location
    point_at(obj, target)

area("Key_Light", (-5.5, 10.0, 8.5), 1200, 6.0, (1.0, 0.95, 0.88), (0, 4.5, 1.4))
area("Rim_Light", (5.5, 7.5, 5.5), 920, 4.5, (0.70, 0.82, 1.0), (0, 4.5, 1.4))
area("Front_Fill", (0, 13.0, 3.2), 680, 4.0, (1.0, 1.0, 1.0), (0, 4.5, 1.4))

for frame in (1, 18, 42, 62, 82):
    scene.frame_set(frame)
    scene.render.filepath = str(PREVIEW_DIR / f"frame-{frame:03d}.png")
    bpy.ops.render.render(write_still=True)

scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT_BLEND))
bpy.ops.wm.usd_export(
    filepath=str(OUT_USDZ),
    export_animation=True,
    export_materials=True,
    export_lights=True,
    export_cameras=True,
)
print(f"Saved {OUT_BLEND}")
print(f"Exported {OUT_USDZ}")
