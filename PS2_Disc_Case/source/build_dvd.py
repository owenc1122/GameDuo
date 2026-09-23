"""PS2 DVD-ROM game disc (NTSC-U/C), runtime model `PS2-DVD`.

Run from the repo root:
    Blender -b --factory-startup --python-exit-code 1 --python PS2_Disc_Case/source/build_dvd.py

Frame (contract_parts/PS2-DVD.json): root PS2_DVD at the disc centre, disc lying
flat, label side +Y, data side -Y, Y = 0 at mid-thickness. Label 2-D coords
[u, v] (viewed from +Y): u = +X, v (label "up") = -Z.

Nodes
  PS2_DVD                 root empty
    DISC_HUB              clear polycarbonate, 15 mm hole -> 41 mm (clamp area 22-33 inside it)
    DISC_BODY             opaque disc 41 -> 120 mm: mirror band 41-44, silver data side,
                          silver rim on the label side outside the print (117-120)
    DISC_LABEL            thin closed annulus 24-117 mm sitting 0.005 mm above the label
                          surface; planar UV 0-1 over the 120 mm square (u = +X,
                          v = label up = -Z) on every face, so a square label image maps
                          naturally and shows (mirrored) through the clear hub from below.
                          Default material DISC_LABEL_default (white).
    TRADEMARK_PRINTS      default NTSC-U/C label prints (black ink, 0.03 mm above the label):
                          PS logo box at 9 o'clock, "PlayStation 2" wordmark below centre.

This file also holds the small geometry / text / logo / render helpers that
build_case.py imports (tools/ps2_blender/common.py must not be edited).
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
HERE = Path(__file__).resolve().parent
ASSET_DIR = HERE.parent
SEGS = 64


# =================================================================== helpers
def new_bm():
    bm = bmesh.new()
    bm.loops.layers.uv.new('UVMap')
    return bm


def finish(name, bm, mats, smooth_angle=None, uv_fn=None, recalc=True, parent=None):
    """bmesh -> mesh object (location 0). uv_fn(co)->(u, v) fills UVMap per loop."""
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if uv_fn is not None:
        uv = bm.loops.layers.uv.active or bm.loops.layers.uv.new('UVMap')
        for f in bm.faces:
            for lp in f.loops:
                lp[uv].uv = uv_fn(lp.vert.co)
    if smooth_angle is not None:
        C._smooth_by_angle(bm, smooth_angle)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for m in mats:
        me.materials.append(m)
    if parent is not None:
        C.set_parent(obj, parent)
    return obj


def add_prism(bm, pts, z0, z1, M=None, mi=0):
    """Extrude a CCW 2-D polygon `pts` (metres) from local z0 to z1, transform by M."""
    M = M or Matrix.Identity(4)
    bot = [bm.verts.new(M @ Vector((x, y, z0))) for x, y in pts]
    top = [bm.verts.new(M @ Vector((x, y, z1))) for x, y in pts]
    faces = [bm.faces.new(top), bm.faces.new(list(reversed(bot)))]
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        faces.append(bm.faces.new((bot[i], bot[j], top[j], top[i])))
    for f in faces:
        f.material_index = mi
    return faces


def add_box(bm, x0, x1, y0, y1, z0, z1, M=None, mi=0):
    return add_prism(bm, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)], z0, z1, M, mi)


def rrect(x0, x1, y0, y1, radii=(0, 0, 0, 0), segs=5):
    """CCW rounded rectangle; radii = (x0y0, x1y0, x1y1, x0y1)."""
    corners = [((x0, y0), (1, 1), math.pi), ((x1, y0), (-1, 1), 1.5 * math.pi),
               ((x1, y1), (-1, -1), 0.0), ((x0, y1), (1, -1), 0.5 * math.pi)]
    pts = []
    for ((cx, cy), (sx, sy), a0), r in zip(corners, radii):
        if r <= 0:
            pts.append((cx, cy))
            continue
        ox, oy = cx + sx * r, cy + sy * r
        for k in range(segs + 1):
            a = a0 + 0.5 * math.pi * k / segs
            pts.append((ox + r * math.cos(a), oy + r * math.sin(a)))
    return pts


def plate(name, x0, x1, y0, y1, z0, z1, radii=(0, 0, 0, 0), segs=5, mats=(), parent=None):
    bm = new_bm()
    add_prism(bm, rrect(x0, x1, y0, y1, radii, segs), z0, z1)
    return finish(name, bm, mats, smooth_angle=35, parent=parent)


def add_lathe(bm, loop, mis, segs=SEGS, closed=True):
    """Revolve a closed (r, y) profile loop about +Y. mis[i] = material of edge i."""
    angs = [2 * math.pi * k / segs for k in range(segs)]
    rings = [[bm.verts.new((r * math.cos(a), y, -r * math.sin(a))) for a in angs] for r, y in loop]
    n = len(loop)
    for i in range(n if closed else n - 1):
        j = (i + 1) % n
        for k in range(segs):
            k2 = (k + 1) % segs
            f = bm.faces.new((rings[i][k], rings[i][k2], rings[j][k2], rings[j][k]))
            f.material_index = mis[i]


def add_arc(bm, cx, cy, r0, r1, a0, a1, z0, z1, n=10, mi=0):
    """Annular sector (angles in radians, XY plane) extruded along Z, built from quads."""
    def ring(r, z):
        return [bm.verts.new((cx + r * math.cos(a0 + (a1 - a0) * k / n),
                              cy + r * math.sin(a0 + (a1 - a0) * k / n), z)) for k in range(n + 1)]
    ib, ob, it, ot = ring(r0, z0), ring(r1, z0), ring(r0, z1), ring(r1, z1)
    fs = []
    for k in range(n):
        fs += [bm.faces.new((it[k], ot[k], ot[k + 1], it[k + 1])),
               bm.faces.new((ib[k], ib[k + 1], ob[k + 1], ob[k])),
               bm.faces.new((ob[k], ob[k + 1], ot[k + 1], ot[k])),
               bm.faces.new((ib[k], it[k], it[k + 1], ib[k + 1]))]
    fs += [bm.faces.new((ib[0], ob[0], ot[0], it[0])), bm.faces.new((ib[n], it[n], ot[n], ob[n]))]
    for f in fs:
        f.material_index = mi


def basis(origin, xdir, ydir):
    """4x4 matrix mapping local (x, y, z) to origin + x*xdir + y*ydir + z*(xdir x ydir)."""
    x, y = Vector(xdir).normalized(), Vector(ydir).normalized()
    z = x.cross(y)
    M = Matrix.Identity(4)
    for r in range(3):
        M[r][0], M[r][1], M[r][2], M[r][3] = x[r], y[r], z[r], origin[r]
    return M


def add_strip(bm, pts, half, M, mi=0):
    """Flat ribbon (faces +local Z) along a 2-D polyline; `half` = half-width
    (number, or one value per point)."""
    n = len(pts)
    halves = half if isinstance(half, (list, tuple)) else [half] * n
    left, right = [], []
    for i, (x, y) in enumerate(pts):
        a = Vector(pts[max(i - 1, 0)])
        b = Vector(pts[min(i + 1, n - 1)])
        d = (b - a).normalized()
        nrm = Vector((-d.y, d.x)) * halves[i]
        left.append(bm.verts.new(M @ Vector((x + nrm.x, y + nrm.y, 0))))
        right.append(bm.verts.new(M @ Vector((x - nrm.x, y - nrm.y, 0))))
    for i in range(n - 1):
        f = bm.faces.new((right[i], right[i + 1], left[i + 1], left[i]))
        f.material_index = mi


def add_flat(bm, pts, M, mi=0):
    """Flat convex polygon facing +local Z."""
    f = bm.faces.new([bm.verts.new(M @ Vector((x, y, 0))) for x, y in pts])
    f.material_index = mi
    return f


def add_flat_poly(bm, pts, M, mi=0):
    """Flat (possibly concave) simple polygon facing +local Z, triangulated."""
    area = sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]))
    if area < 0:
        pts = list(reversed(pts))
    f = add_flat(bm, pts, M, mi)
    bmesh.ops.triangulate(bm, faces=[f], quad_method='BEAUTY', ngon_method='EAR_CLIP')


# ------------------------------------------------------------ SVG vectors
VEC = C.REPO / 'tools/ps2_blender/vectors'
PS2_WORDMARK_PATHS = ['path3003', 'path3005', 'path3023', 'path3007', 'path3009', 'path3011',
                      'path3025', 'path3021', 'path3013', 'path3015', 'path3017', 'path3019',
                      'path3027', 'path3029', 'path3031']   # "PlayStation(R)2" in the PS2 logo SVG


def svg_parts(fname, names=None, res=2):
    """Import a vector from tools/ps2_blender/vectors, fill + mesh each curve object,
    then delete everything the importer created. Returns [(name, [(x, y)], [faces])]
    in the importer's units (y up)."""
    before = {k: set(getattr(bpy.data, k)) for k in ('objects', 'curves', 'materials', 'collections')}
    bpy.ops.import_curve.svg(filepath=str(VEC / fname))
    new = [o for o in bpy.data.objects if o not in before['objects']]
    keep = [o for o in new if o.type == 'CURVE' and (names is None or o.name in names)]
    for o in keep:
        o.data.resolution_u = res
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    parts = []
    for o in sorted(keep, key=lambda o: (names.index(o.name) if names else 0, o.name)):
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        mw = o.matrix_world
        verts = [((mw @ v.co).x, (mw @ v.co).y) for v in me.vertices]
        parts.append((o.name, verts, [tuple(p.vertices) for p in me.polygons]))
        bpy.data.meshes.remove(me)
    for o in new:
        bpy.data.objects.remove(o, do_unlink=True)
    for k in ('curves', 'materials', 'collections'):
        coll = getattr(bpy.data, k)
        for item in [i for i in coll if i not in before[k]]:
            coll.remove(item)
    return parts


