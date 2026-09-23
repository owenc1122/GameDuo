"""Build the PS2 8 MB Memory Card (SCPH-10020, black) runtime model.

Run from the repo root (headless):

    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
        --python-exit-code 1 --python PS2_Model/source/build_memory_card.py [-- --render]

Outputs PS2_Model/exports/PS2-MemoryCard.usdz and PS2_Model/PS2-MemoryCard.blend;
with --render also PS2_Model/renders/memory_card_{top,prints,34_rear,34_connector}.png.

Frame (contract_parts/PS2-MemoryCard.json): card flat, label side up (+Y),
connector end toward -Z. Root PS2_MEMORY_CARD = centre of the connector end face,
so the card spans X -21..21, Y -3.75..3.75, Z 0..56.5: the body is 7.3 mm thick
(Y -3.75..+3.55, label face +3.55) and the embossed SONY rises 0.2 mm to +3.75;
flat prints sit 0.05 mm above the face.

Hierarchy:
    PS2_MEMORY_CARD (empty, origin)
      SHELL            black body: outline with 2 mm chamfers at the connector end,
                       R2.5 rear corners, side grip waves, edge chamfers, a parting
                       groove, the recessed triangle, 2 holes, label recess, groove
                       line and the 3-bay connector window (2 asymmetric ribs)
      CONNECTOR_PINS   8 gold contact pads (1.5 x 0.35 mm) on the bay floors, 3/3/2
      TRADEMARK_PRINTS (empty)
        PRINT_PS_LOGO, PRINT_PLAYSTATION2, PRINT_8MB, PRINT_MEMORY_CARD,
        PRINT_MAGICGATE  flat single-sided print meshes 0.05 mm above the face
        EMBOSS_SONY      raised 0.2 mm body-colour SONY (a trademark, so it lives
                         here too; hiding TRADEMARK_PRINTS leaves a plain face)

Print sources:
  PS logo        tools/ps2_blender/vectors/PS.svg (single colour, official)
  PlayStation 2  wordmark paths of vectors/PlayStation2_logo_commons.svg (no PS2
                 symbol, no (R)); "PlayStation" and the larger "2" are placed
                 separately at their photo-measured boxes (the card's lockup
                 differs from the logo file)
  SONY           vectors/SONY.svg, extruded 0.2 mm
  MagicGate      traced from memcard_top_forenti.jpg by trace_memory_card_prints.py
                 (-> memory_card_prints_traced.json); custom logotype, no vector
  8MB, MEMORY CARD  Helvetica (/System/Library/Fonts/Helvetica.ttc; the card's
                 letterforms are Helvetica), falls back to Blender's built-in font
Vectors keep their proportions (one uniform scale to the contract box); font
text is fitted to the box per axis.
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
HX, HY = SX / 2, SY / 2          # 21, 3.75 (overall bbox half sizes)
BOTTOM = -HY                      # back face (mm)
TOP = BOTTOM + LAY['body_thickness_mm']   # label face: 7.3 body -> Y = +3.55
PRINT_LIFT = 0.05                 # mm above the face for flat prints

VEC = C.HERE / 'vectors'          # shared official vectors (see its README)
PS2_WORD_IDS = {'path3003', 'path3005', 'path3007', 'path3009', 'path3011', 'path3013',
                'path3015', 'path3017', 'path3019', 'path3021', 'path3023', 'path3025'}
PS2_TWO_ID = 'path3031'           # (path3027/3029 = the (R) mark, not printed on the card)
TRACED = Path(__file__).resolve().parent / 'memory_card_prints_traced.json'
FONTS = {'helvetica': Path('/System/Library/Fonts/Helvetica.ttc')}


# ---------------------------------------------------------------- materials
def materials():
    return {
        'body': C.mat('MC_Body', C.hex_rgba(COL['body']), rough=0.62),
        'label': C.mat('MC_LabelRecess', C.hex_rgba(COL['label_recess']), rough=0.5),
        'blue': C.mat('MC_PrintBlue', C.hex_rgba(COL['print_blue']), rough=0.45),
        'gray': C.mat('MC_PrintGray', C.hex_rgba(COL['print_gray']), rough=0.5),
        # partly metallic so the pads read gold even when the dark bays give them
        # nothing bright to reflect
        'pins': C.mat('MC_ContactGold', C.hex_rgba(COL['connector_pins']), rough=0.35, metal=0.6),
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
    rings = [(BOTTOM, 0.3), (BOTTOM + 0.3, 0.0),
             (groove_y0, 0.0), (groove_y0, groove_d), (groove_y1, groove_d), (groove_y1, 0.0),
             (TOP - 0.3, 0.0), (TOP, 0.3)]
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
    pad_w, pad_t, z0, z1 = 1.5, 0.35, 0.5, win["depth_mm"] - 0.3
    for (x0, x1), n in zip(bays, counts):
        mid = (x0 + x1) / 2
        for k in range(n):
            x = mid + (k - (n - 1) / 2) * pitch
            geom = bmesh.ops.create_cube(bm, size=1.0)
            vs = geom['verts']
            bmesh.ops.scale(bm, vec=(pad_w * MM, pad_t * MM, (z1 - z0) * MM), verts=vs)
            bmesh.ops.translate(bm, vec=(x * MM, (floor + pad_t / 2) * MM, (z0 + z1) / 2 * MM),
                                verts=vs)
    bm.normal_update()  # the bottoms lie on the bay floor: drop them
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.y < -0.99], context='FACES')
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
    print(f'[memory_card] font {path} missing, using Blender built-in font')
    return bpy.data.fonts.load('<builtin>', check_existing=True)


def curve_to_mesh(ob):
    """Evaluated (filled) mesh of a curve/text object, in world space, then the
    object and its data are removed."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
    me.transform(ob.matrix_world)
    data = ob.data
    bpy.data.objects.remove(ob, do_unlink=True)
    if data.users == 0:
        (bpy.data.curves.remove if isinstance(data, bpy.types.Curve) else bpy.data.meshes.remove)(data)
    return me


