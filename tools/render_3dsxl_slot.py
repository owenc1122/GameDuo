"""Render the original SPR-001 rear game-card bay from the editable Blender source."""

import bpy
from mathutils import Vector

OUTPUT = "/Users/owen/.codex/.chatgpt-projects/g-p-6aae50355278819184d3cecdd5c348b5/DuoDS/Resources/3DSXL-GameCard-Slot.png"

keep_prefixes = (
    "Lower shell · outer bottom",
    "Lower shell · top deck",
    "Continuous housing seam",
    "Game card slot",
    "Hinge · lower structural bridge",
    "AC charging socket",
    "AC socket",
    "Charging cradle",
    "Infrared transceiver",
    "Wrist strap anchor",
)

for obj in bpy.data.objects:
    obj.hide_render = not obj.name.startswith(keep_prefixes)

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 1800
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.film_transparent = True
scene.render.filepath = OUTPUT

world = scene.world or bpy.data.worlds.new("Slot render world")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.055, 0.060, 0.065, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.34

def point_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()

camera_data = bpy.data.cameras.new("Game card slot close-up camera")
camera = bpy.data.objects.new("Game card slot close-up camera", camera_data)
scene.collection.objects.link(camera)
camera.location = (0, 13.2, 3.65)
point_at(camera, (0, 4.36, 0.62))
camera_data.type = "ORTHO"
camera_data.ortho_scale = 4.25
scene.camera = camera

def area(name, location, energy, size, color, target):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "RECTANGLE"
    data.size = size
    data.size_y = size * 0.55
    data.color = color
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = location
    point_at(obj, target)

area("Slot key", (-5.2, 10.0, 8.0), 1250, 7.0, (1.0, 0.96, 0.90), (0, 4.3, 0.7))
area("Slot rim", (5.6, 8.0, 4.5), 900, 5.0, (0.72, 0.82, 1.0), (0, 4.4, 0.5))
area("Slot face fill", (0, 15.0, 1.5), 700, 4.0, (1.0, 1.0, 1.0), (0, 4.5, 0.55))

bpy.ops.render.render(write_still=True)
print(f"Rendered original 3DS XL game-card bay to {OUTPUT}")
