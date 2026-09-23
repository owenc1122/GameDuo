"""Build the PS2 8 MB Memory Card (SCPH-10020, black) runtime model.

Run from the repo root (headless):

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        --python-exit-code 1 --python PS2_Model/source/build_memory_card.py [-- --render]

Outputs PS2_Model/exports/PS2-MemoryCard.usdz and PS2_Model/PS2-MemoryCard.blend;
with --render also PS2_Model/renders/memory_card_{top,34_rear,34_connector}.png.

Frame (contract_parts/PS2-MemoryCard.json): card flat, label side up (+Y),
connector end toward -Z. Root PS2_MEMORY_CARD = centre of the connector end face,
so the card spans X -21..21, Y -3.75..3.75, Z 0..56.5 (the embossed SONY adds
0.2 mm above the label face, the flat prints 0.05 mm).

Hierarchy:
    PS2_MEMORY_CARD (empty, origin)
      SHELL            black body: outline with 2 mm chamfers at the connector end,
                       R2.5 rear corners, side grip waves, edge chamfers, a parting
                       groove, the recessed triangle, 2 holes, label recess, groove
                       line and the 3-bay connector window (2 asymmetric ribs)
      CONNECTOR_PINS   8 gold contact pads on the floor of the connector bays
      TRADEMARK_PRINTS (empty)
        PRINT_PS_LOGO, PRINT_PLAYSTATION2, PRINT_8MB, PRINT_MEMORY_CARD,
        PRINT_MAGICGATE  flat single-sided print meshes 0.05 mm above the face
        EMBOSS_SONY      raised 0.2 mm body-colour SONY (a trademark, so it lives
                         here too; hiding TRADEMARK_PRINTS leaves a plain face)

Fonts: system fonts are used when present (macOS): Arial Bold for
"PlayStation 2" / "MagicGate" (small caps), Arial for "8MB" / "MEMORY CARD",
SuperClarendon for SONY (Sony's logotype is Clarendon-like). Each falls back to
Blender's built-in font. Every text mesh is scaled to the photo-measured bbox in
the contract, so the font only affects glyph shapes, not placement or size.
The PS logo is a hand-traced polygon from memcard_top_forenti.jpg.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/ps2_blender"))
import common as C  # noqa: E402

MM = 0.001
SPEC = C.load_contract('PS2-MemoryCard')
LAY = SPEC['layout']
COL = SPEC['colors']
SX, SY, SZ = SPEC['size_mm']
HX, HY = SX / 2, SY / 2          # 21, 3.75
TOP = HY                          # label face (mm)
PRINT_LIFT = 0.05                 # mm above the face for flat prints

FONT_DIR = Path('/System/Library/Fonts/Supplemental')
FONTS = {
    'bold': FONT_DIR / 'Arial Bold.ttf',
    'regular': FONT_DIR / 'Arial.ttf',
    'serif': FONT_DIR / 'SuperClarendon.ttc',
}


# ---------------------------------------------------------------- materials
def materials():
    return {
        'body': C.mat('MC_Body', C.hex_rgba(COL['body']), rough=0.62),
        'label': C.mat('MC_LabelRecess', C.hex_rgba(COL['label_recess']), rough=0.5),
        'blue': C.mat('MC_PrintBlue', C.hex_rgba(COL['print_blue']), rough=0.45),
        'gray': C.mat('MC_PrintGray', C.hex_rgba(COL['print_gray']), rough=0.5),
        'pins': C.mat('MC_ContactGold', C.hex_rgba(COL['connector_pins']), rough=0.3, metal=1.0),
    }


# ---------------------------------------------------------------- outline
def outline_xz():
    """Closed top-view outline (mm) as [(x, z)], connector end at z = 0. Winding
    is irrelevant (normals are recalculated)."""
    ch = LAY['connector_end_chamfer_mm']
    r = LAY['rear_end_corner_radius_mm']
    z0, z1 = LAY['grip_ridges']['z_span_mm']
    n_waves = LAY['grip_ridges']['count']
    amp = LAY['grip_ridges']['amplitude_mm']
    steps = 4  # samples per wave

    def side(sign):
        """Points along the x = sign*21 side from z = ch to z = SZ - r."""
        pts = [(sign * HX, ch), (sign * HX, z0)]
        for i in range(1, n_waves * steps):
            t = i / (n_waves * steps)
            inset = amp * 0.5 * (1 - math.cos(2 * math.pi * n_waves * t))
            pts.append((sign * (HX - inset), z0 + (z1 - z0) * t))
        pts.append((sign * HX, z1))
        return pts

    def corner(cx, cz, a0, a1, seg=4):
        return [(cx + r * math.cos(a), cz + r * math.sin(a))
                for a in (a0 + (a1 - a0) * i / seg for i in range(seg + 1))]

    pts = [(-HX + ch, 0.0), (HX - ch, 0.0)]
    pts += side(+1)
    pts += corner(HX - r, SZ - r, 0.0, math.pi / 2)
    pts += corner(-HX + r, SZ - r, math.pi / 2, math.pi)
    pts += list(reversed(side(-1)))
    return pts


def offset_polygon(pts, d):
    """Miter-offset a closed polygon inward by d (mm)."""
    n = len(pts)
    # signed area -> orientation
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1]
               for i in range(n)) / 2
    sgn = 1.0 if area > 0 else -1.0
    out = []
    for i in range(n):
        p0, p1, p2 = Vector(pts[i - 1]), Vector(pts[i]), Vector(pts[(i + 1) % n])
        e0, e1 = (p1 - p0).normalized(), (p2 - p1).normalized()
        # inward normal for CCW polygon is (-y, x)
        n0 = Vector((-e0.y, e0.x)) * sgn
        n1 = Vector((-e1.y, e1.x)) * sgn
        bis = (n0 + n1).normalized()
        k = d / max(bis.dot(n0), 0.2)
        q = p1 + bis * k
        out.append((q.x, q.y))
    return out


def shell_mesh(name):
    """Lofted body: rings of the outline at several heights (inset d) to give
    the top/bottom edge chamfers and a shallow parting groove on the sides."""
    base = outline_xz()
    groove_y0, groove_y1, groove_d = -1.05, -0.8, 0.15
    rings = [(-HY, 0.3), (-HY + 0.3, 0.0),
             (groove_y0, 0.0), (groove_y0, groove_d), (groove_y1, groove_d), (groove_y1, 0.0),
             (HY - 0.3, 0.0), (HY, 0.3)]
    bm = bmesh.new()
    loops = []
    for y, d in rings:
        poly = offset_polygon(base, d) if d else base
        loops.append([bm.verts.new((x * MM, y * MM, z * MM)) for x, z in poly])
    n = len(base)
    for a, b in zip(loops, loops[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(loops[0])
    bm.faces.new(list(reversed(loops[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    C._smooth_by_angle(bm, 35.0)
    return C._mesh_object(name, bm)


def prism(name, poly_xz, y0, y1):
    """Vertical prism (mm) from a top-view polygon, flat shaded."""
    bm = bmesh.new()
    bot = [bm.verts.new((x * MM, y0 * MM, z * MM)) for x, z in poly_xz]
    top = [bm.verts.new((x * MM, y1 * MM, z * MM)) for x, z in poly_xz]
    n = len(poly_xz)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bot[i], bot[j], top[j], top[i]))
    bm.faces.new(bot)
    bm.faces.new(list(reversed(top)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return C._mesh_object(name, bm)


def box_mm(name, x0, x1, y0, y1, z0, z1):
    return prism(name, [(x0, z0), (x1, z0), (x1, z1), (x0, z1)], y0, y1)


def rounded_rect(cx, cz, w, h, r, seg=3):
    pts = []
    for (sx, sz, a0) in ((1, 1, 0), (-1, 1, 90), (-1, -1, 180), (1, -1, 270)):
        ccx, ccz = cx + sx * (w / 2 - r), cz + sz * (h / 2 - r)
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((ccx + r * math.cos(a), ccz + r * math.sin(a)))
    return pts


def circle(cx, cz, r, seg=10):
    return [(cx + r * math.cos(2 * math.pi * i / seg), cz + r * math.sin(2 * math.pi * i / seg))
            for i in range(seg)]


def build_shell(M):
    shell = shell_mesh('SHELL')
    C.assign(shell, M['body'])
    shell.data.materials.append(M['label'])

    # connector window: three bays between the two asymmetric ribs
    win = LAY['connector_window']
    ww, wh = win['size_mm']
    depth = win['depth_mm']
    rib_w = win['rib_width_mm']
    ribs = sorted(win['rib_x_mm'])
    edges = [-ww / 2]
    for rx in ribs:
        edges += [rx - rib_w / 2, rx + rib_w / 2]
    edges.append(ww / 2)
    bays = list(zip(edges[0::2], edges[1::2]))
    cy = win['center_mm'][1]
    for i, (x0, x1) in enumerate(bays):
        C.boolean(shell, box_mm(f'cut_bay{i}', x0, x1, cy - wh / 2, cy + wh / 2, -1.0, depth))

    # recessed triangle (points to -Z)
    tri = LAY['triangle_mark']
    tcx, _, tcz = tri['center_mm']
    tw, th = tri['size_mm']
    C.boolean(shell, prism('cut_triangle', [(tcx, tcz - th / 2), (tcx + tw / 2, tcz + th / 2),
                                            (tcx - tw / 2, tcz + th / 2)], TOP - 0.35, TOP + 1))
    # two small holes
    hr = LAY['holes']['diameter_mm'] / 2
    for i, (hx, _, hz) in enumerate(LAY['holes']['centers_mm']):
        C.boolean(shell, prism(f'cut_hole{i}', circle(hx, hz, hr), TOP - 1.2, TOP + 1))
    # label recess
    lab = LAY['label_recess']
    lcx, _, lcz = lab['center_mm']
    lw, lh = lab['size_mm']
    ld = lab['depth_mm']
    C.boolean(shell, prism('cut_label', rounded_rect(lcx, lcz, lw, lh, 0.8), TOP - ld, TOP + 1))
    # groove line along the bottom edge of the label recess
    g = LAY['groove_line']
    gx0, gx1 = g['x_span_mm']
    gw = g['width_mm']
    C.boolean(shell, box_mm('cut_groove', gx0, gx1, TOP - ld - 0.15, TOP + 1,
                            g['z_mm'] - gw / 2, g['z_mm'] + gw / 2))

    # label recess floor gets its own (slightly smoother) material
    bm = bmesh.new()
    bm.from_mesh(shell.data)
    floor_y = (TOP - ld) * MM
    for f in bm.faces:
        c = f.calc_center_median()
        if (f.normal.y > 0.99 and abs(c.y - floor_y) < 1e-5
                and abs(c.x / MM - lcx) < lw / 2 and abs(c.z / MM - lcz) < lh / 2):
            f.material_index = 1
    bm.to_mesh(shell.data)
    bm.free()
    return shell, bays


def build_pins(M, bays):
    """Gold contact pads on the floor of the bays: 3 / 3 / 2 at the contract
    pitch, centred in each bay (the contract's 8 pins at 2.4 mm pitch)."""
    win = LAY['connector_window']
    pitch = win['pin_pitch_mm']
    floor = win['center_mm'][1] - win['size_mm'][1] / 2
    counts = [3, 3, 2] if win['pin_count'] == 8 else None
    bm = bmesh.new()
    pad_w, z0, z1 = 1.1, 0.8, win["depth_mm"] - 0.3
    for (x0, x1), n in zip(bays, counts):
        mid = (x0 + x1) / 2
        for k in range(n):
            x = mid + (k - (n - 1) / 2) * pitch
            geom = bmesh.ops.create_cube(bm, size=1.0)
            vs = geom['verts']
            bmesh.ops.scale(bm, vec=(pad_w * MM, 0.12 * MM, (z1 - z0) * MM), verts=vs)
            bmesh.ops.translate(bm, vec=(x * MM, (floor + 0.06) * MM, (z0 + z1) / 2 * MM), verts=vs)
    pins = C._mesh_object('CONNECTOR_PINS', bm)
    return C.assign(pins, M['pins'])


# ---------------------------------------------------------------- prints
def load_font(key):
    path = FONTS.get(key)
    if path and path.exists():
        try:
            return bpy.data.fonts.load(str(path), check_existing=True)
        except RuntimeError:
            pass
    return bpy.data.fonts.load('<builtin>', check_existing=True)


def text_mesh(name, body, font_key, extrude_mm=0.0, small_caps=False, resolution=2):
    """Text as mesh data in its own XY plane (unscaled font units)."""
    cu = bpy.data.curves.new(name + '_txt', 'FONT')
    cu.body = body
    cu.font = load_font(font_key)
    cu.resolution_u = resolution
    cu.extrude = extrude_mm / 2  # relative; rescaled below
    if small_caps:
        cu.small_caps_scale = 0.78
        for ch in cu.body_format:
            ch.use_small_caps = True
    ob = bpy.data.objects.new(name + '_txtobj', cu)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.curves.remove(cu)
    return me


def fit_to_face(me, cx, cz, w, h, y_bottom, thickness=None):
    """Map text-plane coords (x right, y up, z normal) onto the label face so it
    reads with the connector end at the top: x -> +X, y -> -Z, z -> +Y. Scales the
    glyph bbox to exactly w x h mm centred on (cx, cz); z is set to y_bottom
    (flat) or stretched to `thickness` mm above y_bottom."""
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    bx, by = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    sx, sy = w / (max(xs) - min(xs)), h / (max(ys) - min(ys))
    z0, zr = min(zs), (max(zs) - min(zs)) or 1.0
    for v in me.vertices:
        x, y, z = v.co
        X = cx + (x - bx) * sx
        Z = cz - (y - by) * sy
        Y = y_bottom + (0.0 if thickness is None else (z - z0) / zr * thickness)
        v.co = (X * MM, Y * MM, Z * MM)
    me.update()
    return me


def merge_meshes(name, meshes):
    bm = bmesh.new()
    for me in meshes:
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    for f in bm.faces:
        f.smooth = False
    return C._mesh_object(name, bm)


def flat_polygons(name, polys_mm):
    """One flat, upward-facing mesh at the print height from several overlapping
    [(x, z)] polygons: they are extruded to prisms, boolean-unioned (so no
    coplanar overlaps remain) and only the top faces are kept."""
    y = TOP + PRINT_LIFT
    parts = [prism(f'{name}_{i}', poly, y - 0.1, y) for i, poly in enumerate(polys_mm)]
    ob = parts[0]
    ob.name = name
    ob.data.name = name
    for other in parts[1:]:
        C.boolean(ob, other, op='UNION')
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.y < 0.99], context='FACES')
    bmesh.ops.dissolve_limit(bm, angle_limit=0.01, verts=bm.verts, edges=bm.edges)
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method='BEAUTY', ngon_method='EAR_CLIP')
    for f in bm.faces:
        f.smooth = False
    bm.to_mesh(ob.data)
    bm.free()
    return ob