def text_mesh(name, body, font_key, resolution=2):
    """Text as flat mesh data in its own XY plane (font units)."""
    cu = bpy.data.curves.new(name + '_txt', 'FONT')
    cu.body = body
    cu.font = load_font(font_key)
    cu.resolution_u = resolution
    ob = bpy.data.objects.new(name + '_txtobj', cu)
    bpy.context.scene.collection.objects.link(ob)
    return curve_to_mesh(ob)


def svg_mesh(svg_path, drop_ids=(), keep_ids=None, resolution=3):
    """Import an SVG (shared vectors, tools/ps2_blender/vectors) as one flat
    filled mesh in the importer's XY plane (y up). Elements whose id is in
    drop_ids are removed first; with keep_ids only those <path>s are kept."""
    import tempfile
    import xml.etree.ElementTree as ET
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    ET.register_namespace('xlink', 'http://www.w3.org/1999/xlink')
    tree = ET.parse(svg_path)
    parents = {c: p for p in tree.iter() for c in p}
    for el in list(tree.iter()):
        tag = el.tag.split('}')[-1]
        drop = el.get('id') in drop_ids
        if keep_ids is not None and tag in ('path', 'polygon', 'rect', 'circle', 'ellipse'):
            drop = drop or el.get('id') not in keep_ids
        if drop and el in parents:
            parents[el].remove(el)
    with tempfile.TemporaryDirectory() as tmp:
        tmp_svg = Path(tmp) / Path(svg_path).name
        tree.write(tmp_svg)
        before = set(bpy.data.objects)
        cols_before = set(bpy.data.collections)
        mats_before = set(bpy.data.materials)
        bpy.ops.import_curve.svg(filepath=str(tmp_svg))
    new = [o for o in bpy.data.objects if o not in before]
    bm = bmesh.new()
    for ob in new:
        if ob.type != 'CURVE':
            bpy.data.objects.remove(ob, do_unlink=True)
            continue
        ob.data.dimensions = '2D'
        ob.data.fill_mode = 'BOTH'
        ob.data.resolution_u = resolution
        me = curve_to_mesh(ob)
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    for col in set(bpy.data.collections) - cols_before:
        bpy.data.collections.remove(col)
    for m in set(bpy.data.materials) - mats_before:  # SVG fill materials
        bpy.data.materials.remove(m)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-9)
    me = bpy.data.meshes.new(Path(svg_path).stem)
    bm.to_mesh(me)
    bm.free()
    return me


