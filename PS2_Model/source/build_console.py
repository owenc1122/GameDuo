"""Build the PlayStation 2 "fat" console SCPH-30001 (NTSC-U/C, black) runtime model.

Run from the repo root (headless):

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        --python-exit-code 1 --python PS2_Model/source/build_console.py -- --check --render

All flags go after `--` (Blender's own parser stops there); each is optional.

Outputs PS2_Model/exports/PS2-Console.usdz and PS2_Model/PS2-Console.blend.
--check  after saving: proxy fit tests (memory card 42x7.5x56.5 at SLOT_MC_n, DualShock 2
         plug lip/collar/body with its 3 windows at PORT_CTRL_n, and the real memory
         card model from PS2_Model/PS2-MemoryCard.blend, which must exist - build the
         memory card first) against every static mesh; then the real PS2 DVD (built
         from PS2_Disc_Case/source/build_dvd.py, not exported) at TRAY_DISC_ANCHOR
         against every console mesh with the tray closed and ejected. Exits 1 on any hit.
--render after saving: PS2_Model/renders/console_{front34,rear,tray_open}.png
         (tray_open: tray ejected, memory card inserted in slot 1).
--closeups DIR  after saving: extra close-up renders console_cu_{right,left,tray,rear}.png
         into DIR (a development aid for photo comparison; not used by run_all.sh).

Frame (contract_parts/PS2-Console.json): console lying flat, Y up, front (fins) +Z.
Root PS2_CONSOLE = bottom centre of the bbox; x -150.5..150.5, y 0..78, z -91..91
(front fin faces z = +91). All layout numbers below are mm in that frame.

Body shape (REFERENCE_NOTES_console.md):
  upper tier  y 37.7..78: a core block plus 6 horizontal fins (fin 1 = top plate) that
              stand 3 mm proud of the core on the FRONT and RIGHT (x+) side only, so the
              grooves wrap front + right; left side and back are flat.
  lower tier  x -149.5..122.5, y 1..36, z -91..70: narrower box, front set back 21 mm
              (carries USB x2 + i.LINK on a blue panel and the front vent grille), right
              side 28 mm under the upper-tier overhang.
  tier gap    1.7 mm shadow slot (y 36..37.7) 2.5 mm deep around the left side and the
              rear x+ half; the rear x- half (fan + power) is one flat panel.
  The left side is x = -149.5 and four rubber pads stand 1.0 mm proud to x = -150.5, so
  the official 301 mm width includes the pads (estimate; the pads are graded 估计).
  Six square rubber feet y 0..1.4 under the lower tier (body bottom y = 1.0).

Hierarchy (every movable node rests at rotation 0; loc_* motions are offsets from the
node's rest location, which the app reads at load time; geometry in root space):
  PS2_CONSOLE
    BODY              one closed mesh: tiers, fins, cavities (tray bay, button pockets,
                      memory card slots, controller ports, grille, rear ports, bay)
    DETAILS           static extras (multi-material): USB panel, port pin blocks, USB /
                      i.LINK / AV shells and tongues, fan + hub, power rocker, AC pins,
                      expansion bay cover, feet, side pads
    DISC_TRAY         tray (face with 2 fin bars + badge boss, plate with 120/80 mm disc
                      wells, spindle hole, laser slot); loc_z 0 closed .. +0.135 ejected
      TRAY_DISC_ANCHOR  disc centre (mid-thickness) seated in the 120 mm well
      TRADEMARK_PRINTS_TRAY  PS family logo on the tray face (moves with the tray, so it
                      cannot live under TRADEMARK_PRINTS)
    BTN_RESET / BTN_EJECT   buttons in pockets (0.4 mm side clearance, 0.5 mm behind
                      when pressed -1 mm); icons are part of the button mesh
      LED_POWER / LED_EJECT  1.6 mm lenses set into the button corner (the light pipe
                      is part of the key cap on the real console, so the lens moves with
                      its button); materials LED_POWER_off / LED_EJECT_off
    PORT_CTRL_1/2     DualShock 2 plug origin when fully inserted: (x, 47.0, 82.3); plug
                      lip (9 mm) + collar sit in a 41.8 x 9.3 x 9.2 mm recess, 3 pin blocks
                      fit inside the plug's windows; plug body face 0.3 mm off the fins
    SLOT_MC_1/2       memory card origin when fully inserted: (x, 61.5, 49.5); card
                      inserted 41.5 mm, protrudes 15 mm (estimated from scph30007r_front.jpg)
    MC_DOOR_1/2       memory card slot spring doors printed MEMORY CARD; origin = hinge
                      line, rest closed, rot_x +pi/2 swings them up into a pocket (extra
                      motion in the part file; the app must open a door before showing a
                      card in its slot - a closed door and an inserted card intersect)
    TRADEMARK_PRINTS  top blue PS2 logo, top "PlayStation 2" wordmark, vertical raised
                      silver SONY, rear-sticker SONY / "PlayStation(R)2": all from the
                      shared vectors in tools/ps2_blender/vectors (import_curve.svg); plus
                      CD/DOLBY/dts/DVD strip, "1 / MagicGate / 2", port triangles,
                      blue-panel icons, rear sticker text, port labels, warranty seal,
                      EXPANSION BAY
Vectors: PlayStation2_logo_commons.svg (P/S/2 polygons fitted to the photo-measured bbox,
4-step contract gradient; wordmark paths without (R) on the top), PlayStation_logo_commons.svg
(colour tray logo, (R) dropped, coloured by island + bisect), SONY.svg. Texts with no public
vector (RESET, MEMORY CARD, MagicGate, 1/2, S400, rear labels, sticker small print, media
strip) use macOS Arial / Arial Bold - glyph shapes are approximations, sizes are fitted.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/ps2_blender"))
import common as C  # noqa: E402

MM = 0.001
SPEC = C.load_contract('PS2-Console')
LAY = SPEC['layout']
COL = SPEC['colors']
FINS = SPEC['fins']['y_ranges_mm']            # top (fin 1) .. bottom (fin 6)
TRAVEL = SPEC['tray_travel_m']

FRONT_Z = 91.0
REAR_Z = -91.0
LEFT_X = -149.5          # body left face; pads reach -150.5
RIGHT_X = 150.5
GROOVE = SPEC['fins']['groove_depth_mm']      # 3.0
LIFT = 0.04              # flat prints above their face (mm)

FONT_DIR = Path('/System/Library/Fonts/Supplemental')
FONTS = {'regular': FONT_DIR / 'Arial.ttf', 'bold': FONT_DIR / 'Arial Bold.ttf',
         'serif': FONT_DIR / 'SuperClarendon.ttc', 'narrow': FONT_DIR / 'Arial Narrow.ttf'}

# text / print frames: (reading dir, glyph-up dir, outward normal)
F_FRONT = ((1, 0, 0), (0, 1, 0), (0, 0, 1))
F_SONY = ((0, -1, 0), (1, 0, 0), (0, 0, 1))     # reads top->bottom, glyph tops to +x
F_TOP_Z = ((0, 0, 1), (1, 0, 0), (0, 1, 0))     # top face, reads rear->front, tops +x
F_TOP_X = ((1, 0, 0), (0, 0, -1), (0, 1, 0))    # top face, reads left->right from front
F_REAR = ((-1, 0, 0), (0, 1, 0), (0, 0, -1))    # rear face as seen from behind

# tray / cavity (mm)
TRAY_OPEN = dict(x0=-3.0, x1=123.5, y0=51.8, y1=63.9)
CLR = 0.4                                        # tray / button clearance
TRAY_BACK = -65.0
CAVITY_BACK = TRAY_BACK - 0.5
DISC_C = (60.3, 18.0)                            # disc centre (x, z) with tray closed
WELL120_FLOOR = 56.0
DISC_FLOAT = 0.05                                # disc data face above the 120 mm well floor
PLATE_TOP = 57.5

# ports / slots
SLOT_XS = (LAY['slot_mc_1']['center_mm'][0], LAY['slot_mc_2']['center_mm'][0])
SLOT_Y = LAY['slot_mc_1']['center_mm'][1]        # 61.5
CARD = (42.0, 7.5, 56.5)
CARD_OUT = 15.0                                  # protrusion in front of the fins (est.)
CARD_Z = FRONT_Z - (CARD[2] - CARD_OUT)          # 49.5 connector end face
PORT_Y = LAY['port_ctrl_1']['center_mm'][1]      # 47.0
LIP = (40.0, 7.5, 9.0)
COLLAR = (41.0, 8.5, 2.0)
PLUG_BODY = (43.0, 13.0, 29.0)
PLUG_GAP = 0.3
PORT_Z = FRONT_Z - LIP[2] + PLUG_GAP             # 82.3 lip end face
PORT_W, PORT_H = 41.8, 9.3
PORT_FLOOR = PORT_Z - 0.5
# memory card slot doors (hinged at the top front of the card channel, swing inward)
DOOR_HINGE_Y, DOOR_HINGE_Z = SLOT_Y + CARD[1] / 2 + 0.4 - 0.2, 89.6   # 65.45, face plane
DOOR_H, DOOR_T, DOOR_W = 6.2, 1.0, 41.6
DOOR_OPEN = math.pi / 2


# ================================================================ helpers
def V(*a):
    return Vector(a[0] if len(a) == 1 else a)


def add_box(bm, lo, hi):
    res = bmesh.ops.create_cube(bm, size=1.0)
    vs = res['verts']
    bmesh.ops.scale(bm, vec=[(h - l) * MM for l, h in zip(lo, hi)], verts=vs)
    bmesh.ops.translate(bm, vec=[(h + l) / 2 * MM for l, h in zip(lo, hi)], verts=vs)
    return vs


def boxes(name, specs):
    """One mesh object made of axis-aligned boxes [(lo, hi), ...] in mm."""
    bm = bmesh.new()
    for lo, hi in specs:
        add_box(bm, lo, hi)
    return C._mesh_object(name, bm)


def rbox(name, lo, hi, r, seg=2):
    """Rounded box between lo/hi (mm) with the mesh baked in root space."""
    size = [(h - l) * MM for l, h in zip(lo, hi)]
    ob = C.rounded_box(name, size, r * MM, seg, [(h + l) / 2 * MM for l, h in zip(lo, hi)])
    bake(ob)
    return ob


def bake(ob):
    ob.data.transform(Matrix.LocRotScale(ob.location, ob.rotation_euler, ob.scale))
    ob.location, ob.rotation_euler, ob.scale = (0, 0, 0), (0, 0, 0), (1, 1, 1)
    return ob


def cyl(name, center, r, z0, z1, verts=32, axis='z'):
    """Cylinder (mm) along an axis between z0..z1 (coordinates along that axis)."""
    depth = (z1 - z0) * MM
    mid = (z0 + z1) / 2
    if axis == 'z':
        loc, rot = (center[0], center[1], mid), (0, 0, 0)
    else:  # 'y'
        loc, rot = (center[0], mid, center[1]), (math.pi / 2, 0, 0)
    ob = C.cylinder(name, r * MM, depth, verts, [c * MM for c in loc], rot)
    return bake(ob)


def cut(obj, cutter):
    C.boolean(obj, cutter, 'DIFFERENCE')
    return obj


def union(obj, other):
    C.boolean(obj, other, 'UNION')
    return obj


def join(name, objs):
    """Join mesh objects (materials kept) into a new object `name`."""
    objs = [o for o in objs if o is not None]
    for o in objs:
        bake(o)
    base = objs[0]
    with bpy.context.temp_override(active_object=base, selected_editable_objects=objs,
                                   selected_objects=objs, object=base):
        bpy.ops.object.join()
    base.name = name
    base.data.name = name
    return base


def frame_vectors(frame):
    ex, ey, ez = (Vector(v) for v in frame)
    assert abs(ex.cross(ey).dot(ez) - 1.0) < 1e-6, frame
    return ex, ey, ez


def poly_prism(name, polys, frame, origin, d0, d1):
    """Extrude 2D polygons [(u, v)] (mm, in `frame` about `origin`) from d0 to d1
    along the frame normal. Returns a closed mesh object (a cutter or a part)."""
    ex, ey, ez = frame_vectors(frame)
    o = Vector(origin)
    bm = bmesh.new()
    for poly in polys:
        lo = [bm.verts.new((o + ex * u + ey * v + ez * d0) * MM) for u, v in poly]
        hi = [bm.verts.new((o + ex * u + ey * v + ez * d1) * MM) for u, v in poly]
        n = len(poly)
        area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1]
                   for i in range(n))
        if area < 0:
            lo.reverse()
            hi.reverse()
        bm.faces.new(list(reversed(lo)))
        bm.faces.new(hi)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bm.normal_update()
    return C._mesh_object(name, bm)


def flat_polys(name, polys, frame, origin, lift=LIFT):
    """Flat single-sided print from polygons [(u, v)] facing the frame normal."""
    ex, ey, ez = frame_vectors(frame)
    o = Vector(origin)
    bm = bmesh.new()
    for poly in polys:
        n = len(poly)
        area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1]
                   for i in range(n))
        pts = poly if area > 0 else list(reversed(poly))
        f = bm.faces.new([bm.verts.new((o + ex * u + ey * v + ez * lift) * MM) for u, v in pts])
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method='BEAUTY', ngon_method='EAR_CLIP')
    for f in bm.faces:
        f.smooth = False
    return C._mesh_object(name, bm)


def rect(cx, cy, w, h):
    return [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2),
            (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)]


def circle(cx, cy, r, seg=16):
    return [(cx + r * math.cos(2 * math.pi * i / seg), cy + r * math.sin(2 * math.pi * i / seg))
            for i in range(seg)]


def stadium(cx, cy, w, h, seg=8):
    r = h / 2
    pts = []
    for i in range(seg + 1):
        a = -math.pi / 2 + math.pi * i / seg
        pts.append((cx + w / 2 - r + r * math.cos(a), cy + r * math.sin(a)))
    for i in range(seg + 1):
        a = math.pi / 2 + math.pi * i / seg
        pts.append((cx - w / 2 + r + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def clip(poly, keep):
    """Sutherland-Hodgman clip of a polygon by the half-plane keep(p) >= 0 (linear)."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        fa, fb = keep(a), keep(b)
        if fa >= 0:
            out.append(a)
        if (fa >= 0) != (fb >= 0):
            t = fa / (fa - fb)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def load_font(key):
    path = FONTS.get(key)
    if path and path.exists():
        try:
            return bpy.data.fonts.load(str(path), check_existing=True)
        except RuntimeError as exc:
            print(f'WARNING [console] font {path} could not be loaded ({exc}); '
                  f'using Blender built-in font (glyph shapes will differ)')
    else:
        print(f'WARNING [console] font file {path} (key {key!r}) missing; '
              f'using Blender built-in font (glyph shapes will differ)')
    return bpy.data.fonts.load('<builtin>', check_existing=True)