# PlayStation logo traced on memcard_top_forenti.jpg (pixel coordinates; the
# logo's blue bbox there is x 202..370, y 233..359). The upright P and the
# flat "S" drawn as two C-shaped halves either side of the P stem.
PS_P = [(261, 359), (261, 232), (275, 232), (292, 234), (306, 238), (318, 244), (328, 253),
        (334, 264), (336, 277), (335, 290), (330, 300), (321, 306), (310, 307), (303, 304),
        (301, 298), (301, 262), (299, 255), (294, 253), (292, 253), (292, 359)]
PS_S_LEFT = [(270, 305), (262, 305), (246, 311), (228, 319), (212, 328), (203, 337),
             (203, 345), (210, 352), (224, 357), (243, 359), (270, 359), (270, 335),
             (262, 335), (246, 337), (232, 339), (225, 338), (226, 335), (240, 331),
             (262, 326), (270, 326)]
PS_S_RIGHT = [(284, 316), (292, 316), (305, 313), (322, 311), (342, 311), (359, 314),
              (369, 320), (370, 328), (364, 335), (350, 340), (330, 344), (310, 347),
              (292, 349), (284, 349), (284, 341), (292, 341), (315, 335), (338, 329),
              (352, 325), (350, 321), (334, 324), (312, 330), (292, 335), (284, 335)]