def traced_mesh(key):
    """Polygons from memory_card_prints_traced.json (card mm, X/Z) as a flat
    filled mesh in a text-like XY plane (x = X, y = -Z), even-odd filled."""
    import json
    data = json.loads(TRACED.read_text())
    cu = bpy.data.curves.new(key + '_trace', 'CURVE')
    cu.dimensions, cu.fill_mode = '2D', 'BOTH'
    for poly in data['prints'][key]:
        sp = cu.splines.new('POLY')
        sp.points.add(len(poly) - 1)
        for pt, (x, z) in zip(sp.points, poly):
            pt.co = (x, -z, 0.0, 1.0)
        sp.use_cyclic_u = True
    ob = bpy.data.objects.new(key + '_traceobj', cu)
    bpy.context.scene.collection.objects.link(ob)
    return curve_to_mesh(ob)


def fit_to_face(me, box, y_bottom, uniform=False, scale=None):
    """Map plane coords (x right, y up) onto the label face so the print reads
    with the connector end at the top: x -> +X, y -> -Z, at height y_bottom (mm).
    box = ((X0, Z0), (X1, Z1)) in card mm. The glyph bbox is centred on the box
    and scaled to it: independently per axis (fonts), with one uniform factor
    (geometric mean; vectors keep their official proportions), or by `scale`
    (mm per plane unit, e.g. 1.0 for traced mm data)."""
    (bx0, bz0), (bx1, bz1) = box
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    mx, my = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    sx, sy = (bx1 - bx0) / (max(xs) - min(xs)), (bz1 - bz0) / (max(ys) - min(ys))
    if scale is not None:
        sx = sy = scale
    elif uniform:
        sx = sy = math.sqrt(sx * sy)
    cx, cz = (bx0 + bx1) / 2, (bz0 + bz1) / 2
    for v in me.vertices:
        x, y, _ = v.co
        v.co = ((cx + (x - mx) * sx) * MM, y_bottom * MM, (cz - (y - my) * sy) * MM)
    me.update()
    return me


def box_of(key, size=None):
    lay = LAY[key]
    cx, _, cz = lay['center_mm']
    w, h = size or lay['size_mm']
    return ((cx - w / 2, cz - h / 2), (cx + w / 2, cz + h / 2))


def merge_meshes(name, meshes):
    """One object from several flat print meshes, all faces facing +Y."""
    bm = bmesh.new()
    for me in meshes:
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-9)
    bm.normal_update()
    for f in bm.faces:
        if f.normal.y < 0:
            f.normal_flip()
        f.smooth = False
    return C._mesh_object(name, bm)