def _fit(parts, cx, cy, w, h, fit):
    xs = [x for _, vs, _ in parts for x, _ in vs]
    ys = [y for _, vs, _ in parts for _, y in vs]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sx, sy = w / (x1 - x0), h / (y1 - y0)
    if fit == 'width':
        sy = sx
    elif fit == 'height':
        sx = sy
    elif fit == 'contain':
        sx = sy = min(sx, sy)
    xc, yc = (x0 + x1) / 2, (y0 + y1) / 2
    return (lambda x, y: (cx + (x - xc) * sx, cy + (y - yc) * sy),
            lambda x, y: ((x - x0) / (x1 - x0), (y - y0) / (y1 - y0)))


def add_svg(bm, parts, cx, cy, w, h, M, mi=0, fit='width', mi_fn=None):
    """Flat SVG geometry fitted into a w x h box at (cx, cy) of M's XY plane, every face
    facing +local Z. mi_fn(part_name, u, v, face_index) -> material index (u, v = face centre, 0-1)."""
    place, norm = _fit(parts, cx, cy, w, h, fit)
    for name, verts, faces in parts:
        loc = [place(x, y) for x, y in verts]
        bv = [bm.verts.new(M @ Vector((x, y, 0))) for x, y in loc]
        for fi, f in enumerate(faces):
            pts = [loc[i] for i in f]
            area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(pts, pts[1:] + pts[:1]))
            idx = list(f) if area > 0 else list(reversed(f))
            try:
                nf = bm.faces.new([bv[i] for i in idx])
            except ValueError:
                continue
            if mi_fn:
                u = sum(verts[i][0] for i in f) / len(f)
                v = sum(verts[i][1] for i in f) / len(f)
                nf.material_index = mi_fn(name, *norm(u, v), fi)
            else:
                nf.material_index = mi


