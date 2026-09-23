"""Build one continuous shot from cartridge insertion to the emulator's exact shell framing."""

import bpy
import math
from pathlib import Path
from mathutils import Vector

ROOT = Path("/Users/owen/.codex/.chatgpt-projects/g-p-6aae50355278819184d3cecdd5c348b5")
OUT_BLEND = ROOT / "ReferenceModels/3DSXL-cartridge-open-transition.blend"
OUT_USDZ = ROOT / "DuoDS/Resources/3DSXL-Cartridge-Open-Transition.usdz"
PREVIEW_DIR = ROOT / "ReferenceModels/OpenTransitionPreview"
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


def cube(name, dimensions, location, mat, bevel=0.0, parent=None):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    if bevel:
        modifier = obj.modifiers.new("Edge radius", "BEVEL")
        modifier.width = bevel
        modifier.segments = 3
    obj.parent = parent
    return obj


def point_at(obj, target):
    obj.rotation_quaternion = (Vector(target) - obj.location).to_track_quat("-Z", "Y")


def object_fcurves(obj):
    animation = obj.animation_data
    action = animation.action
    strip = action.layers[0].strips[0]
    return strip.channelbag(animation.action_slot).fcurves


def smooth_curves(obj, mode="AUTO_CLAMPED"):
    for curve in object_fcurves(obj):
        for point in curve.keyframe_points:
            point.interpolation = "BEZIER"
            point.handle_left_type = mode
            point.handle_right_type = mode


# Remove presentation-only items but retain every real console component.
for obj in list(bpy.data.objects):
    if obj.type in {"CAMERA", "LIGHT"} or obj.name in {
        "Studio ground",
        "REFERENCE · supplied photograph",
    }:
        bpy.data.objects.remove(obj, do_unlink=True)

scene = bpy.context.scene
lid = bpy.data.objects["LID · adjust Opening angle"]
lid.animation_data_clear()  # The source's fixed opening-angle driver overrides rotation keys.

# The console never moves or gets replaced. Only its real hinge and one camera animate.
# The final camera values are copied from the Blender render used by the emulator shell PNG.
lid.rotation_mode = "XYZ"
lid.rotation_euler.x = math.radians(115)
lid.keyframe_insert("rotation_euler", frame=1)
lid.keyframe_insert("rotation_euler", frame=92)
lid.rotation_euler.x = math.radians(48)
lid.keyframe_insert("rotation_euler", frame=126)
lid.rotation_euler.x = math.radians(-2.5)
lid.keyframe_insert("rotation_euler", frame=148)
lid.rotation_euler.x = 0
lid.keyframe_insert("rotation_euler", frame=158)
smooth_curves(lid)

# Cartridge proportions and slot clearance match the physical card bay already in the model.
card_shell = material("NTR card shell", (0.115, 0.12, 0.125), roughness=0.72)
label_mat = material("Dynamic cartridge label", (0.82, 0.82, 0.80), roughness=0.76)
contact_bed_mat = material("Cartridge contact bed", (0.025, 0.028, 0.03), roughness=0.82)
contact_mat = material("Cartridge contacts", (0.82, 0.57, 0.10), metallic=0.72, roughness=0.25)
slot_cavity_mat = material("Game slot cavity", (0.008, 0.009, 0.010), roughness=0.92)
# The exterior reference has a shallow black slot marker. Cut a real blind bay through
# the rear wall, keeping the source opening's exact width and height.
slot_cutter = cube("Slot cavity cutter", (3.5868, 4.10, 0.3312), (0, 3.0, 0.47), slot_cavity_mat)
shell = bpy.data.objects["Lower shell · outer bottom"]
bpy.context.view_layer.objects.active = shell
cut = shell.modifiers.new("Real rear cartridge bay", "BOOLEAN")
cut.operation = "DIFFERENCE"
cut.solver = "EXACT"
cut.object = slot_cutter
bpy.ops.object.modifier_apply(modifier=cut.name)
bpy.data.objects.remove(slot_cutter, do_unlink=True)
well = bpy.data.objects["Game card slot · dark well"]
well.location.y = 0.97