PS_BBOX_PX = (202, 370, 233, 359)


def ps_logo_polys():
    lay = LAY['print_ps_logo']
    cx, _, cz = lay['center_mm']
    w, h = lay['size_mm']
    x0, x1, y0, y1 = PS_BBOX_PX
    def tf(p):
        return (cx + ((p[0] - (x0 + x1) / 2) / (x1 - x0)) * w,
                cz + ((p[1] - (y0 + y1) / 2) / (y1 - y0)) * h)
    return [[tf(p) for p in poly] for poly in (PS_P, PS_S_LEFT, PS_S_RIGHT)]


def build_prints(M, parent):
    y = TOP + PRINT_LIFT
    made = []

    ps = flat_polygons('PRINT_PS_LOGO', ps_logo_polys())
    made.append(C.assign(ps, M['blue']))

    def flat_text(name, key, body, font, mat, small_caps=False):
        lay = LAY[key]
        cx, _, cz = lay['center_mm']
        w, h = lay['size_mm']
        me = fit_to_face(text_mesh(name, body, font, small_caps=small_caps), cx, cz, w, h, y)
        ob = merge_meshes(name, [me])
        made.append(C.assign(ob, mat))

    flat_text('PRINT_PLAYSTATION2', 'print_playstation2', 'PlayStation 2', 'bold', M['blue'])
    flat_text('PRINT_MEMORY_CARD', 'print_memory_card', 'MEMORY CARD', 'regular', M['gray'])
    flat_text('PRINT_MAGICGATE', 'print_magicgate', 'MagicGate', 'bold', M['gray'], small_caps=True)

    # "8MB": big 8 + small MB sharing the baseline; split measured on the photo
    # (8 = 44 % of the width, 9.5 % gap; MB cap height 38 % of the 8).
    lay = LAY['print_8mb']
    cx, _, cz = lay['center_mm']
    w, h = lay['size_mm']
    left, top = cx - w / 2, cz - h / 2
    w8, gap = 0.444 * w, 0.095 * w
    hmb = 0.38 * h
    eight = fit_to_face(text_mesh('P8', '8', 'regular'), left + w8 / 2, cz, w8, h, y)
    wmb = w - w8 - gap
    mb = fit_to_face(text_mesh('PMB', 'MB', 'regular'), left + w8 + gap + wmb / 2,
                     top + h - hmb / 2, wmb, hmb, y)
    made.append(C.assign(merge_meshes('PRINT_8MB', [eight, mb]), M['gray']))

    # raised SONY in body colour
    lay = LAY['emboss_sony']
    cx, _, cz = lay['center_mm']
    w, h = lay['size_mm']
    relief = lay['relief_mm']
    me = fit_to_face(text_mesh('SONY', 'SONY', 'serif', extrude_mm=0.2, resolution=2),
                     cx, cz, w, h, TOP - 0.05, thickness=relief + 0.05)
    sony = merge_meshes('EMBOSS_SONY', [me])
    bm = bmesh.new()  # the bottom cap sits inside the body: drop it
    bm.from_mesh(sony.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.y < -0.99], context='FACES')
    bm.to_mesh(sony.data)
    bm.free()
    made.append(C.assign(sony, M['body']))

    for ob in made:
        C.set_parent(ob, parent)
    return made