def add_ps_logo(bm, cx, cy, w, h, M, mis=None, res=2):
    """PlayStation family logo from PlayStation_logo_commons.svg, fitted (aspect kept)
    inside w x h. mis=None -> single colour (index 0); mis=(red, yellow, green, blue)
    colours it like the printed colour logo: red P; S left piece yellow below / green
    above its mid-height; S right piece green below / blue above."""
    parts = svg_parts('PlayStation_logo_commons.svg', res=res)
    if mis is None:
        add_svg(bm, parts, cx, cy, w, h, M, fit='contain')
        return
    # islands (P, S-left, S-right) + a clean horizontal cut through each S piece
    name, verts, faces = parts[0]
    tmp = bmesh.new()
    tv = [tmp.verts.new((x, y, 0)) for x, y in verts]
    for f in faces:
        try:
            tmp.faces.new([tv[i] for i in f])
        except ValueError:
            pass
    isl = tmp.faces.layers.int.new('island')
    seen, islands = set(), []
    for f in tmp.faces:
        if f in seen:
            continue
        stack, group = [f], []
        seen.add(f)
        while stack:
            g = stack.pop()
            group.append(g)
            for v in g.verts:
                for h2 in v.link_faces:
                    if h2 not in seen:
                        seen.add(h2)
                        stack.append(h2)
        islands.append(group)
    boxes = []
    for i, group in enumerate(islands):
        co = [v.co for g in group for v in g.verts]
        boxes.append((min(c.x for c in co), max(c.x for c in co), min(c.y for c in co), max(c.y for c in co)))
        for g in group:
            g[isl] = i
    p_i = max(range(len(boxes)), key=lambda i: boxes[i][3])
    others = sorted((i for i in range(len(boxes)) if i != p_i), key=lambda i: boxes[i][0])
    left_i, right_i = others[0], others[-1]
    mids = {}
    for i in (left_i, right_i):
        mid = (boxes[i][2] + boxes[i][3]) / 2
        mids[i] = mid
        geom = [g for g in tmp.faces if g[isl] == i]
        geom = list({*geom, *(e for g in geom for e in g.edges), *(v for g in geom for v in g.verts)})
        bmesh.ops.bisect_plane(tmp, geom=geom, plane_co=(0, mid, 0), plane_no=(0, 1, 0))
    red, yellow, green, blue = mis
    tv_list = list(tmp.verts)
    index = {v: k for k, v in enumerate(tv_list)}
    new_faces, colours = [], []
    for g in tmp.faces:
        c = g.calc_center_median()
        i = g[isl]
        if i == left_i:
            col = green if c.y > mids[i] else yellow
        elif i == right_i:
            col = blue if c.y > mids[i] else green
        else:
            col = red
        new_faces.append(tuple(index[v] for v in g.verts))
        colours.append(col)
    pverts = [(v.co.x, v.co.y) for v in tv_list]
    tmp.free()
    add_svg(bm, [(name, pverts, new_faces)], cx, cy, w, h, M, fit='contain',
            mi_fn=lambda _n, _u, _v, fi: colours[fi])