card_rig = bpy.data.objects.new("Cartridge_Rig", None)
scene.collection.objects.link(card_rig)
# The modeled slot is centered at y=4.52, 3.5868 units wide and 0.3312 deep.
# Keep the physical card within that clearance instead of intersecting the slot lip.
card_rig.location = (0, 8.20, 0.47)
cube("Cartridge_Body", (3.30, 3.50, 0.14), (0, 0, 0), card_shell, 0.08, card_rig)
# A planar label needs a full-face UV map; cube-atlas UVs crop the runtime game artwork.
label_mesh = bpy.data.meshes.new("Cartridge label surface")
label_mesh.from_pydata([(-1.31, -1, 0.079), (1.31, -1, 0.079),
                       (1.31, 1.24, 0.079), (-1.31, 1.24, 0.079)], [], [(0, 1, 2, 3)])
label_uv = label_mesh.uv_layers.new(name="UVMap")
for loop, uv in zip(label_uv.data, [(0, 0), (1, 0), (1, 1), (0, 1)]):
    loop.uv = uv
label_obj = bpy.data.objects.new("Cartridge_Label", label_mesh)
scene.collection.objects.link(label_obj)
label_obj.parent = card_rig
label_mesh.materials.append(label_mat)
cube("Cartridge_Contact_Bed", (2.72, 1.14, 0.016), (0, 0.60, -0.076), contact_bed_mat, 0.04, card_rig)
for index in range(17):
    cube(
        f"Cartridge_Contact_{index + 1:02d}",
        (0.072, 0.72, 0.012),
        (-1.08 + index * 0.135, 0.65, -0.088),
        contact_mat,
        0.01,
        card_rig,
    )

card_rig.rotation_mode = "XYZ"
card_rig.keyframe_insert("location", frame=1)
card_rig.rotation_euler = (0, 0, 0)
card_rig.keyframe_insert("rotation_euler", frame=1)
card_rig.rotation_euler.z = math.pi
card_rig.keyframe_insert("rotation_euler", frame=42)
card_rig.keyframe_insert("location", frame=42)
card_rig.location = (0, 6.60, 0.47)
card_rig.keyframe_insert("rotation_euler", frame=58)
card_rig.keyframe_insert("location", frame=58)
# The outer edge ends just behind the slot lip: 2.90 + half-length 1.75 = 4.65.
card_rig.location.y = 2.90
card_rig.keyframe_insert("location", frame=82)
card_rig.keyframe_insert("location", frame=88)
smooth_curves(card_rig)

# Explicit fast-to-slow 180° card turn.
rotation_curve = next(
    curve for curve in object_fcurves(card_rig)
    if curve.data_path == "rotation_euler" and curve.array_index == 2
)
for point in rotation_curve.keyframe_points:
    point.interpolation = "BEZIER"
    point.handle_left_type = "FREE"
    point.handle_right_type = "FREE"
rotation_curve.keyframe_points[0].handle_right = (7, math.pi * 0.48)
rotation_curve.keyframe_points[1].handle_left = (29, math.pi * 0.98)

# One orthographic camera moves continuously from the slot to the emulator's exact top-down frame.
# Keeping the camera orthographic also avoids a perspective pop during the final handoff.
camera_data = bpy.data.cameras.new("Transition_Camera")
camera = bpy.data.objects.new("Transition_Camera", camera_data)
scene.collection.objects.link(camera)
camera.rotation_mode = "QUATERNION"
camera_data.type = "ORTHO"
camera_data.ortho_scale = 10.5
camera.location = (0.0, 14.0, 5.0)
point_at(camera, (0, 4.60, 0.65))
camera.keyframe_insert("location", frame=1)
camera.keyframe_insert("rotation_quaternion", frame=1)
camera_data.keyframe_insert("ortho_scale", frame=1)
camera.keyframe_insert("location", frame=30)
camera.keyframe_insert("rotation_quaternion", frame=30)
camera_data.keyframe_insert("ortho_scale", frame=30)
camera.location = (1.5, 14.0, 4.0)
point_at(camera, (0, 4.65, 0.47))
camera_data.ortho_scale = 10.5
camera.keyframe_insert("location", frame=42)
camera.keyframe_insert("rotation_quaternion", frame=42)
camera_data.keyframe_insert("ortho_scale", frame=42)
camera.keyframe_insert("location", frame=58)
camera.keyframe_insert("rotation_quaternion", frame=58)
camera_data.keyframe_insert("ortho_scale", frame=58)
camera.keyframe_insert("location", frame=88)
camera.keyframe_insert("rotation_quaternion", frame=88)
camera_data.keyframe_insert("ortho_scale", frame=88)