# ---------------------------------------------------------------- render
def look_at(obj, eye, target, up=(0, 1, 0)):
    eye, target, up = Vector(eye), Vector(target), Vector(up)
    z = (eye - target).normalized()
    x = up.cross(z).normalized()
    y = z.cross(x)
    obj.matrix_world = Matrix((
        (x.x, y.x, z.x, eye.x), (x.y, y.y, z.y, eye.y),
        (x.z, y.z, z.z, eye.z), (0, 0, 0, 1)))


def render_views(out_dir):
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    scn.cycles.samples = 32
    scn.cycles.use_denoising = True
    scn.render.resolution_x, scn.render.resolution_y = 1024, 768
    scn.render.film_transparent = False
    scn.view_settings.view_transform = 'Standard'
    world = bpy.data.worlds.new('W')
    world.use_nodes = True
    bg = world.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (0.75, 0.75, 0.74, 1)
    bg.inputs['Strength'].default_value = 0.25
    scn.world = world
    # floor plane under the card (asset Y up)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    floor = bpy.context.active_object
    floor.rotation_euler = (math.radians(-90), 0, 0)
    floor.location = (0, -HY * MM - 0.0002, 0.028)
    C.assign(floor, C.mat('Floor', (0.8, 0.8, 0.78, 1), rough=0.9))
    key = bpy.data.lights.new('Key', 'AREA')
    key.energy, key.size = 0.6, 0.15
    key_ob = bpy.data.objects.new('Key', key)
    scn.collection.objects.link(key_ob)
    look_at(key_ob, (-0.08, 0.2, -0.05), (0, 0, 0.028), up=(0, 0, 1))
    fill = bpy.data.lights.new('Fill', 'AREA')
    fill.energy, fill.size = 0.25, 0.2
    fill_ob = bpy.data.objects.new('Fill', fill)
    scn.collection.objects.link(fill_ob)
    look_at(fill_ob, (0.12, 0.12, 0.15), (0, 0, 0.028), up=(0, 1, 0))

    cam_data = bpy.data.cameras.new('Cam')
    cam = bpy.data.objects.new('Cam', cam_data)
    scn.collection.objects.link(cam)
    scn.camera = cam
    centre = (0, 0, SZ / 2 * MM)
    views = {
        'top': dict(ortho=0.08, eye=(0, 0.3, SZ / 2 * MM), up=(0, 0, -1)),
        '34_rear': dict(lens=70, eye=(-0.09, 0.11, 0.17), up=(0, 1, 0)),
        '34_connector': dict(lens=70, eye=(0.07, 0.09, -0.13), up=(0, 1, 0)),
    }
    for name, v in views.items():
        if 'ortho' in v:
            cam_data.type, cam_data.ortho_scale = 'ORTHO', v['ortho']
        else:
            cam_data.type, cam_data.lens = 'PERSP', v['lens']
        cam_data.clip_start = 0.001
        look_at(cam, v['eye'], centre, up=v['up'])
        scn.render.filepath = str(out_dir / f'memory_card_{name}.png')
        bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- main
def main():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    C.reset_scene()
    M = materials()
    root = C.empty(SPEC['root'])
    shell, bays = build_shell(M)
    C.set_parent(shell, root)
    pins = build_pins(M, bays)
    C.set_parent(pins, root)
    prints = C.empty('TRADEMARK_PRINTS', parent=root)
    build_prints(M, prints)

    for ob in C.descendants(root):
        C.apply_all(ob)
    tris = C.triangle_count(C.descendants(root))
    print(f'[memory_card] triangles: {tris}')
    for ob in C.descendants(root):
        if ob.type == 'MESH':
            print(f'  {ob.name}: {C.triangle_count(ob)}')
    C.export_usdz(root, C.REPO / SPEC['file'])
    C.save_blend(C.REPO / 'PS2_Model/PS2-MemoryCard.blend')
    if '--render' in argv:
        render_views(C.REPO / 'PS2_Model/renders')


main()
