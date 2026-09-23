"""Check renders for the DualShock 2 asset (imported by build_dualshock2.py --render).

Adds a studio (floor, lights, camera) AFTER the .blend was saved, renders
ds2_front.png (3/4 from the player side), ds2_top.png (orthographic top-down) and
ds2_motion.png (sticks tilted, L2 pulled, CROSS pressed, D-pad tilted), then
restores the rest pose. Cycles, low sample count (8 GB machine).
"""
import math
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

MM = 0.001


def _look(cam, eye_mm, target_mm, up=(0, 1, 0)):
    eye, target = Vector(eye_mm) * MM, Vector(target_mm) * MM
    f = (target - eye).normalized()
    r = f.cross(Vector(up)).normalized()
    u = r.cross(f)
    M = Matrix((r, u, -f)).transposed().to_4x4()
    M.translation = eye
    cam.matrix_world = M


def _area(name, loc_mm, target_mm, size, power):
    data = bpy.data.lights.new(name, 'AREA')
    data.size, data.energy = size, power
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    _look(obj, loc_mm, target_mm)
    return obj


def studio():
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 32
    sc.cycles.use_denoising = True
    sc.render.resolution_x, sc.render.resolution_y = 1200, 900
    sc.render.film_transparent = False
    sc.view_settings.view_transform = 'Standard'
    sc.view_settings.exposure = 0.0
    world = bpy.data.worlds.new('studio')
    world.use_nodes = True
    bg = world.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (0.78, 0.79, 0.8, 1)
    bg.inputs['Strength'].default_value = 0.04
    sc.world = world
    # floor = table (Y = 0 plane)
    me = bpy.data.meshes.new('floor')
    s = 0.6
    me.from_pydata([(-s, 0, -s), (s, 0, -s), (s, 0, s), (-s, 0, s)], [], [(0, 3, 2, 1)])
    floor = bpy.data.objects.new('floor', me)
    fm = bpy.data.materials.new('floor')
    fm.use_nodes = True
    fm.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.72, 0.72, 0.73, 1)
    fm.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.8
    # white sweep like the studio photo, self-lit so no big overhead softbox has to
    # light it (that softbox's reflection washed the black satin out to grey)
    fm.node_tree.nodes['Principled BSDF'].inputs['Emission Color'].default_value = (1, 1, 1, 1)
    fm.node_tree.nodes['Principled BSDF'].inputs['Emission Strength'].default_value = 0.8
    me.materials.append(fm)
    sc.collection.objects.link(floor)
    floor.location.y = -0.0002
    _area('key', (-220, 420, 180), (0, 30, 0), 0.25, 5)
    _area('fill', (320, 200, 120), (0, 30, 0), 0.4, 1.0)
    _area('rim', (0, 300, -400), (0, 30, 0), 0.3, 4)
    cam_data = bpy.data.cameras.new('cam')
    cam = bpy.data.objects.new('cam', cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    return cam


ONLY = None


def render(path):
    if ONLY and Path(path).stem not in ONLY:
        return
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    print(f'[ds2] rendered {path}')


def render_all(root, outdir, only=None):
    global ONLY
    ONLY = only
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    cam = studio()
    cd = cam.data
    # 3/4 from the player side (like the Evan-Amos photo)
    cd.type = 'PERSP'
    cd.lens = 70
    _look(cam, (-95, 330, 330), (0, 22, -8))
    render(outdir / 'ds2_front.png')
    # orthographic top-down, shoulders at the top of the image
    cd.type = 'ORTHO'
    cd.ortho_scale = 0.185
    _look(cam, (0, 400, -5), (0, 0, -5), up=(0, 0, -1))
    render(outdir / 'ds2_top.png')
    # motion pose
    obj = bpy.data.objects
    pose = {
        'STICK_L': ('rot', 0, -0.4363), 'STICK_R': ('rot', 2, 0.4363),
        'L2': ('rot', 0, -0.1396), 'BTN_CROSS': ('loc', 1, -0.002),
        'DPAD': ('rot', 2, 0.0873), 'R1': ('loc', 1, -0.002),
    }
    saved = {}
    for name, (kind, i, v) in pose.items():
        o = obj[name]
        saved[name] = (o.location.copy(), o.rotation_euler.copy())
        if kind == 'rot':
            o.rotation_euler[i] += v
        else:
            o.location[i] += v
    cd.type = 'PERSP'
    cd.lens = 60
    _look(cam, (-290, 210, -150), (0, 25, -5))
    render(outdir / 'ds2_motion.png')
    for name, (loc, rot) in saved.items():
        obj[name].location, obj[name].rotation_euler = loc, rot