# Sample the one-take path densely so the camera cannot take a 180° quaternion shortcut.
start_location = Vector((1.5, 14.0, 4.0))
control_location = Vector((2.2, 10.2, 18.0))
end_location = Vector((-0.01, 4.05, 30.0))
start_target = Vector((0, 4.65, 0.47))
end_target = Vector((-0.01, 4.05, 0.0))
previous_quaternion = camera.rotation_quaternion.copy()
for frame in range(90, 159, 2):
    raw = (frame - 88) / 70
    t = raw * raw * (3 - 2 * raw)
    target = start_target.lerp(end_target, t)
    # Orbit to the front while rising so the top-down endpoint has the same up direction
    # as the emulator. A straight rear-to-overhead move produces a last-frame 180° flip.
    start_angle = math.atan2(start_location.x - start_target.x, start_location.y - start_target.y)
    angle = start_angle + (math.pi - start_angle) * t
    radius = math.hypot(start_location.x - start_target.x, start_location.y - start_target.y) * (1 - t)
    location = Vector((target.x + math.sin(angle) * radius,
                       target.y + math.cos(angle) * radius,
                       start_location.z + (end_location.z - start_location.z) * t))
    quaternion = (target - location).to_track_quat("-Z", "Y")
    if quaternion.dot(previous_quaternion) < 0:
        quaternion.negate()
    camera.location = location
    camera.rotation_quaternion = quaternion
    camera.keyframe_insert("location", frame=frame)
    camera.keyframe_insert("rotation_quaternion", frame=frame)
    previous_quaternion = quaternion.copy()

# Exact endpoint of Nintendo-3DS-XL-180deg.png used by Rendered3DSXLConsoleView.
camera.location = end_location
camera.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
# 27.16 is the exact full-screen equivalent of the 18.75 source render when
# Nintendo-3DS-XL-180deg.png is fitted by Rendered3DSXLConsoleView at 900x1600.
camera_data.ortho_scale = 27.16
camera.keyframe_insert("location", frame=158)
camera.keyframe_insert("rotation_quaternion", frame=158)
camera_data.keyframe_insert("ortho_scale", frame=158)
smooth_curves(camera)
smooth_curves(camera_data)
for curve in object_fcurves(camera):
    if curve.data_path == "rotation_quaternion":
        for point in curve.keyframe_points:
            point.interpolation = "LINEAR"
scene.camera = camera

# Fail generation if the source driver returns or the entry path leaves the slot clearance.
scene.frame_set(1)
assert abs(lid.rotation_euler.x - math.radians(115)) < 1e-4
for frame in range(58, 89):
    scene.frame_set(frame)
    assert abs(card_rig.location.x) < 1e-4 and abs(card_rig.location.z - 0.47) < 1e-4
    assert abs(card_rig.rotation_euler.z - math.pi) < 1e-4
scene.frame_set(158)
assert abs(lid.rotation_euler.x) < 1e-4


def area(name, location, energy, size, color, target):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = location
    obj.rotation_mode = "QUATERNION"
    point_at(obj, target)


# One broad source only: no paired circular highlights on the screens.
area("Single_Softbox", (-2.0, 11.0, 12.0), 1550, 11.0, (1.0, 0.97, 0.92), (0, 4.60, 0.6))

scene.frame_start = 1
scene.frame_end = 164
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 900
scene.render.resolution_y = 1600
scene.render.resolution_percentage = 62
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.film_transparent = True
scene.render.fps = 30
world = scene.world or bpy.data.worlds.new("Transition world")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.012, 0.014, 0.018, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.52

for frame in (1, 42, 52, 64, 74, 82, 104, 128, 146, 158):
    scene.frame_set(frame)
    scene.render.filepath = str(PREVIEW_DIR / f"frame-{frame:03d}.png")
    bpy.ops.render.render(write_still=True)

scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT_BLEND))
bpy.ops.wm.usd_export(
    filepath=str(OUT_USDZ),
    export_animation=True,
    export_materials=True,
    # SceneKit displays Blender's exported disk lights as visible white geometry.
    # Runtime lights are recreated from the same rig values in Swift instead.
    export_lights=False,
    export_cameras=True,
)
print(f"Saved {OUT_BLEND}")
print(f"Exported {OUT_USDZ}")