def text_polys_mesh(body, font_key, extrude=0.0, small_caps=False):
    cu = bpy.data.curves.new('_txt', 'FONT')
    cu.body = body
    cu.font = load_font(font_key)
    if small_caps:
        cu.small_caps_scale = 0.78
        for ch in cu.body_format:
            ch.use_small_caps = True
    cu.resolution_u = 2
    cu.extrude = extrude
    ob = bpy.data.objects.new('_txtobj', cu)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.curves.remove(cu)
    return me


def fit_mesh(name, me, frame, center, w=None, h=None, lift=LIFT, depth=None):
    """Map mesh data drawn in its own XY plane (x = reading, y = glyph up, z = normal)
    onto a face: bbox scaled to w x h mm (one may be None to keep the aspect), centred
    on `center` (mm, a point on the face) in `frame`. Flat meshes are lifted `lift` mm;
    with depth=(d0, d1) solid (extruded) meshes span d0..d1 mm along the normal."""
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    bx, by = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    W, H = max(xs) - min(xs), max(ys) - min(ys)
    sx = w / W if w else None
    sy = h / H if h else None
    sx, sy = sx or sy, sy or sx
    z0, zr = min(zs), (max(zs) - min(zs)) or 1.0
    ex, ey, ez = frame_vectors(frame)
    o = Vector(center)
    for v in me.vertices:
        x, y, z = v.co
        d = lift if depth is None else depth[0] + (z - z0) / zr * (depth[1] - depth[0])
        v.co = (o + ex * ((x - bx) * sx) + ey * ((y - by) * sy) + ez * d) * MM
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    for p in me.polygons:
        p.use_smooth = False
    return ob


def text(name, body, font_key, frame, center, w=None, h=None, lift=LIFT, depth=None, small_caps=False):
    """System-font text (only where no shared vector exists) fitted like fit_mesh."""
    me = text_polys_mesh(body, font_key, extrude=0.05 if depth else 0.0, small_caps=small_caps)
    return fit_mesh(name, me, frame, center, w, h, lift, depth)


VEC_DIR = C.REPO / 'tools/ps2_blender/vectors'


def svg_meshes(fname, resolution=4, extrude=0.0):
    """Import a shared vector (tools/ps2_blender/vectors) with bpy.ops.import_curve.svg
    and return {curve object name: filled mesh data} in the SVG's own XY (y up).
    The temporary curves, their collection and importer materials are removed."""
    before_obs, before_cols = set(bpy.data.objects), set(bpy.data.collections)
    before_mats = set(bpy.data.materials)
    bpy.ops.import_curve.svg(filepath=str(VEC_DIR / fname))
    new = [o for o in bpy.data.objects if o not in before_obs]
    for o in new:
        if o.type == 'CURVE':
            o.data.resolution_u = resolution
            o.data.extrude = extrude
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    out = {}
    for o in new:
        if o.type == 'CURVE':
            me = bpy.data.meshes.new_from_object(o.evaluated_get(dg), depsgraph=dg)
            me.transform(o.matrix_world)
            me.materials.clear()
            out[o.name] = me
    for o in new:
        data = o.data
        bpy.data.objects.remove(o, do_unlink=True)
        if data is not None and data.users == 0:
            bpy.data.curves.remove(data)
    for col in [c for c in bpy.data.collections if c not in before_cols]:
        bpy.data.collections.remove(col)
    for m in [m for m in bpy.data.materials if m not in before_mats and m.users == 0]:
        bpy.data.materials.remove(m)
    return out


def merge_meshes(meshes):
    bm = bmesh.new()
    for me in meshes:
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    out = bpy.data.meshes.new('_merged')
    bm.to_mesh(out)
    bm.free()
    return out


def svg_part(fname, include=None, exclude=(), resolution=4, extrude=0.0):
    """Merged mesh of the chosen curves of a shared vector file."""
    ms = svg_meshes(fname, resolution, extrude)
    keep = [me for name, me in ms.items()
            if (include is None or name.split('.')[0] in include) and name.split('.')[0] not in exclude]
    for name, me in ms.items():
        if me not in keep:
            bpy.data.meshes.remove(me)
    return merge_meshes(keep)