def add_ps2_wordmark(bm, cx, cy, w, h, M, mi=0, res=2, fit='width', registered=True):
    """Official "PlayStation(R)2" wordmark outlines (PlayStation2_logo_commons.svg)."""
    names = [n for n in PS2_WORDMARK_PATHS if registered or n not in ('path3027', 'path3029')]
    add_svg(bm, svg_parts('PlayStation2_logo_commons.svg', names, res), cx, cy, w, h, M, mi, fit)


def add_outline(bm, cx, cy, w, h, line, M, mi=0):
    x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    for rect in [(x0, x1, y0, y0 + line), (x0, x1, y1 - line, y1),
                 (x0, x0 + line, y0 + line, y1 - line), (x1 - line, x1, y0 + line, y1 - line)]:
        a, b, c, d = rect
        add_flat(bm, [(a, c), (b, c), (b, d), (a, d)], M, mi)


def add_text(bm, body, cx, cy, w, h, M, mi=0, depth=0.0, res=2, fit='box'):
    """Blender built-in font text fitted to a w x h box centred at (cx, cy) in the
    local XY plane of M; flat facing +local Z (depth 0) or extruded 0..depth along +Z."""
    cu = bpy.data.curves.new('tmp_text', 'FONT')
    cu.body = body
    cu.resolution_u = res
    cu.size = 1.0
    if depth > 0:
        cu.extrude = 0.05
    ob = bpy.data.objects.new('tmp_text', cu)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.curves.remove(cu)
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sx, sy = w / (x1 - x0), h / (y1 - y0)
    if fit == 'width':
        sy = sx
    elif fit == 'height':
        sx = sy
    tmp = bmesh.new()
    tmp.from_mesh(me)
    bpy.data.meshes.remove(me)
    vmap = {}
    for v in tmp.verts:
        z = (v.co.z + 0.05) / 0.1 * depth if depth > 0 else 0.0
        loc = Vector((cx + (v.co.x - (x0 + x1) / 2) * sx, cy + (v.co.y - (y0 + y1) / 2) * sy, z))
        vmap[v] = bm.verts.new(M @ loc)
    flip = (sx * sy) < 0
    out = []
    for f in tmp.faces:
        vs = [vmap[v] for v in f.verts]
        if flip:
            vs.reverse()
        try:
            nf = bm.faces.new(vs)
        except ValueError:
            continue
        nf.material_index = mi
        out.append(nf)
    tmp.free()
    # flat text: make every face point along +local Z
    if depth <= 0:
        want = (M.to_3x3() @ Vector((0, 0, 1))).normalized()
        for f in out:
            f.normal_update()
            if f.normal.dot(want) < 0:
                f.normal_flip()
    return out


# ------------------------------------------------------------------ rendering
def look_at(cam, eye, target, up=(0, 1, 0)):
    eye, target, up = Vector(eye), Vector(target), Vector(up)
    f = (target - eye).normalized()
    r = f.cross(up).normalized()
    u = r.cross(f)
    M = Matrix.Identity(4)
    for i in range(3):
        M[i][0], M[i][1], M[i][2], M[i][3] = r[i], u[i], -f[i], eye[i]
    cam.matrix_world = M