def emboss(ob, height_mm):
    """Extrude a flat, upward-facing print mesh by height_mm along +Y (side walls
    + top); the bottom stays open because it sits inside the body."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    res = bmesh.ops.extrude_face_region(bm, geom=list(bm.faces))
    moved = [e for e in res['geom'] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, height_mm * MM, 0), verts=moved)
    bottom = [f for f in bm.faces if all(v not in moved for v in f.verts)]
    bmesh.ops.delete(bm, geom=bottom, context='FACES')
    bm.normal_update()
    for f in bm.faces:
        f.smooth = False
    bm.to_mesh(ob.data)
    bm.free()
    return ob


def build_prints(M, parent):
    y = TOP + PRINT_LIFT
    made = []

    # PS logo: single-colour vector (PS.svg), official proportions
    ps = fit_to_face(svg_mesh(VEC / 'PS.svg', resolution=3), box_of('print_ps_logo'), y,
                     uniform=True)
    made.append(C.assign(merge_meshes('PRINT_PS_LOGO', [ps]), M['blue']))

    # "PlayStation 2": wordmark paths of PlayStation2_logo_commons.svg (no PS2
    # symbol, no (R)); "PlayStation" and the larger "2" placed separately as on the card
    lay = LAY['print_playstation2']
    word = fit_to_face(svg_mesh(VEC / 'PlayStation2_logo_commons.svg', keep_ids=PS2_WORD_IDS,
                                resolution=2), lay['word_bbox_mm'], y, uniform=True)
    two = fit_to_face(svg_mesh(VEC / 'PlayStation2_logo_commons.svg', keep_ids={PS2_TWO_ID},
                               resolution=3), lay['two_bbox_mm'], y, uniform=True)
    made.append(C.assign(merge_meshes('PRINT_PLAYSTATION2', [word, two]), M['blue']))

    # "MEMORY CARD": Helvetica, fitted to the photo bbox
    mc = fit_to_face(text_mesh('PMC', 'MEMORY CARD', 'helvetica'), box_of('print_memory_card'), y)
    made.append(C.assign(merge_meshes('PRINT_MEMORY_CARD', [mc]), M['gray']))

    # "MagicGate": traced logotype, traced scale, centred on the contract centre
    mg = fit_to_face(traced_mesh('print_magicgate'), box_of('print_magicgate'), y, scale=1.0)
    made.append(C.assign(merge_meshes('PRINT_MAGICGATE', [mg]), M['gray']))

    # "8MB": Helvetica big 8 + small MB sharing the baseline; split measured on the
    # photo (8 = 44 % of the width, 9.5 % gap; MB cap height 38 % of the 8).
    (x0, z0), (x1, z1) = box_of('print_8mb')
    w, h = x1 - x0, z1 - z0
    w8, gap, hmb = 0.444 * w, 0.095 * w, 0.38 * h
    eight = fit_to_face(text_mesh('P8', '8', 'helvetica', resolution=3), ((x0, z0), (x0 + w8, z1)), y)
    mb = fit_to_face(text_mesh('PMB', 'MB', 'helvetica'), ((x0 + w8 + gap, z1 - hmb), (x1, z1)), y)
    made.append(C.assign(merge_meshes('PRINT_8MB', [eight, mb]), M['gray']))

    # SONY: vector (SONY.svg), raised in body colour from inside the body
    relief = LAY['emboss_sony']['relief_mm']
    sony = fit_to_face(svg_mesh(VEC / 'SONY.svg', resolution=2), box_of('emboss_sony'),
                       TOP - 0.05, uniform=True)
    sony = emboss(merge_meshes('EMBOSS_SONY', [sony]), relief + 0.05)
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
        'prints': dict(ortho=0.044, eye=(0, 0.3, 0.0155), target=(0, 0, 0.0155), up=(0, 0, -1)),
        '34_rear': dict(lens=70, eye=(-0.09, 0.11, 0.17), up=(0, 1, 0)),
        '34_connector': dict(lens=70, eye=(0.07, 0.09, -0.13), up=(0, 1, 0)),
    }
    for name, v in views.items():
        if 'ortho' in v:
            cam_data.type, cam_data.ortho_scale = 'ORTHO', v['ortho']
        else:
            cam_data.type, cam_data.lens = 'PERSP', v['lens']
        cam_data.clip_start = 0.001
        look_at(cam, v['eye'], v.get('target', centre), up=v['up'])
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