def band_split(ob, axis_vec, edges, first_slot=0):
    """Bisect a (world-space) print mesh at planes normal to axis_vec located at
    `edges` (metres along axis_vec) and give each face the material slot of its band."""
    axis = Vector(axis_vec).normalized()
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    for e in edges:
        geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=axis * e, plane_no=axis)
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method='BEAUTY', ngon_method='EAR_CLIP')
    for f in bm.faces:
        t = f.calc_center_median().dot(axis)
        f.material_index = first_slot + sum(1 for e in edges if t > e)
    bm.to_mesh(ob.data)
    bm.free()
    return ob


def reshade(ob, angle=50.0):
    """Smooth faces, sharp edges above `angle` (boolean results mix flags otherwise)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    C._smooth_by_angle(bm, angle)
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()
    return ob


def merge(name, objs, material=None):
    ob = join(name, objs)
    if material is not None:
        C.assign(ob, material)
    return ob


# ================================================================ materials
def materials():
    h = C.hex_rgba
    M = {
        'body': C.mat('PS2_Body', h(COL['body']), rough=0.55),
        'tray': C.mat('PS2_TrayFace', h(COL['tray_face']), rough=0.45),
        'tray_plate': C.mat('PS2_TrayPlate', h('#19191B'), rough=0.6),
        'button': C.mat('PS2_Button', h(COL['buttons']), rough=0.38),
        'dark': C.mat('PS2_Dark', h(COL['fan_grille_dark']), rough=0.85),
        'rubber': C.mat('PS2_Rubber', h('#141415'), rough=0.9),
        'blue': C.mat('PS2_USBPanel', h(COL['usb_panel_blue']), rough=0.45),
        'metal': C.mat('PS2_Metal', h('#B9B9BE'), rough=0.3, metal=1.0),
        'gold': C.mat('PS2_Gold', h('#C9A24A'), rough=0.3, metal=1.0),
        'cover': C.mat('PS2_BayCover', h('#212123'), rough=0.6),
        'teal': C.mat('PRINT_ResetTeal', h(COL['reset_icon_teal']), rough=0.4),
        'ejectblue': C.mat('PRINT_EjectBlue', h(COL['eject_icon_blue']), rough=0.4),
        'silver': C.mat('PRINT_SonySilver', h(COL['sony_front_silver']), rough=0.3, metal=0.6),
        'white': C.mat('PRINT_White', h(COL['print_white']), rough=0.5),
        'red': C.mat('PRINT_PS_Red', h(COL['ps_logo_red']), rough=0.3),
        'yellow': C.mat('PRINT_PS_Yellow', h(COL['ps_logo_yellow']), rough=0.3),
        'green': C.mat('PRINT_PS_Green', h(COL['ps_logo_green']), rough=0.3),
        'psblue': C.mat('PRINT_PS_Blue', h(COL['ps_logo_blue']), rough=0.3),
        'emboss': C.mat('PRINT_Emboss', h('#121213'), rough=0.45),
        'low': C.mat('PRINT_LowContrast', h('#3A3A3D'), rough=0.45),
        'panelprint': C.mat('PRINT_PanelIcons', h('#B4C2E0'), rough=0.5),
        'sticker': C.mat('PRINT_Sticker', h('#4C4C51'), rough=0.45, metal=0.2),
        'label': C.mat('PRINT_LabelWhite', h('#EDEDED'), rough=0.6),
        'black': C.mat('PRINT_Black', h('#0C0C0D'), rough=0.5),
        'seal': C.mat('PRINT_WarrantySeal', h('#2C2C2F'), rough=0.25),
        'led_power': C.mat('LED_POWER_off', h('#2B1C1C'), rough=0.15),
        'led_eject': C.mat('LED_EJECT_off', h('#1C1F2B'), rough=0.15),
    }
    a, b = C.hex_rgba(COL['logo_ps2_top_cyan']), C.hex_rgba(COL['logo_ps2_top_violet'])
    for i in range(4):  # gradient: feet (x low) cyan -> tops (x high) violet
        t = i / 3
        M[f'logo{i}'] = C.mat(f'PRINT_PS2Logo_{i}', tuple(a[k] + (b[k] - a[k]) * t for k in range(4)),
                              rough=0.35)
    return M


# ================================================================ body
def build_body():
    fl = FINS
    # ---- upper tier: core + 6 fins, lower tier, tier connector, flat rear x- panel.
    # Everything overhangs the left face / back by 3 mm and is trimmed once at the end,
    # so those faces are flat and no coplanar unions are needed.
    body = boxes('BODY', [((LEFT_X - 3, 38.5, REAR_Z - 3), (RIGHT_X - GROOVE, 77.0, FRONT_Z - GROOVE))])
    for i, (y0, y1) in enumerate(fl):
        union(body, rbox(f'_fin{i}', (LEFT_X - 3, y0, REAR_Z - 3), (RIGHT_X, y1, FRONT_Z), 1.0, 2))
    union(body, rbox('_lower', (LEFT_X - 3, 1.0, REAR_Z - 3), (122.5, 36.0, 70.0), 1.0, 2))
    union(body, boxes('_conn', [((LEFT_X + 2.5, 35.0, REAR_Z + 2.5), (120.0, 38.6, 67.5))]))
    union(body, boxes('_rearfill', [((LEFT_X + 2.5, 35.0, REAR_Z - 3), (-13.0, 38.6, REAR_Z + 6))]))
    cut(body, boxes('_trimL', [((LEFT_X - 5, -5, REAR_Z - 5), (LEFT_X, 85, FRONT_Z + 5))]))
    cut(body, boxes('_trimB', [((LEFT_X - 5, -5, REAR_Z - 5), (RIGHT_X + 5, 85, REAR_Z))]))

    # ---- tray bay: opening + cavity as long as the tray
    t = TRAY_OPEN
    cut(body, boxes('_traybay', [((t['x0'], t['y0'], CAVITY_BACK), (t['x1'], t['y1'], FRONT_Z + 2))]))
    # ---- button pockets
    for key in ('btn_reset', 'btn_eject'):
        (cx, cy, _), (w, h, _) = LAY[key]['center_mm'], LAY[key]['size_mm']
        cut(body, boxes('_pocket', [((cx - w / 2 - CLR, cy - h / 2 - CLR, 84.0),
                                     (cx + w / 2 + CLR, cy + h / 2 + CLR, FRONT_Z + 2))]))
    # ---- memory card slots: bezel recess + card channel
    specs = []
    for x in SLOT_XS:
        specs.append(((x - 23.0, 56.45, FRONT_Z - 1.2), (x + 23.0, 66.3, FRONT_Z + 2)))
    cut(body, boxes('_mcbezel', specs))
    specs = []
    for x in SLOT_XS:
        specs.append(((x - CARD[0] / 2 - 0.5, SLOT_Y - CARD[1] / 2 - 0.4, CARD_Z - 0.5),
                      (x + CARD[0] / 2 + 0.5, SLOT_Y + CARD[1] / 2 + 0.4, FRONT_Z - 0.5)))
    cut(body, boxes('_mcslot', specs))
    specs = []   # pockets the doors swing up into (door lies along the channel ceiling)
    for x in SLOT_XS:
        specs.append(((x - DOOR_W / 2 - 0.4, DOOR_HINGE_Y - 0.1, DOOR_HINGE_Z - DOOR_H - 0.4),
                      (x + DOOR_W / 2 + 0.4, DOOR_HINGE_Y + DOOR_T + 0.35, FRONT_Z - 0.5)))
    cut(body, boxes('_doorpocket', specs))
    # ---- controller ports: bezel + plug recess
    specs = []
    for x in SLOT_XS:
        specs.append(((x - 23.0, 41.9, FRONT_Z - 1.2), (x + 23.0, 51.85, FRONT_Z + 2)))
    cut(body, boxes('_ctrlbezel', specs))
    specs = []
    for x in SLOT_XS:
        specs.append(((x - PORT_W / 2, PORT_Y - PORT_H / 2, PORT_FLOOR),
                      (x + PORT_W / 2, PORT_Y + PORT_H / 2, FRONT_Z - 0.5)))
    cut(body, boxes('_ctrlport', specs))
    # ---- panel split lines on fins 3-5 (left edge of the slot/port panel run)
    cut(body, boxes('_split', [((-26.3, 44.0, FRONT_Z - 1.0), (-25.7, 64.5, FRONT_Z + 1))]))

    # ---- lower front: vent grille (8 rows x 13 slots), USB panel recess, USB / i.LINK
    g = LAY['vents_front']
    gx0, gx1 = g['center_mm'][0] - g['size_mm'][0] / 2, g['center_mm'][0] + g['size_mm'][0] / 2
    n, bar = 13, 1.6
    seg = (gx1 - gx0 - (n - 1) * bar) / n
    specs = []
    for row in range(8):
        y0 = 6.1 + row * 3.1
        for c in range(n):
            x0 = gx0 + c * (seg + bar)
            specs.append(((x0, y0, 64.5), (x0 + seg, y0 + 1.6, 72.0)))
    cut(body, boxes('_grille', specs))
    up = LAY['usb_panel']
    (ux, uy, _), (uw, uh, _) = up['center_mm'], up['size_mm']
    cut(body, boxes('_usbpanel', [((ux - uw / 2, uy - uh / 2, 69.0), (ux + uw / 2, uy + uh / 2, 72.0))]))
    cut(body, boxes('_usbholes', usb_hole_specs(58.0, 72.0)))

    # ---- rear: fan grille (3 x 7 openings) + fan chamber
    f = LAY['rear_vent_fan']
    (fx, fy, _), (fw, fh, _) = f['center_mm'], f['size_mm']
    cut(body, boxes('_fanchamber', [((fx - fw / 2 + 2.0, fy - fh / 2 + 2.0, REAR_Z + 6.5),
                                     (fx + fw / 2 - 2.0, fy + fh / 2 - 2.0, REAR_Z + 19.0))]))
    cut(body, boxes('_fanholes', fan_hole_specs(REAR_Z - 2, REAR_Z + 7.0)))
    # power switch + AC IN frames (2 mm), rocker hole, C8 inlet
    sw, ac = LAY['rear_power_switch'], LAY['rear_ac_in']
    sx, sy = sw['center_mm'][:2]
    ax, ay = ac['center_mm'][:2]
    cut(body, boxes('_pwrframes', [((sx - 13.25, sy - 7.65, REAR_Z - 2), (sx + 13.25, sy + 7.65, REAR_Z + 2.0)),
                                   ((ax - 13.25, ay - 7.35, REAR_Z - 2), (ax + 13.25, ay + 7.35, REAR_Z + 2.0))]))
    cut(body, boxes('_rockerhole', [((sx - 10.3, sy - 5.9, REAR_Z + 1), (sx + 10.3, sy + 5.9, REAR_Z + 8.0))]))
    cut(body, poly_prism('_c8', [stadium(0, 0, 14.6, 7.6)], F_REAR, (ax, ay, REAR_Z), -12.0, -1.0))
    # optical out: shallow square frame + port hole
    o = LAY['rear_optical_out']
    ox, oy = o['center_mm'][:2]
    cut(body, boxes('_optical', [((ox - 5.95, oy - 5.5, REAR_Z - 2), (ox + 5.95, oy + 5.5, REAR_Z + 0.8))]))
    cut(body, boxes('_opthole', [((ox - 3.5, oy - 3.0, REAR_Z), (ox + 3.5, oy + 3.0, REAR_Z + 5.0))]))
    # AV MULTI OUT
    av = LAY['rear_av_multi_out']
    vx, vy = av['center_mm'][:2]
    cut(body, boxes('_av', [((vx - 11.05, vy - 4.05, REAR_Z - 2), (vx + 11.05, vy + 4.05, REAR_Z + 8.0))]))
    # expansion bay opening (cover fitted)
    eb = LAY['rear_expansion_bay']
    (ex_, ey_, _), (ew, eh, _) = eb['center_mm'], eb['size_mm']
    cut(body, boxes('_bay', [((ex_ - ew / 2, ey_ - eh / 2, REAR_Z - 2), (ex_ + ew / 2, ey_ + eh / 2, REAR_Z + 5.0))]))
    # rear panel seams (fan panel borders, optical-AV parting line), screw + pin holes
    cut(body, boxes('_seams', [((-12.8, 2.0, REAR_Z - 1), (-12.3, 76.0, REAR_Z + 0.5)),
                               ((-86.8, 2.0, REAR_Z - 1), (-86.3, 76.0, REAR_Z + 0.5)),
                               ((vx + 11.05, 16.8, REAR_Z - 1), (ox - 5.95, 17.3, REAR_Z + 0.5))]))
    cut(body, cyl('_screw', (143.5, 57.5), 1.1, REAR_Z - 1, REAR_Z + 4.0, 16))
    cut(body, cyl('_rearhole', (-108.6, 25.0), 1.0, REAR_Z - 1, REAR_Z + 3.0, 16))
    return body


def usb_hole_specs(z0, z1):
    specs = []
    for key in ('usb_1', 'usb_2'):
        (x, y, _), (w, h, _) = LAY[key]['center_mm'], LAY[key]['size_mm']
        specs.append(((x - w / 2, y - h / 2, z0), (x + w / 2, y + h / 2, z1)))
    (x, y, _), (w, h, _) = LAY['ilink']['center_mm'], LAY['ilink']['size_mm']
    specs.append(((x - w / 2, y - h / 2, z0 + 3), (x + w / 2, y + h / 2, z1)))
    return specs


def fan_hole_specs(z0, z1):
    f = LAY['rear_vent_fan']
    (fx, fy, _), (fw, fh, _) = f['center_mm'], f['size_mm']
    bar = 3.0
    cw = (fw - 4 * bar) / 3
    rh = (fh - 8 * bar) / 7
    specs = []
    for c in range(3):
        for r in range(7):
            x0 = fx - fw / 2 + bar + c * (cw + bar)
            y0 = fy - fh / 2 + bar + r * (rh + bar)
            specs.append(((x0, y0, z0), (x0 + cw, y0 + rh, z1)))
    return specs


# ================================================================ static details
def build_details(M):
    parts = []

    def part(ob, m):
        C.assign(ob, M[m])
        parts.append(ob)
        return ob

    # blue USB / i.LINK panel (cut for the ports)
    up = LAY['usb_panel']
    (ux, uy, _), (uw, uh, _) = up['center_mm'], up['size_mm']
    panel = rbox('_panel', (ux - uw / 2 + 0.2, uy - uh / 2 + 0.2, 68.9), (ux + uw / 2 - 0.2, uy + uh / 2 - 0.2, 69.75), 0.3, 1)
    cut(panel, boxes('_ph', usb_hole_specs(60.0, 72.0)))
    part(panel, 'blue')
    # USB shells + tongues, i.LINK shell + insert
    for key in ('usb_1', 'usb_2'):
        (x, y, _), (w, h, _) = LAY[key]['center_mm'], LAY[key]['size_mm']
        shell = boxes('_usbshell', [((x - w / 2 + 0.1, y - h / 2 + 0.1, 59.0), (x + w / 2 - 0.1, y + h / 2 - 0.1, 69.7))])
        cut(shell, boxes('_usbin', [((x - w / 2 + 0.45, y - h / 2 + 0.45, 60.0), (x + w / 2 - 0.45, y + h / 2 - 0.45, 71.0))]))
        part(shell, 'metal')
        part(boxes('_tongue', [((x - 5.6, y + 0.15, 59.5), (x + 5.6, y + 2.0, 67.8))]), 'dark')
        part(boxes('_contacts', [((x - 4.5, y + 0.05, 62.0), (x + 4.5, y + 0.15, 67.5))]), 'gold')
    (x, y, _), (w, h, _) = LAY['ilink']['center_mm'], LAY['ilink']['size_mm']
    shell = boxes('_ilshell', [((x - w / 2 + 0.1, y - h / 2 + 0.1, 62.0), (x + w / 2 - 0.1, y + h / 2 - 0.1, 69.7))])
    cut(shell, boxes('_ilin', [((x - w / 2 + 0.45, y - h / 2 + 0.45, 63.0), (x + w / 2 - 0.45, y + h / 2 - 0.45, 71.0))]))
    part(shell, 'metal')
    part(boxes('_ilcore', [((x - 2.2, y - 0.9, 62.5), (x + 2.2, y + 0.5, 67.5))]), 'dark')

    # controller port pin blocks (fit inside the plug's 3 windows) with 3 holes each
    win_w = (LIP[0] - 4 * 1.6) / 3
    for sx in SLOT_XS:
        for i in range(3):
            cx = sx - LIP[0] / 2 + 1.6 + win_w / 2 + i * (win_w + 1.6)
            blk = rbox('_pins', (cx - 5.2, PORT_Y - 2.05, PORT_FLOOR - 0.3), (cx + 5.2, PORT_Y + 2.05, 88.8), 0.5, 1)
            for k in (-1, 0, 1):
                cut(blk, cyl('_pinhole', (cx + k * 3.0, PORT_Y), 0.55, 86.8, 90.0, 10))
            part(blk, 'body')
    # card slot back wall (dark connector face)
    for sx in SLOT_XS:
        part(boxes('_mcconn', [((sx - 21.5, SLOT_Y - 3.9, CARD_Z - 0.8), (sx + 21.5, SLOT_Y + 3.9, CARD_Z - 0.35))]), 'dark')
        part(boxes('_ctrlfloor', [((sx - 20.8, PORT_Y - 4.55, PORT_FLOOR - 0.3), (sx + 20.8, PORT_Y + 4.55, PORT_FLOOR + 0.15))]), 'dark')

    # rear fan (hub + 7 blades) behind the grille
    f = LAY['rear_vent_fan']
    fx, fy = f['center_mm'][:2]
    fz = REAR_Z + 12.0
    part(cyl('_hub', (fx, fy), 13.0, fz - 1.5, fz + 3.0, 32), 'dark')
    bm = bmesh.new()
    for i in range(7):
        vs = add_box(bm, (-3.5, 12.0, -1.0), (3.5, 27.5, 1.0))
        rot = Matrix.Rotation(2 * math.pi * i / 7, 3, 'Z') @ Matrix.Rotation(0.5, 3, 'Y')
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=vs)
    bmesh.ops.translate(bm, vec=(fx * MM, fy * MM, fz * MM), verts=bm.verts)
    part(C._mesh_object('_blades', bm), 'dark')
    part(boxes('_fanback', [((fx - 28, fy - 29, REAR_Z + 18.0), (fx + 28, fy + 29, REAR_Z + 19.5))]), 'dark')

    # power rocker (I / O printed below), AC inlet pins
    sw, ac = LAY['rear_power_switch'], LAY['rear_ac_in']
    sx, sy = sw['center_mm'][:2]
    ax, ay = ac['center_mm'][:2]
    part(rbox('_rocker', (sx - 9.9, sy - 5.5, REAR_Z + 0.9), (sx + 9.9, sy + 5.5, REAR_Z + 7.5), 0.6, 1), 'button')
    part(boxes('_c8floor', [((ax - 7.4, ay - 3.9, REAR_Z + 10.6), (ax + 7.4, ay + 3.9, REAR_Z + 11.2))]), 'dark')
    for k in (-1, 1):
        part(cyl('_acpin', (ax + k * 3.6, ay), 1.1, REAR_Z + 4.5, REAR_Z + 10.8, 12), 'metal')
    # optical shutter, AV MULTI OUT shell + tongue
    o = LAY['rear_optical_out']
    ox, oy = o['center_mm'][:2]
    part(boxes('_shutter', [((ox - 3.6, oy - 3.1, REAR_Z + 4.2), (ox + 3.6, oy + 3.1, REAR_Z + 4.8))]), 'dark')
    av = LAY['rear_av_multi_out']
    vx, vy = av['center_mm'][:2]
    sh = boxes('_avshell', [((vx - 10.95, vy - 3.95, REAR_Z + 0.3), (vx + 10.95, vy + 3.95, REAR_Z + 7.5))])
    cut(sh, boxes('_avin', [((vx - 9.6, vy - 2.6, REAR_Z - 1), (vx + 9.6, vy + 2.6, REAR_Z + 6.8))]))
    part(sh, 'button')                    # black plastic surround (photo)
    part(boxes('_avtongue', [((vx - 8.5, vy - 1.6, REAR_Z + 1.8), (vx + 8.5, vy + 0.6, REAR_Z + 7.0))]), 'dark')
    comb = [((vx - 8.0 + k * 0.8, vy + 0.6, REAR_Z + 2.2), (vx - 7.7 + k * 0.8, vy + 1.3, REAR_Z + 6.5)) for k in range(20)]
    part(boxes('_avpins', comb), 'metal')
    # expansion bay cover
    eb = LAY['rear_expansion_bay']
    (ex_, ey_, _), (ew, eh, _) = eb['center_mm'], eb['size_mm']
    cover = rbox('_cover', (ex_ - ew / 2 + 0.3, ey_ - eh / 2 + 0.3, REAR_Z + 0.2),
                 (ex_ + ew / 2 - 0.3, ey_ + eh / 2 - 0.3, REAR_Z + 4.8), 0.8, 2)
    cut(cover, boxes('_notch', [((ex_ - 8, ey_ + eh / 2 - 3.0, REAR_Z - 1), (ex_ + 8, ey_ + eh / 2, REAR_Z + 1.2))]))
    part(cover, 'cover')

    # feet and left-side pads (rubber)
    for i in range(1, 7):
        (x, _, z), (w, _, d) = LAY[f'foot_bottom_{i}']['center_mm'], LAY[f'foot_bottom_{i}']['size_mm']
        part(rbox('_foot', (x - w / 2, 0.0, z - d / 2), (x + w / 2, 1.4, z + d / 2), 0.4, 1), 'rubber')
    for i in range(1, 5):
        (_, y, z), (_, h, d) = LAY[f'pad_side_left_{i}']['center_mm'], LAY[f'pad_side_left_{i}']['size_mm']
        part(rbox('_pad', (-150.5, y - h / 2, z - d / 2), (LEFT_X + 0.3, y + h / 2, z + d / 2), 0.4, 1), 'rubber')
    return join('DETAILS', parts)


# ================================================================ tray
# Kept on the tray face (bottom edge of the lower bar .. just into the upper bar, as in
# ifixit_front_right_buttons_1600.jpg); the part file's 11.5 x 9.5 at y 54.5 would hang
# 2.5 mm below the tray and float when it ejects.
PS_LOGO_Y, PS_LOGO_H = 56.35, 8.2


def ps_logo(parent, M, center, height, lift):
    """Colour PS family logo from tools/ps2_blender/vectors/PlayStation_logo_commons.svg
    (the (R) islands are dropped - the console badge has none). Colours as on the tray
    badge photos: P red; S left lobe yellow (lower) / green (upper); S right lobe green
    (inner) / blue (outer)."""
    me = svg_part('PlayStation_logo_commons.svg', resolution=5)
    bm = bmesh.new()
    bm.from_mesh(me)
    tag = bm.faces.layers.int.new('island')
    islands, seen = [], set()
    for f0 in bm.faces:
        if f0 in seen:
            continue
        stack, comp = [f0], []
        seen.add(f0)
        while stack:
            f1 = stack.pop()
            comp.append(f1)
            for e in f1.edges:
                for f2 in e.link_faces:
                    if f2 not in seen:
                        seen.add(f2)
                        stack.append(f2)
        vs = {v for f in comp for v in f.verts}
        xs, ys = [v.co.x for v in vs], [v.co.y for v in vs]
        islands.append(dict(faces=comp, x0=min(xs), x1=max(xs), y0=min(ys), y1=max(ys)))
    H = max(i['y1'] - i['y0'] for i in islands)
    small = [i for i in islands if max(i['x1'] - i['x0'], i['y1'] - i['y0']) < 0.2 * H]
    bmesh.ops.delete(bm, geom=[f for i in small for f in i['faces']], context='FACES')
    islands = [i for i in islands if i not in small]
    P = max(islands, key=lambda i: i['y1'] - i['y0'])
    SL = min(islands, key=lambda i: i['x0'])
    for i in islands:
        k = 0 if i is P else (1 if i is SL else 2)
        for f in i['faces']:
            f[tag] = k
    X0, X1 = min(i['x0'] for i in islands), max(i['x1'] for i in islands)
    Y0 = min(i['y0'] for i in islands)
    ycut = Y0 + 0.31 * (P['y1'] - Y0)
    xcut = X0 + 0.75 * (X1 - X0)
    geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, ycut, 0), plane_no=(0, 1, 0))
    geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(xcut, 0, 0), plane_no=(1, 0, 0))
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method='BEAUTY', ngon_method='EAR_CLIP')
    for f in bm.faces:
        c = f.calc_center_median()
        k = f[tag]
        if k == 0:
            f.material_index = 0
        elif k == 1:
            f.material_index = 2 if c.y > ycut else 1
        else:
            f.material_index = 3 if c.x > xcut else 2
    bm.faces.layers.int.remove(tag)
    bm.to_mesh(me)
    bm.free()
    ob = fit_mesh('PRINT_PS_LOGO_TRAY', me, F_FRONT, center, h=height, lift=lift)
    for m in (M['red'], M['yellow'], M['green'], M['psblue']):
        ob.data.materials.append(m)
    C.set_parent(ob, parent)
    return ob


def build_tray(M, root):
    t = TRAY_OPEN
    x0, x1 = t['x0'] + CLR, t['x1'] - CLR
    y0, y1 = t['y0'] + CLR, t['y1'] - CLR
    fins3, fins4 = FINS[2], FINS[3]            # (59.3, 63.6), (52.0, 56.2)
    parts = []
    # face: two fin bars + recessed web (the groove between fins 3 and 4)
    upper = rbox('_tf_up', (x0, fins3[0], 83.5), (x1, y1, FRONT_Z), 0.9, 2)
    lower = rbox('_tf_lo', (x0, y0, 83.5), (x1, fins4[1], FRONT_Z), 0.9, 2)
    web = boxes('_tf_web', [((x0 + 0.5, fins4[1] - 0.8, 83.6), (x1 - 0.5, fins3[0] + 0.8, FRONT_Z - GROOVE))])
    boss = rbox('_tf_boss', (55.0, fins4[1] - 0.5, 84.0), (66.6, fins3[0] + 0.5, FRONT_Z - 0.1), 0.6, 1)
    for ob in (upper, lower, web, boss):
        C.assign(ob, M['tray'])
        parts.append(ob)
    # plate with disc wells, spindle hole and laser slot
    plate = boxes('_plate', [((x0, y0, TRAY_BACK), (x1, PLATE_TOP, 84.0))])
    dx, dz = DISC_C
    cut(plate, cyl('_w120', (dx, dz), 60.6, WELL120_FLOOR, PLATE_TOP + 1, 96, axis='y'))
    cut(plate, cyl('_w80', (dx, dz), 40.4, WELL120_FLOOR - 1.0, PLATE_TOP + 1, 72, axis='y'))
    cut(plate, cyl('_spindle', (dx, dz), 17.0, y0 - 1, PLATE_TOP + 1, 48, axis='y'))
    cut(plate, boxes('_laser', [((dx - 14.0, y0 - 1, dz - 57.0), (dx + 14.0, PLATE_TOP + 1, dz - 10.0))]))
    # finger grooves / ribs on the plate top in front of the well
    C.assign(plate, M['tray_plate'])
    reshade(plate)
    parts.append(plate)
    tray = join('DISC_TRAY', parts)
    C.set_parent(tray, root)
    # disc centre = mid-thickness: data face DISC_FLOAT above the well floor (not flush)
    anchor = C.empty('TRAY_DISC_ANCHOR', tray,
                     location=(dx * MM, (WELL120_FLOOR + DISC_FLOAT + 0.6) * MM, dz * MM))
    prints = C.empty('TRADEMARK_PRINTS_TRAY', tray)
    lg = LAY['logo_ps2_front']
    cx = lg['center_mm'][0]
    ps_logo(prints, M, (cx, PS_LOGO_Y, FRONT_Z), PS_LOGO_H, LIFT)
    return tray, anchor


# ================================================================ buttons + LEDs
def power_icon(cx, cy, r=1.55, wline=0.45, seg=20):
    """IEC power symbol: open ring (gap at top) + vertical bar."""
    outer, inner = r, r - wline
    gap = math.radians(50)
    a0, a1 = math.pi / 2 + gap, math.pi / 2 + 2 * math.pi - gap
    ring = [(cx + outer * math.cos(a0 + (a1 - a0) * i / seg), cy + outer * math.sin(a0 + (a1 - a0) * i / seg))
            for i in range(seg + 1)]
    ring += [(cx + inner * math.cos(a1 - (a1 - a0) * i / seg), cy + inner * math.sin(a1 - (a1 - a0) * i / seg))
             for i in range(seg + 1)]
    bar = rect(cx, cy + r * 0.45, wline, r * 1.1)
    return [ring, bar]


def build_button(M, root, key, name, led_name, led_key, led_mat):
    (cx, cy, _), (w, h, _) = LAY[key]['center_mm'], LAY[key]['size_mm']
    cap = rbox(name, (cx - w / 2, cy - h / 2, 85.5), (cx + w / 2, cy + h / 2, FRONT_Z), 0.8, 2)
    C.assign(cap, M['button'])
    icons = []
    if key == 'btn_reset':
        icons.append(C.assign(flat_polys('_pwr', power_icon(cx, cy + 1.6), F_FRONT, (0, 0, FRONT_Z)), M['teal']))
        icons.append(C.assign(text('_reset', 'RESET', 'bold', F_FRONT, (cx, cy - 2.4, FRONT_Z), w=6.6), M['teal']))
    else:
        tri = [(cx - 1.9, cy + 0.2), (cx + 1.9, cy + 0.2), (cx, cy + 2.1)]
        icons.append(C.assign(flat_polys('_ej', [tri, rect(cx, cy - 0.55, 3.8, 0.6)], F_FRONT, (0, 0, FRONT_Z)),
                              M['ejectblue']))
    btn = join(name, [cap] + icons)
    C.set_parent(btn, root)
    (lx, ly, _), (lw, _, _) = LAY[led_key]['center_mm'], LAY[led_key]['size_mm']
    led = cyl(led_name, (lx, ly), lw / 2, FRONT_Z - 0.4, FRONT_Z + 0.03, 16)
    C.assign(led, led_mat)
    C.set_parent(led, btn)
    return btn, led


def build_doors(M, root):
    """MC_DOOR_1/2: spring doors of the memory card slots, printed MEMORY CARD (as in
    ifixit_front_left_ports_1600.jpg). Node origin = hinge line (x centre, y 65.45,
    z 89.6); rest = closed (rot 0); rot_x +pi/2 swings the door inward/up into its
    pocket, which is how the card passes: the app must open MC_DOOR_n before a card
    is shown in SLOT_MC_n (closed door + inserted card intersect)."""
    doors = []
    for n, x in enumerate(SLOT_XS, 1):
        hinge = Vector((x, DOOR_HINGE_Y, DOOR_HINGE_Z))
        plate = rbox(f'MC_DOOR_{n}', (x - DOOR_W / 2, DOOR_HINGE_Y - DOOR_H, DOOR_HINGE_Z - DOOR_T),
                     (x + DOOR_W / 2, DOOR_HINGE_Y, DOOR_HINGE_Z), 0.4, 1)
        C.assign(plate, M['button'])
        label = text('_mclabel', 'MEMORY CARD', 'regular', F_FRONT,
                     (x + 1.0, DOOR_HINGE_Y - DOOR_H / 2 - 0.3, DOOR_HINGE_Z), w=23.0)
        C.assign(label, M['white'])
        door = join(f'MC_DOOR_{n}', [plate, label])
        door.data.transform(Matrix.Translation(-hinge * MM))
        door.location = hinge * MM
        C.set_parent(door, root, keep_world=False)
        doors.append(door)
    return doors


def set_doors(doors, angle):
    for d in doors:
        d.rotation_euler.x = angle
    bpy.context.view_layer.update()


# ================================================================ prints
def ps2_top_logo(M, parent):
    """Blue PS2 logo on the top: the P / S / 2 polygons of
    tools/ps2_blender/vectors/PlayStation2_logo_commons.svg (TM mark dropped - not on
    the console), fitted to the photo-measured bbox x 8.8..33.4, z -65.7..65.3 (reads
    rear->front, glyph tops +x), with the contract's 4-step gradient (feet cyan ->
    tops violet) split across the glyph height."""
    lay = LAY['logo_ps2_top']
    (lx, _, lz), (lw, _, ll) = lay['center_mm'], lay['size_mm']
    me = svg_part('PlayStation2_logo_commons.svg', include={'polygon5', 'polygon7', 'polygon9'})
    ob = fit_mesh('PRINT_PS2_LOGO_TOP', me, F_TOP_Z, (lx, 78.0, lz), w=ll, h=lw, lift=LIFT)
    x0 = (lx - lw / 2) * MM
    band_split(ob, (1, 0, 0), [x0 + lw * MM * k / 4 for k in (1, 2, 3)])
    for i in range(4):
        ob.data.materials.append(M[f'logo{i}'])
    C.set_parent(ob, parent)
    return ob


def ps2_wordmark(exclude_r=True):
    """"PlayStation(R)2" wordmark paths of PlayStation2_logo_commons.svg."""
    names = {f'path30{n:02d}' for n in range(3, 32, 2)}
    if exclude_r:
        names -= {'path3027', 'path3029'}
    return svg_part('PlayStation2_logo_commons.svg', include=names, resolution=4)


def build_prints(M, root):
    P = C.empty('TRADEMARK_PRINTS', root)
    made = []

    def add(ob, m):
        C.assign(ob, M[m])
        made.append(ob)
        return ob

    ps2_top_logo(M, P)
    # top: embossed "PlayStation 2" wordmark, media logo strip
    wm = LAY['logo_wordmark_top']
    (x, _, z), (w, _, l) = wm['center_mm'], wm['size_mm']
    add(fit_mesh('PRINT_WORDMARK_TOP', ps2_wordmark(), F_TOP_Z, (x, 78.0, z), w=l), 'emboss')
    ml = LAY['logos_media_top']
    (mx, _, mz), (mw, _, mh) = ml['center_mm'], ml['size_mm']
    items = ['disc', 'DOLBY', 'dts', 'DVD', 'DVD']
    widths = [14, 16, 12, 13, 13]
    cursor = mx - mw / 2
    for i, (s, wd) in enumerate(zip(items, widths)):
        cx = cursor + wd / 2
        add(text(f'PRINT_MEDIA_{i}', s, 'bold', F_TOP_X, (cx, 78.0, mz), w=wd - 3.0, h=mh * 0.55), 'low')
        cursor += wd + (mw - sum(widths)) / (len(items) - 1)
    # front: vertical raised SONY letters
    so = LAY['logo_wordmark_front']
    (sx, sy, _), (sw, sh, _) = so['center_mm'], so['size_mm']
    sony = svg_part('SONY.svg', resolution=4, extrude=0.0001)
    add(fit_mesh('PRINT_SONY', sony, F_SONY, (sx, sy, FRONT_Z), w=sh, depth=(-0.9, 0.08)), 'silver')
    # front: memory card labels (fin 2) and port triangles (fin 4)
    for key, s in (('label_mc_1', '1'), ('label_mc_2', '2')):
        (x, y, _), (w, h, _) = LAY[key]['center_mm'], LAY[key]['size_mm']
        add(text(f'PRINT_{key.upper()}', s, 'regular', F_FRONT, (x, y, FRONT_Z), h=h * 0.8), 'white')
    (x, y, _), (w, h, _) = LAY['label_magicgate']['center_mm'], LAY['label_magicgate']['size_mm']
    add(text('PRINT_MAGICGATE', 'MagicGate', 'bold', F_FRONT, (x, y, FRONT_Z), w=w, small_caps=True), 'white')
    tris = []
    for sx_ in SLOT_XS:
        tris.append([(sx_ - 3.0, 55.0), (sx_ - 2.2, 55.0), (sx_, 53.1), (sx_ + 2.2, 55.0), (sx_ + 3.0, 55.0), (sx_, 52.6)])
    add(flat_polys('PRINT_PORT_MARKS', tris, F_FRONT, (0, 0, FRONT_Z)), 'low')
    # blue panel icons: S400 + down triangle over i.LINK, USB trident, i.LINK "i"
    ix, iy = LAY['ilink']['center_mm'][:2]
    add(text('PRINT_S400', 'S400', 'regular', F_FRONT, (ix, iy + 5.6, 69.75), h=1.6), 'panelprint')
    add(flat_polys('PRINT_S400_TRI', [[(ix - 0.8, iy + 4.2), (ix + 0.8, iy + 4.2), (ix, iy + 3.2)]],
                   F_FRONT, (0, 0, 69.75)), 'panelprint')
    ux, uy = -119.3, 10.5
    usb = [rect(ux, uy, 0.45, 5.0), [(ux - 0.9, uy + 2.4), (ux + 0.9, uy + 2.4), (ux, uy + 3.6)],
           circle(ux, uy - 2.7, 0.7, 10),
           [(ux, uy - 0.2), (ux - 1.5, uy + 0.7), (ux - 1.5, uy + 1.3), (ux - 1.2, uy + 1.3), (ux - 1.2, uy + 0.9), (ux, uy + 0.2)],
           [(ux, uy - 1.2), (ux + 1.5, uy - 0.3), (ux + 1.5, uy + 0.3), (ux + 1.2, uy + 0.3), (ux + 1.2, uy - 0.1), (ux, uy - 0.8)],
           rect(ux - 1.35, uy + 1.55, 0.9, 0.9), circle(ux + 1.35, uy + 0.55, 0.5, 8)]
    add(flat_polys('PRINT_USB_ICON', usb, F_FRONT, (0, 0, 69.75)), 'panelprint')
    add(text('PRINT_ILINK_ICON', 'i', 'bold', F_FRONT, (ix, 11.0, 69.75), h=4.0), 'panelprint')
    # rear sticker (upper tier back), port labels, EXPANSION BAY
    rl = LAY['rear_label']
    (rx, ry, _), (rw, rh, _) = rl['center_mm'], rl['size_mm']
    add(flat_polys('PRINT_REAR_STICKER', [rect(0, 0, rw, rh)], F_REAR, (rx, ry, REAR_Z), LIFT), 'sticker')
    L2 = LIFT + 0.02
    # frame F_REAR: u = -x. Right edge of the sticker as seen from behind is x = rx - rw/2.
    def rtext(name, s, font, x, y, h, m='white', w=None):
        return add(text(name, s, font, F_REAR, (x, y, REAR_Z), w=w, h=h, lift=L2), m)
    left = rx + rw / 2 - 3.0          # viewer's left edge of the sticker (x+)
    add(fit_mesh('PRINT_ST_SONY', svg_part('SONY.svg'), F_REAR, (left - 9.5, ry + 9.5, REAR_Z), w=15.0, lift=L2), 'white')
    add(fit_mesh('PRINT_ST_PS2', ps2_wordmark(exclude_r=False), F_REAR, (left - 12.0, ry + 5.4, REAR_Z), w=20.0, lift=L2), 'white')
    rtext('PRINT_ST_SCE', 'Sony Computer Entertainment Inc.', 'regular', left - 17.0, ry + 2.3, 1.6, w=30.0)
    rtext('PRINT_ST_AC', 'AC120V  60Hz  79W', 'regular', left - 12.5, ry - 0.8, 1.7, w=21.0)
    rtext('PRINT_ST_MODEL', 'MODEL NO. SCPH-30001', 'regular', left - 38.0, ry + 9.5, 1.9, w=24.0)
    rtext('PRINT_ST_NTSC', 'NTSC   U/C', 'bold', left - 37.0, ry + 5.9, 1.7, w=13.0)
    rtext('PRINT_ST_SERIAL', 'SERIAL', 'bold', left - 7.0, ry - 4.2, 1.5, w=8.0)
    rtext('PRINT_ST_JAPAN', 'MADE IN JAPAN', 'regular', left - 37.0, ry - 0.8, 1.4, w=14.0)
    lines = [rect(-45.0, ry + 1.5 - k * 1.6, 62.0, 0.8) for k in range(8)]
    lines += [rect(-22.0, ry + 10.0 - k * 1.6, 20.0, 0.8) for k in range(4)]
    add(flat_polys('PRINT_ST_TEXTLINES', lines, F_REAR, (0, 0, REAR_Z), L2), 'low')
    add(flat_polys('PRINT_ST_BARCODE_BG', [rect(-55.0, ry + 6.8, 30.0, 7.5)], F_REAR, (0, 0, REAR_Z), L2), 'label')
    bars = [rect(-55.0 - 13.5 + k * 0.95, ry + 7.2, 0.25 + 0.3 * (k % 3 == 0), 5.2) for k in range(29)]
    add(flat_polys('PRINT_ST_BARCODE', bars, F_REAR, (0, 0, REAR_Z), L2 + 0.02), 'black')
    sw_, ac_ = LAY['rear_power_switch']['center_mm'], LAY['rear_ac_in']['center_mm']
    rtext('PRINT_MAIN_POWER', 'MAIN', 'regular', sw_[0] - 19.5, sw_[1] + 1.8, 1.8, 'low', w=6.5)
    rtext('PRINT_MAIN_POWER2', 'POWER', 'regular', sw_[0] - 19.5, sw_[1] - 1.2, 1.8, 'low', w=7.5)
    rtext('PRINT_AC_IN', 'AC IN', 'regular', ac_[0] - 19.5, ac_[1], 1.8, 'low', w=7.0)
    # rocker marks on the rocker face (z = REAR_Z + 0.9)
    add(text('PRINT_ROCKER_I', 'I', 'regular', F_REAR, (sw_[0] + 4.5, sw_[1], REAR_Z + 0.9), h=4.0, lift=LIFT), 'white')
    add(text('PRINT_ROCKER_O', 'O', 'regular', F_REAR, (sw_[0] - 4.5, sw_[1], REAR_Z + 0.9), h=4.0, lift=LIFT), 'white')
    op, av = LAY['rear_optical_out']['center_mm'], LAY['rear_av_multi_out']['center_mm']
    rtext('PRINT_DIGITAL_OUT', 'DIGITAL OUT', 'regular', op[0], op[1] + 10.5, 1.6, 'low', w=12.0)
    rtext('PRINT_OPTICAL', '(OPTICAL)', 'regular', op[0], op[1] + 8.0, 1.6, 'low', w=10.0)
    rtext('PRINT_AV_MULTI', 'AV MULTI OUT', 'regular', av[0] - 1.0, av[1] + 7.5, 1.7, 'low', w=16.0)
    # warranty seal (translucent sticker at the rear x- corner, back photo)
    add(flat_polys('PRINT_WARRANTY_SEAL', [rect(142.6, 27.5, 9.4, 47.0)], F_REAR, (0, 0, REAR_Z), LIFT), 'seal')
    seal_lines = [rect(-(-146.0 + k * 1.25), 25.0, 0.45, 38.0) for k in range(6)]
    add(flat_polys('PRINT_WARRANTY_TEXT', seal_lines, F_REAR, (0, 0, REAR_Z), L2), 'low')
    eb = LAY['rear_expansion_bay']['center_mm']
    add(text('PRINT_EXPANSION_BAY', 'EXPANSION BAY', 'regular', F_REAR, (eb[0], eb[1] - 1.5, REAR_Z + 0.2),
             w=46.0, h=3.4, lift=LIFT), 'low')
    for ob in made:
        C.set_parent(ob, P)
    return P


# ================================================================ checks
def world_tris(obj):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    mw = obj.matrix_world
    co = [mw @ v.co for v in me.vertices]
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    ev.to_mesh_clear()
    return co, tris


def bvh_of(obj):
    co, tris = world_tris(obj)
    return BVHTree.FromPolygons(co, tris, all_triangles=True), co


def point_inside(tree, p):
    for d in (Vector((0.2673, 0.5345, 0.8018)), Vector((-0.6247, 0.3123, -0.7158))):
        hits, o = 0, p
        while True:
            loc = tree.ray_cast(o, d)[0]
            if loc is None:
                break
            hits += 1
            o = loc + d * 1e-6
        if hits % 2 == 0:
            return False
    return True


def collide(a_obj, b_obj):
    ta, ca = bvh_of(a_obj)
    tb, cb = bvh_of(b_obj)
    if not ca or not cb:
        return None
    for k in range(3):
        if min(v[k] for v in ca) > max(v[k] for v in cb) or min(v[k] for v in cb) > max(v[k] for v in ca):
            return None
    pairs = ta.overlap(tb)
    if pairs:
        return f'{len(pairs)} tri pairs'
    if ca and point_inside(tb, ca[0]):
        return 'inside'
    if cb and point_inside(ta, cb[0]):
        return 'contains'
    return None


def plug_proxy(name, anchor):
    """DualShock 2 plug per its builder: lip 40x7.5x9 with 3 windows, collar
    41x8.5 (z 7..9), body 43x13 (z 9..38); origin = lip end face, insertion -Z."""
    lw, lh, ll = LIP
    lip = boxes(name + '_lip', [((-lw / 2, -lh / 2, 0.0), (lw / 2, lh / 2, ll))])
    win_w = (lw - 4 * 1.6) / 3
    wins = []
    for i in range(3):
        cx = -lw / 2 + 1.6 + win_w / 2 + i * (win_w + 1.6)
        wins.append(((cx - win_w / 2, -(lh - 2.6) / 2, -3.0), (cx + win_w / 2, (lh - 2.6) / 2, 7.0)))
    cut(lip, boxes('_win', wins))
    body = boxes(name + '_body', [((-COLLAR[0] / 2, -COLLAR[1] / 2, 7.0), (COLLAR[0] / 2, COLLAR[1] / 2, 9.0)),
                                  ((-PLUG_BODY[0] / 2, -PLUG_BODY[1] / 2, 9.0), (PLUG_BODY[0] / 2, PLUG_BODY[1] / 2, 38.0))])
    out = []
    for ob in (lip, body):
        ob.matrix_world = anchor.matrix_world.copy()
        out.append(ob)
    return out


def card_proxy(name, anchor):
    ob = boxes(name, [((-CARD[0] / 2, -CARD[1] / 2, 0.0), (CARD[0] / 2, CARD[1] / 2, CARD[2]))])
    ob.matrix_world = anchor.matrix_world.copy()
    return ob


def run_checks(root):
    bpy.context.view_layer.update()
    static = [o for o in C.descendants(root) if o.type == 'MESH'
              and not any(p.name in ('DISC_TRAY', 'BTN_RESET', 'BTN_EJECT') for p in [o, *iter_parents(o)])]
    # (MC_DOOR_n are included: the caller swings them open first)
    report = []
    proxies = []
    for n in (1, 2):
        a = bpy.data.objects[f'SLOT_MC_{n}']
        proxies.append((f'card proxy @SLOT_MC_{n}', [card_proxy(f'_card{n}', a)]))
        p = bpy.data.objects[f'PORT_CTRL_{n}']
        proxies.append((f'plug proxy @PORT_CTRL_{n}', plug_proxy(f'_plug{n}', p)))
    ok = True
    card_objs = append_memory_card(bpy.data.objects['SLOT_MC_1'])
    if card_objs:
        proxies.append(('real PS2-MemoryCard @SLOT_MC_1', [o for o in card_objs if o.type == 'MESH']))
    else:
        ok = False
        report.append(f'  real PS2-MemoryCard @SLOT_MC_1: MISSING {MEMORY_CARD_BLEND} '
                      f'(build PS2_Model/source/build_memory_card.py first)')
    bpy.context.view_layer.update()
    for label, objs in proxies:
        hits = []
        for po in objs:
            for so in static:
                r = collide(po, so)
                if r:
                    hits.append(f'{po.name} x {so.name}: {r}')
        ok &= not hits
        report.append(f'  {label}: ' + ('clear' if not hits else '; '.join(hits)))
    ok &= disc_in_tray_check(root, report)
    # protrusion / depth report
    print('[console] fit checks:')
    for line in report:
        print(line)
    print(f'[console] card inserted {CARD[2] - CARD_OUT:.1f} mm, protrudes {CARD_OUT:.1f} mm; '
          f'plug lip end at z {PORT_Z:.1f}, body face {FRONT_Z + PLUG_GAP:.1f}')
    print('[console] FIT ' + ('OK' if ok else 'FAIL'))
    for label, objs in proxies:
        if label.startswith('real'):
            continue
        for o in objs:
            bpy.data.objects.remove(o, do_unlink=True)
    return ok


def disc_in_tray_check(root, report):
    """Real PS2 DVD (built by PS2_Disc_Case/source/build_dvd.py, so the check does not
    depend on build order or a stale export) parented to TRAY_DISC_ANCHOR with identity
    local transform, against every console mesh with the tray closed and ejected.
    The disc is removed again afterwards (not part of the export / .blend)."""
    import importlib.util
    path = C.REPO / 'PS2_Disc_Case/source/build_dvd.py'
    tray = bpy.data.objects['DISC_TRAY']
    if not path.exists():
        report.append(f'  PS2-DVD @TRAY_DISC_ANCHOR: MISSING {path}')
        return False
    spec = importlib.util.spec_from_file_location('build_dvd', path)
    dvd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dvd)
    console_meshes = [o for o in C.descendants(root) if o.type == 'MESH']
    disc = dvd.build()
    C.set_parent(disc, bpy.data.objects['TRAY_DISC_ANCHOR'], keep_world=False)
    disc.location, disc.rotation_euler = (0, 0, 0), (0, 0, 0)
    disc_meshes = [o for o in C.descendants(disc) if o.type == 'MESH']
    ok = True
    for label, z in (('tray closed', 0.0), ('tray ejected', TRAVEL)):
        tray.location.z = z
        bpy.context.view_layer.update()
        hits = []
        for do in disc_meshes:
            for co in console_meshes:
                r = collide(do, co)
                if r:
                    hits.append(f'{do.name} x {co.name}: {r}')
        ok &= not hits
        report.append(f'  PS2-DVD @TRAY_DISC_ANCHOR, {label}: ' + ('clear' if not hits else '; '.join(hits)))
    tray.location.z = 0.0
    for o in reversed(C.descendants(disc)):   # children first, then the root
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.context.view_layer.update()
    return ok


def iter_parents(o):
    p = o.parent
    while p is not None:
        yield p
        p = p.parent


_CARD = []
MEMORY_CARD_BLEND = C.REPO / 'PS2_Model/PS2-MemoryCard.blend'


def append_memory_card(anchor):
    if _CARD:
        return _CARD
    path = MEMORY_CARD_BLEND
    if not path.exists():
        print(f'[console] ERROR: {path} not found; build PS2_Model/source/build_memory_card.py first')
        return []
    with bpy.data.libraries.load(str(path)) as (src, dst):
        dst.objects = list(src.objects)
    objs = [o for o in dst.objects if o is not None]
    for o in objs:
        bpy.context.scene.collection.objects.link(o)
    roots = [o for o in objs if o.parent is None and o.name.startswith('PS2_MEMORY_CARD')]
    if not roots:
        return objs
    roots[0].matrix_world = anchor.matrix_world.copy()
    bpy.context.view_layer.update()
    _CARD.extend(objs)
    return objs


# ================================================================ render
def look_at(obj, eye, target, up=(0, 1, 0)):
    eye, target, up = Vector(eye), Vector(target), Vector(up)
    z = (eye - target).normalized()
    x = up.cross(z).normalized()
    y = z.cross(x)
    obj.matrix_world = Matrix(((x.x, y.x, z.x, eye.x), (x.y, y.y, z.y, eye.y),
                               (x.z, y.z, z.z, eye.z), (0, 0, 0, 1)))


def render_views(root, tray, doors, out_dir, closeup_dir=None):
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.samples = 32
    scn.cycles.use_denoising = True
    scn.render.resolution_x, scn.render.resolution_y = 1200, 800
    scn.view_settings.view_transform = 'Standard'
    world = bpy.data.worlds.new('W')
    world.use_nodes = True
    bg = world.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (1, 1, 1, 1)
    bg.inputs['Strength'].default_value = 0.35
    scn.world = world
    bpy.ops.mesh.primitive_plane_add(size=3.0)
    floor = bpy.context.active_object
    floor.rotation_euler = (math.radians(-90), 0, 0)
    floor.location = (0, -0.0001, 0)
    C.assign(floor, C.mat('Floor', (0.9, 0.9, 0.9, 1), rough=0.9))

    def area(name, energy, size, eye, target=(0, 0.04, 0)):
        L = bpy.data.lights.new(name, 'AREA')
        L.energy, L.size = energy, size
        ob = bpy.data.objects.new(name, L)
        scn.collection.objects.link(ob)
        look_at(ob, eye, target)
    area('Key', 9, 0.6, (-0.5, 0.8, 0.6))
    area('Fill', 4, 0.8, (0.7, 0.5, 0.4))
    area('Rim', 5, 0.8, (0.2, 0.6, -0.8))
    cam_data = bpy.data.cameras.new('Cam')
    cam = bpy.data.objects.new('Cam', cam_data)
    scn.collection.objects.link(cam)
    scn.camera = cam
    cam_data.clip_start = 0.01
    views = [
        ('front34', 50, (-0.36, 0.40, 0.52), (0.0, 0.03, 0.0), {}),
        ('rear', 50, (0.24, 0.30, -0.62), (0.0, 0.035, 0.0), {}),
        ('tray_open', 45, (-0.30, 0.36, 0.62), (0.0, 0.03, 0.05), {'tray': True}),
    ]
    if closeup_dir:
        views = [
            ('cu_right', 60, (0.24, 0.10, 0.30), (0.12, 0.055, 0.09), {}),
            ('cu_left', 60, (-0.16, 0.10, 0.30), (-0.09, 0.04, 0.08), {}),
            ('cu_tray', 50, (0.10, 0.28, 0.40), (0.06, 0.05, 0.14), {'tray': True}),
            ('cu_rear', 50, (-0.10, 0.12, -0.35), (-0.08, 0.04, -0.09), {}),
        ]
        out_dir = Path(closeup_dir)
    card = []
    for name, lens, eye, target, opt in views:
        cam_data.lens = lens
        look_at(cam, eye, target)
        tray.location.z = TRAVEL if opt.get('tray') else 0.0
        doors[0].rotation_euler.x = DOOR_OPEN if opt.get('tray') else 0.0
        if opt.get('tray') and not card:
            card = append_memory_card(bpy.data.objects['SLOT_MC_1'])
        for o in _CARD:   # the card only appears in the tray-open views
            o.hide_render = not opt.get('tray')
        scn.render.filepath = str(out_dir / f'console_{name}.png')
        bpy.ops.render.render(write_still=True)
    tray.location.z = 0.0
    set_doors(doors, 0.0)


# ================================================================ main
def main():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    C.reset_scene()
    M = materials()
    root = C.empty(SPEC['root'])
    body = reshade(build_body())
    C.assign(body, M['body'])
    C.set_parent(body, root)
    details = reshade(build_details(M))
    C.set_parent(details, root)
    tray, _ = build_tray(M, root)
    build_button(M, root, 'btn_reset', 'BTN_RESET', 'LED_POWER', 'led_power', M['led_power'])
    build_button(M, root, 'btn_eject', 'BTN_EJECT', 'LED_EJECT', 'led_eject', M['led_eject'])
    for n, x in enumerate(SLOT_XS, 1):
        C.empty(f'PORT_CTRL_{n}', root, location=(x * MM, PORT_Y * MM, PORT_Z * MM))
        C.empty(f'SLOT_MC_{n}', root, location=(x * MM, SLOT_Y * MM, CARD_Z * MM))
    doors = build_doors(M, root)
    build_prints(M, root)

    for ob in C.descendants(root):
        C.apply_all(ob)
    tris = C.triangle_count(C.descendants(root))
    print(f'[console] triangles: {tris}')
    for ob in C.descendants(root):
        if ob.type == 'MESH' and C.triangle_count(ob) > 1500:
            print(f'  {ob.name}: {C.triangle_count(ob)}')
    C.export_usdz(root, C.REPO / SPEC['file'])
    C.save_blend(C.REPO / 'PS2_Model/PS2-Console.blend')
    ok = True
    if '--check' in argv:
        set_doors(doors, DOOR_OPEN)          # a card needs its door swung open
        ok = run_checks(root)
        set_doors(doors, 0.0)
    if '--render' in argv:
        render_views(root, tray, doors, C.REPO / 'PS2_Model/renders')
    if '--closeups' in argv:
        render_views(root, tray, doors, None, argv[argv.index('--closeups') + 1])
    if not ok:
        sys.exit(1)


if __name__ == '__main__':
    main()