def setup_render(res=(1024, 768), samples=32, world_rgb=(0.20, 0.21, 0.23)):
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.device = 'CPU'
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.view_settings.view_transform = 'Standard'
    sc.render.image_settings.file_format = 'PNG'
    world = bpy.data.worlds.get('RenderWorld') or bpy.data.worlds.new('RenderWorld')
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes.get('Background')
    bg.inputs['Strength'].default_value = 1.0
    # vertical gradient (asset +Y is up): dark floor -> light sky, so metal reads as metal
    tc = nt.nodes.new('ShaderNodeTexCoord')
    sep = nt.nodes.new('ShaderNodeSeparateXYZ')
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    nt.links.new(tc.outputs['Generated'], sep.inputs[0])
    nt.links.new(sep.outputs['Y'], ramp.inputs['Fac'])
    ramp.color_ramp.elements[0].position = 0.45
    ramp.color_ramp.elements[0].color = (world_rgb[0] * 0.25, world_rgb[1] * 0.25, world_rgb[2] * 0.25, 1)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (world_rgb[0] * 2.6, world_rgb[1] * 2.6, world_rgb[2] * 2.6, 1)
    nt.links.new(ramp.outputs['Color'], bg.inputs['Color'])
    sc.world = world
    cam = bpy.data.objects.get('RenderCam')
    if cam is None:
        cam = bpy.data.objects.new('RenderCam', bpy.data.cameras.new('RenderCam'))
        sc.collection.objects.link(cam)
    cam.data.lens = 50
    cam.data.clip_start = 0.005
    sc.camera = cam
    return cam


def area_light(name, loc, target, size, energy, color=(1, 1, 1)):
    li = bpy.data.objects.get(name)
    if li is None:
        li = bpy.data.objects.new(name, bpy.data.lights.new(name, 'AREA'))
        bpy.context.scene.collection.objects.link(li)
    li.data.size = size
    li.data.energy = energy
    li.data.color = color
    look_at(li, loc, target)
    return li


def render(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    return path


# =================================================================== the disc
def build():
    """Build the disc tree in the current scene; returns root PS2_DVD."""
    spec = C.load_contract('PS2-DVD')
    L, col = spec['layout'], spec['colors']
    r_hole = L['center_hole_d'] / 2 * MM            # 7.5
    r_clear = L['clear_hub_outer_d'] / 2 * MM       # 20.5
    r_mirror = L['mirror_band_outer_d'] / 2 * MM    # 22.0
    r_lab0 = L['label_inner_d'] / 2 * MM            # 12.0
    r_lab1 = L['label_outer_d'] / 2 * MM            # 58.5
    R = spec['size_mm'][0] / 2 * MM                 # 60
    t = spec['size_mm'][1] / 2 * MM                 # 0.6
    e = L['edge_round_radius_mm'] * MM              # 0.2

    m_data = C.mat('DVD_data_side', C.hex_rgba(col['data_side']), rough=0.12, metal=1.0)
    m_mirror = C.mat('DVD_mirror_band', C.hex_rgba(col['mirror_band']), rough=0.03, metal=1.0)
    m_hub = C.mat('DVD_hub_clear', C.hex_rgba(col['hub_clear_polycarbonate']), rough=0.05, alpha=0.3)
    m_rim = C.mat('DVD_rim', C.hex_rgba('#A9A9AE'), rough=0.25, metal=0.8)
    m_label = C.mat('DISC_LABEL_default', C.hex_rgba(col['label_default']), rough=0.45)
    m_ink = C.mat('DVD_print_ink', C.hex_rgba(col['label_ink_black_ntscuc']), rough=0.4)

    root = C.empty('PS2_DVD')

    # clear hub 7.5 -> 20.5 mm (full thickness) with the molded stacking ring on the
    # data side (d 37, 0.2 mm high, ECMA-267 third transition area 33-44 allows +0.25)
    rs = L['stacking_ring_d'] / 2 * MM
    hs = L['stacking_ring_height_mm'] * MM
    bm = new_bm()
    add_lathe(bm, [(r_hole, t), (r_clear, t), (r_clear, -t), (rs + 0.4 * MM, -t), (rs, -t - hs),
                   (rs - 0.4 * MM, -t), (r_hole, -t)], [0] * 7)
    finish('DISC_HUB', bm, [m_hub], smooth_angle=30, parent=root)

    # opaque body 20.5 -> 60 mm; profile CCW seen with +r right, +y up
    loop = [(r_clear, t), (r_lab1, t), (R - e, t), (R, t - e), (R, -t + e), (R - e, -t),
            (r_mirror, -t), (r_clear, -t)]
    #        top-under-label, top rim, bevel, edge, bevel, data, mirror, inner wall
    mis = [2, 2, 2, 2, 2, 0, 1, 2]
    bm = new_bm()
    add_lathe(bm, loop, mis)
    finish('DISC_BODY', bm, [m_data, m_mirror, m_rim], smooth_angle=30, parent=root)

    # printable label: thin closed annulus, planar UVs over the 120 mm square
    y0, y1 = t + 0.005 * MM, t + 0.025 * MM
    bm = new_bm()
    add_lathe(bm, [(r_lab0, y1), (r_lab1, y1), (r_lab1, y0), (r_lab0, y0)], [0, 0, 0, 0])
    uv = lambda co: ((co.x + R) / (2 * R), (-co.z + R) / (2 * R))  # noqa: E731
    finish('DISC_LABEL', bm, [m_label], smooth_angle=30, uv_fn=uv, parent=root)

    # default NTSC-U/C prints, black ink, 0.03 mm above the label
    prints = C.empty('TRADEMARK_PRINTS', parent=root)
    yp = y1 + 0.03 * MM
    Mlab = basis((0, yp, 0), (1, 0, 0), (0, 0, -1))  # local x = u, local y = v, normal +Y
    el = L['label_elements_ntscuc']
    bx = el['ps_logo_box']
    (bu, bv), (bw, bh) = bx['center_uv_mm'], bx['size_mm']
    bm = new_bm()
    add_outline(bm, bu * MM, bv * MM, bw * MM, bh * MM, 0.6 * MM, Mlab)
    add_ps_logo(bm, bu * MM, bv * MM, 11.0 * MM, 9.2 * MM, Mlab)
    finish('LABEL_PS_LOGO_BOX', bm, [m_ink], recalc=False, parent=prints)
    wm = el['playstation2_wordmark']
    (wu, wv), (ww, wh) = wm['center_uv_mm'], wm['size_mm']
    bm = new_bm()
    add_ps2_wordmark(bm, wu * MM, wv * MM, ww * MM, wh * MM, Mlab)
    finish('LABEL_WORDMARK', bm, [m_ink], recalc=False, parent=prints)

    # molded holograms in the clear hub ring (data side, 0.03 mm below it): 3 PS logos
    # alternating with 3 "PlayStation 2" wordmarks, tangential, letters' up toward the centre
    holo = L['data_side_holograms']
    rc = (holo['ring_inner_d'] + holo['ring_outer_d']) / 4 * MM
    m_holo = C.mat('DVD_hologram', C.hex_rgba('#B4B2D6'), rough=0.12, metal=1.0)
    bm = new_bm()
    for k in range(holo['count']):
        a = math.radians(90 + 60 * k)
        tx, tz = -math.sin(a), math.cos(a)
        Mh = basis((rc * math.cos(a), -t - 0.03 * MM, rc * math.sin(a)),
                   (tx, 0, tz), (-math.cos(a), 0, -math.sin(a)))
        if k % 2:
            add_ps2_wordmark(bm, 0, 0, 9.0 * MM, 1.8 * MM, Mh, res=1, registered=False)
        else:
            add_ps_logo(bm, 0, 0, 4.2 * MM, 3.2 * MM, Mh, res=1)
    finish('HUB_HOLOGRAMS', bm, [m_holo], recalc=False, parent=prints)
    return root


def main():
    C.reset_scene()
    root = build()
    tris = C.triangle_count(C.descendants(root))
    print(f'PS2-DVD triangles: {tris}')
    C.export_usdz(root, ASSET_DIR / 'exports/PS2-DVD.usdz')

    cam = setup_render()
    area_light('KeyLight', (0.25, 0.35, 0.15), (0, 0, 0), 0.25, 5)
    area_light('FillLight', (-0.3, 0.15, -0.2), (0, 0, 0), 0.4, 3)
    look_at(cam, (0.09, 0.22, 0.17), (0, 0, 0.0))
    render(ASSET_DIR / 'renders/dvd_label.png')
    root.rotation_euler = (0, 0, math.pi)  # render only (export done): data side up
    bpy.data.objects['KeyLight'].data.energy = 1.5
    render(ASSET_DIR / 'renders/dvd_data.png')
    root.rotation_euler = (0, 0, 0)


if __name__ == '__main__':
    main()
