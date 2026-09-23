"""Build the Sony DualShock 2 (SCPH-10010, black) runtime asset for Game Duo.

Run from the repo root (background Blender, see docs/superpowers/plans/ps2-builder-brief.md):

    B="/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1"
    $B --python PS2_Model/source/build_dualshock2.py [-- --render]

Frame (contract_parts/PS2-DualShock2.json "frame"): controller lying face-up on a
table, X right, Y up (0 = table), Z toward the player (+Z grip ends, -Z shoulders /
cable). Modelled directly in those axes (Blender Y = up). Root DUALSHOCK2 = bottom
centre of the body bbox. All layout numbers below are millimetres.

Body: a signed-distance field (flat face deck + stick bosses + shoulder towers +
round-cone grips, smooth unions) meshed with OpenVDB, decimated, then cut with
EXACT booleans for the wells, pockets, holes and screw recesses so every moving part
has real clearance. Moving parts are separate nodes whose local transform is the pivot.
Prints come from the shared vectors in tools/ps2_blender/vectors (SONY, PS, PlayStation,
SELECT, START, L, R, face symbols, D-pad arrows); "DUALSHOCK 2" and "ANALOG" have no
vector and use the closest system font (Arial Bold / Arial).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/ps2_blender"))
import common as C  # noqa: E402

import bmesh  # noqa: E402
import bpy  # noqa: E402
import numpy as np  # noqa: E402
import openvdb  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

ASSET = 'PS2-DualShock2'
K = C.load_contract(ASSET)
L = K['layout']
COL = K['colors']
TR = K['travel']
MM = 0.001
OUT_USDZ = C.REPO / K['file']
OUT_BLEND = C.REPO / 'PS2_Model/PS2-DualShock2.blend'
RENDER_DIR = C.REPO / 'PS2_Model/renders'

FACE_Y = K['face_plane_y_mm']          # 52: flat face deck
BOSS_Y = 50.0                          # floor of the conical stick ring (a 25 deg cap clears it)
RING_R0, RING_R1 = 13.0, 17.5
POD_Y = 52.8                           # raised D-pad / face-button pods (photo: clear circular rim)
POD_INSET, POD_RIM_R = 0.6, 0.9        # pod platform radius = POD_R - inset, rim rounding          # cone from BOSS_Y (r0) up to the face plane (r1)
WELL_FLOOR = 50.0                      # D-pad / face-button cross wells
GAP = 0.3                              # radial clearance of buttons in their holes
BODY_TRIS = 16000                      # decimation target for the SDF body


# ============================================================ small helpers
def v3(p):
    return Vector((p[0], p[1], p[2]))


def mm(p):
    return Vector((p[0] * MM, p[1] * MM, p[2] * MM))


def srgb(key_or_hex, a=1.0):
    return C.hex_rgba(COL.get(key_or_hex, key_or_hex), a)


MATS = {}


def material(name, hex_or_key, rough=0.5, metal=0.0, alpha=1.0):
    MATS[name] = C.mat(name, srgb(hex_or_key), rough=rough, metal=metal, alpha=alpha)
    return MATS[name]


def make_object(name, bm, mats, parent, origin_mm=(0, 0, 0), smooth_angle=35.0):
    """Mesh object from a bmesh built in WORLD millimetres. Its origin (pivot) is
    `origin_mm` (world); its local rotation is zero relative to `parent`, so the
    vertex data is expressed in the parent's axes."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bpy.context.view_layer.update()
    pw = parent.matrix_world.copy() if parent else Matrix.Identity(4)
    local_origin = pw.inverted() @ mm(origin_mm)
    target = pw @ Matrix.Translation(local_origin)
    to_local = target.inverted() @ Matrix.Diagonal((MM, MM, MM, 1.0))
    bmesh.ops.transform(bm, matrix=to_local, verts=bm.verts)
    if smooth_angle:
        smooth_bm(bm, smooth_angle)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Identity(4)
    obj.location = local_origin
    obj.rotation_euler = (0, 0, 0)
    return obj


def smooth_bm(bm, angle_deg):
    for f in bm.faces:
        f.smooth = True
    limit = math.radians(angle_deg)
    for e in bm.edges:
        e.smooth = e.is_manifold and e.calc_face_angle(0.0) <= limit


def smooth_object(obj, angle_deg):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    smooth_bm(bm, angle_deg)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


# ============================================================ 2D polygons (x, z)
def round_poly(pts, radius, n=4):
    """Round every corner of a simple polygon; `radius` scalar or per-corner list."""
    out = []
    N = len(pts)
    for i in range(N):
        P = np.array(pts[i], float)
        A = np.array(pts[i - 1], float)
        B = np.array(pts[(i + 1) % N], float)
        r = radius[i] if isinstance(radius, (list, tuple)) else radius
        la, lb = np.linalg.norm(A - P), np.linalg.norm(B - P)
        if r <= 0 or la < 1e-9 or lb < 1e-9:
            out.append(tuple(P))
            continue
        u, v = (A - P) / la, (B - P) / lb
        ang = math.acos(max(-1.0, min(1.0, float(np.dot(u, v)))))
        if ang > math.pi - 1e-3:
            out.append(tuple(P))
            continue
        t = r / math.tan(ang / 2)
        tmax = 0.49 * min(la, lb)
        if t > tmax:
            t = tmax
            r = t * math.tan(ang / 2)
        bis = (u + v) / np.linalg.norm(u + v)
        Cc = P + bis * (r / math.sin(ang / 2))
        T1, T2 = P + u * t, P + v * t
        a1 = math.atan2(T1[1] - Cc[1], T1[0] - Cc[0])
        a2 = math.atan2(T2[1] - Cc[1], T2[0] - Cc[0])
        d = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
        for k in range(n + 1):
            a = a1 + d * k / n
            out.append((Cc[0] + r * math.cos(a), Cc[1] + r * math.sin(a)))
    return out


def rrect(cx, cz, w, d, r, n=4):
    hx, hz = w / 2, d / 2
    pts = [(cx - hx, cz - hz), (cx + hx, cz - hz), (cx + hx, cz + hz), (cx - hx, cz + hz)]
    return round_poly(pts, r, n)


def cross_poly(cx, cz, ex, ez, w, r_out, r_in, n=3):
    """Plus shape: half extents ex (x) / ez (z), arm half-width w."""
    raw = [(w, ez), (-w, ez), (-w, w), (-ex, w), (-ex, -w), (-w, -w), (-w, -ez),
           (w, -ez), (w, -w), (ex, -w), (ex, w), (w, w)]
    radii = [r_in if (abs(abs(x) - w) < 1e-9 and abs(abs(z) - w) < 1e-9) else r_out for x, z in raw]
    return [(cx + x, cz + z) for x, z in round_poly(raw, radii, n)]


def circle_poly(cx, cz, r, n=32):
    return [(cx + r * math.cos(2 * math.pi * i / n), cz + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


# ============================================================ bmesh builders (world mm)
def add_prism(bm, poly, y0, y1, mat=0, bevel_top=0.0, segs=2):
    bot = [bm.verts.new((x, y0, z)) for x, z in poly]
    top = [bm.verts.new((x, y1, z)) for x, z in poly]
    faces = [bm.faces.new(bot[::-1]), bm.faces.new(top)]
    n = len(poly)
    for i in range(n):
        j = (i + 1) % n
        faces.append(bm.faces.new((bot[i], bot[j], top[j], top[i])))
    for f in faces:
        f.material_index = mat
    if bevel_top > 0:
        edges = [e for e in bm.edges if all(v in top for v in e.verts)]
        bmesh.ops.bevel(bm, geom=edges, offset=bevel_top, segments=segs, profile=0.5,
                        affect='EDGES', clamp_overlap=True)
    return faces


def add_lathe(bm, profile, center, seg=32, mat_fn=None, axis_matrix=None):
    """Surface of revolution about the vertical axis through center=(x, y, z) world.
    profile: [(r, dy), ...] from top pole to bottom pole (r=0 ends -> closed)."""
    rings = []
    for r, dy in profile:
        if r < 1e-9:
            rings.append([(0.0, dy, 0.0)])
        else:
            rings.append([(r * math.cos(2 * math.pi * i / seg), dy, r * math.sin(2 * math.pi * i / seg))
                          for i in range(seg)])
    M = axis_matrix or Matrix.Identity(4)
    cvec = v3(center)
    vr = [[bm.verts.new(M @ Vector(p) + cvec) for p in ring] for ring in rings]
    for a, b in zip(vr, vr[1:]):
        ymid = None
        if len(a) == 1 and len(b) == 1:
            continue
        for i in range(seg):
            j = (i + 1) % seg
            if len(a) == 1:
                f = bm.faces.new((a[0], b[j], b[i]))
            elif len(b) == 1:
                f = bm.faces.new((a[i], a[j], b[0]))
            else:
                f = bm.faces.new((a[i], a[j], b[j], b[i]))
            if mat_fn:
                ymid = sum(v.co.y for v in f.verts) / len(f.verts) - center[1]
                f.material_index = mat_fn(ymid)
    return vr


def add_box(bm, center, size, radius, mat=0, segs=2):
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    bmesh.ops.scale(tmp, vec=size, verts=tmp.verts)
    if radius > 0:
        bmesh.ops.bevel(tmp, geom=list(tmp.verts) + list(tmp.edges), offset=radius,
                        offset_type='OFFSET', segments=segs, profile=0.5, affect='EDGES',
                        clamp_overlap=True)
    bmesh.ops.translate(tmp, vec=center, verts=tmp.verts)
    for f in tmp.faces:
        f.material_index = mat
    me = bpy.data.meshes.new('_tmp')
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def add_cyl_y(bm, cx, cz, r, y0, y1, seg=48, mat=0):
    add_lathe(bm, [(0, y1), (r, y1), (r, y0), (0, y0)], (cx, 0, cz), seg,
              mat_fn=(lambda y: mat))


def frame_matrix(fwd):
    """Rotation whose local +Z is `fwd` (unit), local +Y as close to world +Y as possible."""
    f = Vector(fwd).normalized()
    up = Vector((0, 1, 0)) if abs(f.y) < 0.95 else Vector((1, 0, 0))
    x = up.cross(f).normalized()
    y = f.cross(x).normalized()
    M = Matrix((x, y, f)).transposed().to_4x4()
    return M


def add_tube(bm, pts, radius, sides=10, mat=0, cap=True):
    """Swept circle along a polyline (parallel-transport frames), capped ends."""
    pts = [Vector(p) for p in pts]
    tangents = []
    for i in range(len(pts)):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, len(pts) - 1)]
        tangents.append((b - a).normalized())
    n0 = tangents[0].orthogonal().normalized()
    normals = [n0]
    for i in range(1, len(pts)):
        n = normals[-1]
        t = tangents[i]
        n = (n - t * n.dot(t)).normalized()
        normals.append(n)
    rings = []
    for p, t, n in zip(pts, tangents, normals):
        b = t.cross(n)
        rings.append([bm.verts.new(p + (n * math.cos(2 * math.pi * k / sides)
                                        + b * math.sin(2 * math.pi * k / sides)) * radius)
                      for k in range(sides)])
    for a, b in zip(rings, rings[1:]):
        for k in range(sides):
            j = (k + 1) % sides
            bm.faces.new((a[k], a[j], b[j], b[k])).material_index = mat
    if cap:
        bm.faces.new(rings[0][::-1]).material_index = mat
        bm.faces.new(rings[-1]).material_index = mat


# ============================================================ SDF body
def sat(x):
    return np.clip(x, 0.0, 1.0)


def smin(a, b, k):
    h = sat(0.5 + 0.5 * (b - a) / k)
    return b + (a - b) * h - k * h * (1.0 - h)


def smax(a, b, k):
    return -smin(-a, -b, k)


def sd_rrect2(x, z, cx, cz, hx, hz, r):
    qx = np.abs(x - cx) - hx + r
    qz = np.abs(z - cz) - hz + r
    return np.hypot(np.maximum(qx, 0), np.maximum(qz, 0)) + np.minimum(np.maximum(qx, qz), 0) - r


def extrude(d2, y, y0, y1, rtop, rbot):
    """Extrude a 2D SDF between y0..y1 with rounded top (rtop) / bottom (rbot) edges."""
    wx = d2 + rtop
    wy = y - y1 + rtop
    top = np.hypot(np.maximum(wx, 0), np.maximum(wy, 0)) + np.minimum(np.maximum(wx, wy), 0) - rtop
    wx = d2 + rbot
    wy = y0 - y + rbot
    bot = np.hypot(np.maximum(wx, 0), np.maximum(wy, 0)) + np.minimum(np.maximum(wx, wy), 0) - rbot
    return np.where(y > 0.5 * (y0 + y1), top, bot)


def sd_round_cone(px, py, pz, a, b, r1, r2, ysq=1.0):
    """Inigo Quilez round cone; ysq < 1 squashes it vertically about the axis."""
    ya = a[1] + (b[1] - a[1]) * 0.0
    py = ya + (py - ya) / ysq if ysq != 1.0 else py
    ba = np.array(b, float) - np.array(a, float)
    l2 = float(ba @ ba)
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pax, pay, paz = px - a[0], py - a[1], pz - a[2]
    y = pax * ba[0] + pay * ba[1] + paz * ba[2]
    z = y - l2
    qx, qy, qz = pax * l2 - ba[0] * y, pay * l2 - ba[1] * y, paz * l2 - ba[2] * y
    x2 = qx * qx + qy * qy + qz * qz
    y2 = y * y * l2
    z2 = z * z * l2
    k = math.copysign(1.0, rr) * rr * rr * x2
    d_mid = (np.sqrt(np.maximum(x2 * a2 * il2, 0)) + y * rr) * il2 - r1
    d_b = np.sqrt(x2 + z2) * il2 - r2
    d_a = np.sqrt(x2 + y2) * il2 - r1
    return np.where(np.sign(z) * a2 * z2 > k, d_b, np.where(np.sign(y) * a2 * y2 < k, d_a, d_mid))


# shape parameters (mm) -------------------------------------------------------
POD_C = (46.5, -12.5)                 # D-pad / face-button pod centres (|x|, z)
POD_R = 26.0
STICK_C = (23.0, 10.5)
BOSS_R = 19.5
GRIP_A, GRIP_RA = (54.5, 26.5, -8.0), 24.0
GRIP_B, GRIP_RB = (65.0, 13.0, 34.5), 13.0
SHOULDER = dict(cx=46.5, hx=14.5, z0=-45.5, z1=-22.0, y0=6.0, y1=48.6, r=4.0)


def body_sdf(x, y, z):
    ax = np.abs(x)
    # --- flat face deck (pods + bridge + centre tongue + stick rings), flat top at FACE_Y
    pod = np.hypot(ax - POD_C[0], z - POD_C[1]) - POD_R
    bridge = sd_rrect2(x, z, 0.0, -17.0, 44.0, 18.0, 6.0)          # z -35 .. +1
    tongue = sd_rrect2(x, z, 0.0, 6.0, 6.5, 8.5, 3.0)               # centre tongue to z=14.5
    rs = np.hypot(ax - STICK_C[0], z - STICK_C[1])                  # radius from stick axis
    boss2 = rs - BOSS_R
    deck2 = smin(smin(smin(pod, bridge, 6.0), tongue, 3.0), boss2, 2.0)
    # big sloped rounding on the bridge front-top edge (DUALSHOCK 2 print face)
    rtop = 3.5 + 5.5 * sat((-z - 24.0) / 8.0) * sat((36.0 - ax) / 5.0)
    deck = extrude(deck2, y, 20.0, FACE_Y, rtop, 7.0)
    # --- stick housings continue down as round lobes on the underside
    lobe = extrude(boss2, y, 15.0, 44.0, 3.0, 9.0)
    d = smin(deck, lobe, 2.0)
    # --- shoulder towers carrying L1/L2 on their front face
    s = SHOULDER
    sh2 = sd_rrect2(ax, z, s['cx'], 0.5 * (s['z0'] + s['z1']), s['hx'], 0.5 * (s['z1'] - s['z0']), 5.0)
    sh = extrude(sh2, y, s['y0'], s['y1'], s['r'], s['r'] + 1.5)
    d = smin(d, sh, 3.0)
    # --- grips (round cones, slightly squashed), blended in generously
    grip = sd_round_cone(ax, y, z, GRIP_A, GRIP_B, GRIP_RA, GRIP_RB, ysq=0.92)
    d = smin(d, grip, 7.0)
    # never above the flat face plane (the smooth unions would bulge it)
    d = np.maximum(d, y - FACE_Y)
    # raised round button pods (flat top POD_Y, crisp rim) over the face deck
    podp = extrude(pod + POD_INSET, y, 26.0, POD_Y, POD_RIM_R, 2.0)
    d = smin(d, podp, 0.5)
    # conical housing ring: face plane at RING_R1 sloping down to BOSS_Y at RING_R0
    # (keeps a 25 deg tilted cap clear while the ring reads as a raised bezel)
    slope = (FACE_Y - BOSS_Y) / (RING_R1 - RING_R0)
    h = BOSS_Y + np.maximum(rs - RING_R0, 0.0) * slope
    d = smax(d, (y - h) / math.sqrt(1 + slope * slope), 0.8)
    return d


def sdf_body_mesh(voxel=0.42):
    x0, x1 = -84.0, 84.0
    y0, y1 = -4.0, 55.0
    z0, z1 = -52.0, 52.0
    xs = np.arange(x0, x1 + voxel, voxel, dtype=np.float32)
    ys = np.arange(y0, y1 + voxel, voxel, dtype=np.float32)
    zs = np.arange(z0, z1 + voxel, voxel, dtype=np.float32)
    grid = np.empty((len(xs), len(ys), len(zs)), dtype=np.float32)
    X, Y = np.meshgrid(xs, ys, indexing='ij')
    X, Y = X[:, :, None], Y[:, :, None]
    step = 24
    for k in range(0, len(zs), step):
        Z = zs[None, None, k:k + step]
        grid[:, :, k:k + step] = body_sdf(X, Y, Z).astype(np.float32)
    g = openvdb.FloatGrid()
    g.background = 5.0
    g.copyFromArray(grid, tolerance=0.0)
    del grid
    pts, tris, quads = g.convertToPolygons(isovalue=0.0, adaptivity=0.0)
    pts = pts.astype(np.float64) * voxel + np.array([x0, y0, z0])
    tris = np.asarray(tris, dtype=np.int64).reshape(-1, 3)
    quads = np.asarray(quads, dtype=np.int64).reshape(-1, 4)
    me = bpy.data.meshes.new('DS2_BODY_raw')
    me.vertices.add(len(pts))
    me.vertices.foreach_set('co', (pts * MM).astype(np.float32).ravel())
    corners = np.concatenate([quads.ravel(), tris.ravel()])
    starts = np.concatenate([np.arange(len(quads)) * 4, len(quads) * 4 + np.arange(len(tris)) * 3])
    me.loops.add(len(corners))
    me.loops.foreach_set('vertex_index', corners.astype(np.int32))
    me.polygons.add(len(starts))
    me.polygons.foreach_set('loop_start', starts.astype(np.int32))
    me.update(calc_edges=True)
    me.validate()
    return me


# ============================================================ materials
def build_materials():
    material('DS2_Body', '#141416', rough=0.45)        # contract #1C1C1E, a touch darker so it reads black (satin)
    material('DS2_ButtonCap', 'button_cap', rough=0.18)
    material('DS2_DPad', 'dpad', rough=0.4)
    material('DS2_StickRubber', 'stick_cap', rough=0.85)
    material('DS2_StickShaft', '#18181A', rough=0.45)
    material('DS2_Shoulder', '#1A1A1C', rough=0.35)
    material('DS2_SmallButton', '#232326', rough=0.35)
    material('DS2_SymTriangle', 'symbol_triangle', rough=0.35)
    material('DS2_SymCircle', 'symbol_circle', rough=0.35)
    material('DS2_SymCross', 'symbol_cross', rough=0.35)
    material('DS2_SymSquare', 'symbol_square', rough=0.35)
    material('LED_ANALOG_off', 'led_off', rough=0.25)
    material('DS2_PrintGray', 'print_gray', rough=0.5)
    material('DS2_PrintBlue', 'print_dualshock2_blue', rough=0.5)
    material('DS2_Cable', 'cable', rough=0.6)
    material('DS2_Plug', 'plug', rough=0.5)
    material('DS2_PlugDark', '#070708', rough=0.7)
    material('DS2_Ferrite', 'ferrite', rough=0.55)
    material('DS2_Emboss', '#1A1A1C', rough=0.4)       # molded D-pad arrows
    material('DS2_Seam', '#060607', rough=0.8)         # top/bottom shell parting line
    material('DS2_Screw', '#3A3A3D', rough=0.35, metal=0.7)


# ============================================================ body
def build_body(root):
    me = sdf_body_mesh()
    me.name = 'DS2_BODY'
    me.materials.append(MATS['DS2_Body'])
    body = bpy.data.objects.new('DS2_BODY', me)
    bpy.context.scene.collection.objects.link(body)
    body.parent = root
    body.matrix_parent_inverse = Matrix.Identity(4)
    print(f'[ds2] SDF body raw tris: {C.triangle_count(body)}')
    dec = body.modifiers.new('Decimate', 'DECIMATE')
    dec.decimate_type = 'COLLAPSE'
    dec.use_symmetry = False
    dec.symmetry_axis = 'X'
    dec.ratio = min(1.0, BODY_TRIS / max(1, C.triangle_count(body)))
    C.apply_all(body)
    print(f'[ds2] body after decimate: {C.triangle_count(body)} tris')
    # snap: bottom exactly on the table, report bbox
    co = np.array([v.co[:] for v in body.data.vertices])
    lo, hi = co.min(0), co.max(0)
    print(f'[ds2] body bbox mm lo={np.round(lo / MM, 2)} hi={np.round(hi / MM, 2)}')
    body.data.transform(Matrix.Translation((-(lo[0] + hi[0]) / 2, -lo[1], 0.0)))
    cut_body(body)
    smooth_object(body, 40.0)
    return body


# (x, z, head radius, recess depth) read off dualshock2_rear_solomon203.jpg (bottom view,
# mirrored to the top-view frame): 2 on the centre panel, 2 at the shoulder towers, 2 at
# the grip ends (iFixit: six bottom screws)
SCREW_SPOTS = [(5.3, -29.0, 2.0, 1.2), (-4.6, 7.0, 2.0, 1.2),
               (-54.0, -27.0, 2.3, 4.0), (54.0, -27.0, 2.3, 4.0),
               (-68.0, 33.0, 2.3, 4.0), (68.0, 33.0, 2.3, 4.0)]
SCREWS = []


def cutter(name, build):
    bm = bmesh.new()
    build(bm)
    return make_object(name, bm, [MATS['DS2_Body']], None)


def cut_body(body):
    cuts = []
    dp = L['dpad']['center_mm']
    fc = L['face_cluster_center_mm']
    # cross wells (crisp, floor WELL_FLOOR)
    ex, ez = L['dpad']['well_size_mm'][0] / 2, L['dpad']['well_size_mm'][1] / 2
    cuts.append(cutter('cut_dpad_well', lambda bm: add_prism(
        bm, cross_poly(dp[0], dp[2], ex, ez, 7.2, 1.2, 1.6), WELL_FLOOR, 60)))
    ex, ez = L['face_well_size_mm'][0] / 2, L['face_well_size_mm'][1] / 2
    cuts.append(cutter('cut_face_well', lambda bm: add_prism(
        bm, cross_poly(fc[0], fc[2], ex, ez, 7.8, 1.2, 1.6), WELL_FLOOR, 60)))
    # D-pad pocket: D-pad outline + 0.6 mm, deep enough for a 5 deg tilt
    # D-pad: four pad-shaped holes through the well floor into a hidden hub cavity
    cuts.append(cutter('cut_dpad_hub', lambda bm: add_cyl_y(bm, dp[0], dp[2], DPAD_VOID_R, 45.3, DPAD_VOID_TOP, 48)))
    for i in range(4):
        cuts.append(cutter(f'cut_dpad_pad{i}', lambda bm, i=i: add_prism(
            bm, dpad_pad_poly(i, 0.5), 47.8, 60)))
    # face button holes
    for key in ('btn_triangle', 'btn_circle', 'btn_cross', 'btn_square'):
        c = L[key]['center_mm']
        r = L[key]['diameter_mm'] / 2 + GAP
        cuts.append(cutter('cut_' + key, lambda bm, c=c, r=r: add_cyl_y(bm, c[0], c[2], r, 45.0, 60.0, 48)))
    # SELECT / START / ANALOG pockets
    sel = L['btn_select']
    cuts.append(cutter('cut_select', lambda bm: add_prism(
        bm, rrect(sel['center_mm'][0], sel['center_mm'][2], sel['size_mm'][0] + 2 * GAP,
                  sel['size_mm'][2] + 2 * GAP, 1.0), 48.5, 60)))
    st = L['btn_start']
    cuts.append(cutter('cut_start', lambda bm: add_prism(bm, start_poly(GAP), 48.5, 60)))
    an = L['btn_analog']
    cuts.append(cutter('cut_analog', lambda bm: add_prism(
        bm, rrect(an['center_mm'][0], an['center_mm'][2], an['size_mm'][0] + 2 * GAP,
                  an['size_mm'][2] + 2 * GAP, 0.8), 48.5, 60)))
    led = L['led_analog']
    cuts.append(cutter('cut_led', lambda bm: add_prism(
        bm, rrect(led['center_mm'][0], led['center_mm'][2], led['size_mm'][0] + 0.8,
                  led['size_mm'][2] + 0.8, 0.4), 50.5, 60)))
    # stick openings (with a chamfered lip), cavity for the pivot ball
    for key in ('stick_l', 'stick_r'):
        c = L[key]['center_mm']
        cuts.append(cutter('cut_' + key, lambda bm, c=c: add_lathe(
            bm, [(0, 60), (12.2, 60), (12.2, BOSS_Y + 0.2), (11.0, BOSS_Y - 1.0),
                 (11.0, 31.5), (0, 31.5)], (c[0], 0, c[2]), 56)))
    # shoulder button slots
    for key in ('l1', 'r1'):
        c = L[key]['center_mm']
        sx, sy = L[key]['size_mm'][0], L[key]['size_mm'][1]
        back = c[2] + L[key]['size_mm'][2] / 2 + TR['shoulder_l1r1_mm'] + 1.0
        cuts.append(cutter('cut_' + key, lambda bm, c=c, sx=sx, sy=sy, back=back: add_box(
            bm, (c[0], c[1], 0.5 * (back - 60)), (sx + 0.8, sy + 0.8, back + 60), 0.6)))
    for key in ('l2', 'r2'):
        c = L[key]['center_mm']
        sx, sy = L[key]['size_mm'][0], L[key]['size_mm'][1]
        y0, y1 = c[1] - sy / 2 - 1.2, c[1] + sy / 2 + 1.2
        back = -35.5
        cuts.append(cutter('cut_' + key, lambda bm, c=c, sx=sx, y0=y0, y1=y1, back=back: add_box(
            bm, (c[0], 0.5 * (y0 + y1), 0.5 * (back - 60)), (sx + 0.8, y1 - y0, back + 60), 0.6)))
    # six bottom screws (rear photo): recesses in the underside
    surf = Surface(body)
    SCREWS.clear()
    for x, z, r, depth in SCREW_SPOTS:
        hit = surf.tree.ray_cast(Vector((x, -30.0, z)), Vector((0, 1, 0)), 80.0)[0]
        if hit is None:
            print(f'[ds2] screw at ({x}, {z}) missed the body, skipped')
            continue
        SCREWS.append((x, hit.y + depth, z, r))
        cuts.append(cutter(f'cut_screw_{len(SCREWS)}', lambda bm, x=x, z=z, r=r, y=hit.y, d=depth:
                           add_cyl_y(bm, x, z, r + 0.5, y - 4.0, y + d, 24)))
    for cobj in cuts:
        C.boolean(body, cobj)
    body.data.update()


def start_poly(grow=0.0):
    """START: triangle pointing +X. `grow` offsets every edge outward by that many mm
    (exact: scale about the incentre by (r_in + grow) / r_in), corners rounded."""
    st = L['btn_start']
    cx, cz = st['center_mm'][0], st['center_mm'][2]
    hx, hz = st['size_mm'][0] / 2, st['size_mm'][2] / 2
    P = [np.array(p) for p in ((cx - hx, cz - hz), (cx + hx, cz), (cx - hx, cz + hz))]
    a, b, c = (np.linalg.norm(P[1] - P[2]), np.linalg.norm(P[2] - P[0]), np.linalg.norm(P[0] - P[1]))
    inc = (a * P[0] + b * P[1] + c * P[2]) / (a + b + c)
    area = 0.5 * abs(np.cross(P[1] - P[0], P[2] - P[0]))
    r_in = 2 * area / (a + b + c)
    k = (r_in + grow) / r_in
    pts = [tuple(inc + (p - inc) * k) for p in P]
    return round_poly(pts, 0.7 + grow, 3)


# ============================================================ moving parts
DPAD_VOID_R, DPAD_VOID_TOP = 9.0, 48.95   # hidden cavity for the rocker hub under the well floor


def dpad_pad_poly(i, grow=0.0):
    """Outline of directional pad i (0:+X, 1:+Z, 2:-X, 3:-Z): a flat pad with a pointed
    inner tip; `grow` = clearance offset (approximate, corners re-rounded)."""
    d = L['dpad']
    c = d['center_mm']
    w, e = d['arm_width_mm'] / 2 - 0.35 + grow, d['size_mm'][0] / 2 - 0.3 + grow
    a = math.radians(90 * i)
    dx, dz = math.cos(a), math.sin(a)
    tip = 3.2 - grow * 1.6
    loc = [(e, w), (e, -w), (5.6, -w), (tip, 0.0), (5.6, w)]
    pts = [(c[0] + dx * u - dz * v, c[2] + dz * u + dx * v) for u, v in loc]
    return round_poly(pts, [0.9 + grow, 0.9 + grow, 0.6 + grow, 0.4 + grow, 0.6 + grow], 2)


def build_dpad(root):
    """One rocker node: four separate-looking arrow pads joined by a hub that is hidden
    in a cavity under the shell (the pads rise through their own holes)."""
    d = L['dpad']
    c, piv = d['center_mm'], d['pivot_mm']
    top = c[1]
    bm = bmesh.new()
    for i in range(4):
        add_prism(bm, dpad_pad_poly(i), 49.4, top, 0, 0.5, 2)
        a = math.radians(90 * i)
        dx, dz = math.cos(a), math.sin(a)
        stem = [(5.0, 2.3), (5.0, -2.3), (7.9, -2.3), (7.9, 2.3)]
        add_prism(bm, [(c[0] + dx * u - dz * v, c[2] + dz * u + dx * v) for u, v in stem], 46.8, 49.6, 0)
    add_cyl_y(bm, c[0], c[2], 7.5, 46.3, 47.9, 32, 0)
    return make_object('DPAD', bm, [MATS['DS2_DPad']], root, piv)


SYM_SVG = {'btn_triangle': ('TRIANGLE.svg', 6.2), 'btn_circle': ('CIRCLE.svg', 5.7),
           'btn_cross': ('CROSS.svg', 5.5), 'btn_square': ('SQUARE.svg', 5.1)}


def build_face_buttons(root):
    names = {'btn_triangle': ('BTN_TRIANGLE', 'DS2_SymTriangle'),
             'btn_circle': ('BTN_CIRCLE', 'DS2_SymCircle'),
             'btn_cross': ('BTN_CROSS', 'DS2_SymCross'),
             'btn_square': ('BTN_SQUARE', 'DS2_SymSquare')}
    out = []
    for key, (node, sym) in names.items():
        b = L[key]
        c = b['center_mm']
        r = b['diameter_mm'] / 2
        top = c[1]
        bm = bmesh.new()
        prof = [(0, top), (3.4, top - 0.04), (4.6, top - 0.12), (5.05, top - 0.35),
                (r, top - 0.8), (r, 47.5), (0, 47.5)]
        add_lathe(bm, [(pr, py) for pr, py in prof], (c[0], 0, c[2]), 40, mat_fn=lambda y: 0)
        fname, width = SYM_SVG[key]
        sbm = svg_bm(fname, res=4)
        place_bm(sbm, (c[0], top, c[2]), (1, 0, 0), (0, 0, -1), (0, 1, 0), width, None, 0.15, 0.05)
        merge_bm(bm, sbm, 1)
        out.append(make_object(node, bm, [MATS['DS2_ButtonCap'], MATS[sym]], root, c))
    return out


def build_small_buttons(root):
    sel, st, an = L['btn_select'], L['btn_start'], L['btn_analog']
    bm = bmesh.new()
    add_prism(bm, rrect(sel['center_mm'][0], sel['center_mm'][2], sel['size_mm'][0], sel['size_mm'][2], 0.9),
              50.0, sel['center_mm'][1], 0, 0.4, 2)
    make_object('BTN_SELECT', bm, [MATS['DS2_SmallButton']], root, sel['center_mm'])
    bm = bmesh.new()
    add_prism(bm, start_poly(0.0), 50.0, st['center_mm'][1], 0, 0.4, 2)
    make_object('BTN_START', bm, [MATS['DS2_SmallButton']], root, st['center_mm'])
    bm = bmesh.new()
    add_prism(bm, rrect(an['center_mm'][0], an['center_mm'][2], an['size_mm'][0], an['size_mm'][2], 0.7),
              50.0, an['center_mm'][1], 0, 0.3, 2)
    make_object('BTN_ANALOG', bm, [MATS['DS2_SmallButton']], root, an['center_mm'])
    led = L['led_analog']
    bm = bmesh.new()
    add_prism(bm, rrect(led['center_mm'][0], led['center_mm'][2], led['size_mm'][0], led['size_mm'][2], 0.5),
              50.6, led['center_mm'][1], 0, 0.2, 1)
    make_object('LED_ANALOG', bm, [MATS['LED_ANALOG_off']], root, led['center_mm'])


def build_sticks(root):
    for key, node in (('stick_l', 'STICK_L'), ('stick_r', 'STICK_R')):
        s = L[key]
        piv = s['pivot_mm']
        top = s['center_mm'][1] - piv[1]          # 18 mm above the pivot
        R = s['cap_diameter_mm'] / 2
        t = s['cap_thickness_mm']
        ball = 9.5
        neck = 6.5
        yj = math.sqrt(ball * ball - neck * neck)
        prof = [(0, top - 1.0), (3.5, top - 0.9), (6.8, top - 0.55), (8.6, top - 0.15),
                (9.5, top), (10.35, top - 0.12), (10.95, top - 0.55), (R, top - 1.3),
                (R, top - t + 0.8), (R - 0.35, top - t + 0.15), (R - 1.2, top - t),
                (neck + 0.8, top - t), (neck, top - t - 0.6)]
        prof.append((neck, yj + 0.01))
        for i in range(1, 12):
            phi = math.asin(neck / ball) + (math.pi - math.asin(neck / ball)) * i / 12
            prof.append((ball * math.sin(phi), ball * math.cos(phi)))
        prof.append((0, -ball))
        cap_y = top - t - 0.3
        bm = bmesh.new()
        add_lathe(bm, [(r, y + piv[1]) for r, y in prof], (piv[0], 0, piv[2]), 32,
                  mat_fn=lambda y, cap_y=cap_y + piv[1]: 0 if y > cap_y else 1)
        make_object(node, bm, [MATS['DS2_StickRubber'], MATS['DS2_StickShaft']], root, piv)


def add_prism_x(bm, poly_zy, x0, x1, mat=0, bevel=0.0, segs=2):
    """Prism along X from a (z, y) side profile; all edges bevelled."""
    tmp = bmesh.new()
    a = [tmp.verts.new((x0, y, z)) for z, y in poly_zy]
    b = [tmp.verts.new((x1, y, z)) for z, y in poly_zy]
    tmp.faces.new(a[::-1])
    tmp.faces.new(b)
    n = len(poly_zy)
    for i in range(n):
        j = (i + 1) % n
        tmp.faces.new((a[i], a[j], b[j], b[i]))
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    if bevel > 0:
        sharp = [e for e in tmp.edges if e.calc_face_angle(0.0) > math.radians(30)]
        bmesh.ops.bevel(tmp, geom=sharp, offset=bevel, segments=segs, profile=0.5,
                        affect='EDGES', clamp_overlap=True)
    for f in tmp.faces:
        f.material_index = mat
    me = bpy.data.meshes.new('_px')
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def build_shoulders(root):
    """L1/R1: slim buttons with a convex front. L2/R2: taller triggers with a concave
    front and a forward-curled lower lip (profiles from the reference photos)."""
    for key, node in (('l1', 'L1'), ('r1', 'R1')):
        s = L[key]
        c = s['center_mm']
        hx = s['size_mm'][0] / 2
        zb, zf = c[2] + s['size_mm'][2] / 2, c[2] - s['size_mm'][2] / 2       # back / front
        y0, y1 = c[1] - s['size_mm'][1] / 2, c[1] + s['size_mm'][1] / 2
        prof = [(zb, y0), (zb, y1), (zf + 0.7, y1), (zf + 0.25, y1 - 0.9), (zf, y1 - 2.6),
                (zf, y0 + 2.6), (zf + 0.25, y0 + 0.9), (zf + 0.7, y0)]
        mount = C.empty(node + '_MOUNT', root, mm(c), (-math.pi / 2, 0, 0))
        bm = bmesh.new()
        add_prism_x(bm, prof, c[0] - hx, c[0] + hx, 0, 0.7, 2)
        make_object(node, bm, [MATS['DS2_Shoulder']], mount, c, smooth_angle=50)
    for key, node in (('l2', 'L2'), ('r2', 'R2')):
        s = L[key]
        c = s['center_mm']
        hx = s['size_mm'][0] / 2
        zb, zf = c[2] + s['size_mm'][2] / 2, c[2] - s['size_mm'][2] / 2
        y0, y1 = c[1] - s['size_mm'][1] / 2, c[1] + s['size_mm'][1] / 2
        prof = [(zb, y0), (zb, y1), (zf + 0.5, y1), (zf + 0.2, y1 - 0.8), (zf + 0.75, y1 - 4.0),
                (zf + 1.0, c[1]), (zf + 0.8, y0 + 4.0), (zf + 0.2, y0 + 1.4), (zf, y0 + 0.5), (zf + 0.4, y0)]
        bm = bmesh.new()
        add_prism_x(bm, prof, c[0] - hx, c[0] + hx, 0, 0.7, 2)
        make_object(node, bm, [MATS['DS2_Shoulder']], root, s['hinge_mm'], smooth_angle=50)


# ============================================================ cable + plug
def catmull(points, per=8):
    P = [Vector(p) for p in points]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(per):
            t = k / per
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t))
    out.append(P[-2])
    return out


PLUG_DIR = Vector((0.30, 0.0, -1.0)).normalized()      # insertion direction (world)
PLUG_FACE = Vector((58.0, 7.0, -262.0))                  # insertion face centre (world mm)


def build_cable(root):
    ce = L['cable_exit']
    ex = Vector(ce['center_mm'])
    rad = ce['cable_diameter_mm'] / 2
    pl = L['plug']
    plug_len = pl['body_size_mm'][2] + pl['lip_size_mm'][2]             # 38
    back = -PLUG_DIR
    plug_rear = PLUG_FACE + back * plug_len
    relief_end = plug_rear + back * pl['strain_relief_length_mm']
    fe = L['ferrite_core']
    fer_near = plug_rear + back * fe['distance_from_plug_rear_mm']
    fer_far = fer_near + back * fe['length_mm']
    bm = bmesh.new()
    # strain relief at the controller (tapered, ribbed), cable axis -Z
    sr = ce['strain_relief_diameter_mm'] / 2
    srl = ce['strain_relief_length_mm']
    prof = [(0, 4.0), (sr, 4.0), (sr, 0.0)]
    for k in range(4):                                  # tapered boot with four rings
        t0, t1 = srl * k / 4, srl * (k + 1) / 4
        rr = sr * (1.0 - 0.38 * (k + 0.5) / 4)
        prof += [(rr, -t0 - 0.3), (rr * 0.9, -t0 - 0.9), (rr * 0.9, -t1 + 0.3)]
    prof += [(sr * 0.6, -srl), (rad + 0.35, -srl - 1.5), (0, -srl - 1.5)]
    # lathe axis = local Y; +90 deg about X maps it to +Z, so profile y < 0 points out (-Z)
    add_lathe(bm, prof, (0, 0, 0), 20, mat_fn=lambda y: 0,
              axis_matrix=Matrix.Translation(ex) @ Matrix.Rotation(math.radians(90), 4, 'X'))
    # cable centreline: exit -> droop to the table -> up through the ferrite -> plug
    start = ex + Vector((0, 0, -srl - 1.0))
    on_table = fer_far + back * 22
    mids = [start, start + Vector((0, -1.5, -12)), Vector((2, 25, -76)), Vector((6, 7, -96)),
            Vector((10, rad + 0.3, -110)), Vector((on_table.x, rad + 0.3, on_table.z)),
            fer_far + back * 6, fer_far]
    path = catmull([p for p in mids], 7)
    path += [fer_far + (fer_near - fer_far) * (i / 4) for i in range(1, 5)]
    path += [fer_near + (relief_end - fer_near) * (i / 6) for i in range(1, 7)]
    path.append(relief_end + (plug_rear - relief_end) * 0.6)
    add_tube(bm, path, rad, 10, 0)
    # ferrite core (rounded cylinder along the cable)
    fer_axis = frame_matrix(PLUG_DIR) @ Matrix.Rotation(math.radians(90), 4, 'X')
    fr, fl = fe['diameter_mm'] / 2, fe['length_mm']
    prof = [(0, fl / 2), (fr - 2.0, fl / 2), (fr - 0.6, fl / 2 - 0.5), (fr, fl / 2 - 2.0),
            (fr, 1.0), (fr - 0.5, 0.5), (fr - 0.5, -0.5), (fr, -1.0),
            (fr, -fl / 2 + 2.0), (fr - 0.6, -fl / 2 + 0.5), (fr - 2.0, -fl / 2), (0, -fl / 2)]
    add_lathe(bm, prof, tuple((fer_near + fer_far) / 2), 24, mat_fn=lambda y: 1, axis_matrix=fer_axis)
    # plug-side strain relief
    srl2 = pl['strain_relief_length_mm']
    prof = [(0, 1.0), (4.6, 1.0), (4.6, -2.0), (3.6, -srl2 * 0.6), (rad + 0.4, -srl2), (0, -srl2)]
    add_lathe(bm, prof, tuple(plug_rear), 16, mat_fn=lambda y: 0, axis_matrix=fer_axis)
    return make_object('CABLE', bm, [MATS['DS2_Cable'], MATS['DS2_Ferrite']], root, tuple(ex))


def build_plug(root):
    pl = L['plug']
    bw, bh, bl = pl['body_size_mm']
    lw, lh, ll = pl['lip_size_mm']
    yaw = math.atan2(-PLUG_DIR.x, -PLUG_DIR.z)          # Ry(yaw) maps local -Z to PLUG_DIR
    mount = C.empty('CTRL_PLUG_MOUNT', root, mm(PLUG_FACE), (0, yaw, 0))
    bpy.context.view_layer.update()
    bm = bmesh.new()
    # built in the plug's LOCAL frame (origin = insertion face centre, -Z = insertion)
    add_box(bm, (0, 0, ll + bl / 2), (bw, bh, bl), 1.6, 0, 2)
    # grip ribs on both sides
    for sx in (-1, 1):
        for i in range(4):
            add_box(bm, (sx * (bw / 2 - 0.2), 0, ll + 5 + i * 2.2), (0.9, bh - 4.0, 1.0), 0.3, 0, 1)
    # lip with a raised collar step and three recessed windows
    add_box(bm, (0, 0, ll - 1.0), (lw + 1.0, lh + 1.0, 2.0), 0.6, 0, 1)
    lip = bmesh.new()
    add_box(lip, (0, 0, ll / 2), (lw, lh, ll), 1.0, 0, 2)
    me = bpy.data.meshes.new('_lip')
    lip.to_mesh(me)
    lip.free()
    lip_obj = bpy.data.objects.new('_lip', me)
    bpy.context.scene.collection.objects.link(lip_obj)
    win_w = (lw - 4 * 1.6) / 3
    for i in range(3):
        cx = -lw / 2 + 1.6 + win_w / 2 + i * (win_w + 1.6)
        wb = bmesh.new()
        add_box(wb, (cx, 0, 2.0), (win_w, lh - 2.6, 10.0), 0.4, 0, 1)
        wme = bpy.data.meshes.new('_win')
        wb.to_mesh(wme)
        wb.free()
        wobj = bpy.data.objects.new('_win', wme)
        bpy.context.scene.collection.objects.link(wobj)
        C.boolean(lip_obj, wobj)
    tmp = bmesh.new()
    tmp.from_mesh(lip_obj.data)
    for f in tmp.faces:  # window walls / floors dark
        c = f.calc_center_median()
        inner = c.z > 0.05 and abs(c.x) < lw / 2 - 0.3 and abs(c.y) < lh / 2 - 0.3
        f.material_index = 1 if inner else 0
    me2 = bpy.data.meshes.new('_lip2')
    tmp.to_mesh(me2)
    tmp.free()
    bm.from_mesh(me2)
    bpy.data.meshes.remove(me2)
    bpy.data.objects.remove(lip_obj, do_unlink=True)
    # the bmesh is in plug-local mm; express it in world mm for make_object
    M = mount.matrix_world.copy()
    M.translation = M.translation / MM
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    return make_object('CTRL_PLUG', bm, [MATS['DS2_Plug'], MATS['DS2_PlugDark']], mount, tuple(PLUG_FACE))


# ============================================================ prints
FONT_DIR = Path('/System/Library/Fonts/Supplemental')
LETTER_DZ = 2.5   # L/R moved 2.5 mm back from the layout point onto the flat tower top


def load_font(*names):
    for n in names:
        p = FONT_DIR / n
        if p.exists():
            try:
                return bpy.data.fonts.load(str(p), check_existing=True)
            except RuntimeError:
                continue
    return None


def text_bm(txt, font, size=1.0, spacing=1.0):
    cu = bpy.data.curves.new('_txt', 'FONT')
    cu.body = txt
    if font:
        cu.font = font
    cu.size = size
    cu.space_character = spacing
    cu.align_x = 'CENTER'
    cu.align_y = 'CENTER'
    cu.resolution_u = 2
    cu.extrude = 0.5
    ob = bpy.data.objects.new('_txt', cu)
    bpy.context.scene.collection.objects.link(ob)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    bm = bmesh.new()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)
    bpy.data.objects.remove(ob, do_unlink=True)
    bpy.data.curves.remove(cu)
    return bm


def place_bm(bm, center, right, up, normal, width=None, height=None, thick=0.08, proud=0.05,
             surf=None):
    """Scale a text/logo bmesh (XY letters, Z extrude +-0.5) to width/height mm and
    orient it on a surface: x->right, y->up, z->normal, top face `proud` mm above."""
    co = np.array([v.co[:] for v in bm.verts])
    lo, hi = co.min(0), co.max(0)
    mid = (lo + hi) / 2
    sx = width / (hi[0] - lo[0]) if width else None
    sy = height / (hi[1] - lo[1]) if height else None
    s = min(v for v in (sx, sy) if v is not None)
    N = Vector(normal).normalized()
    R = Vector(right)
    R = (R - N * R.dot(N)).normalized()
    U = N.cross(R).normalized()
    rot = Matrix((R, U, N)).transposed().to_4x4()
    zc = proud - thick / 2
    top_layer = {v: v.co.z > mid[2] for v in bm.verts}
    M = (Matrix.Translation(Vector(center) + N * zc) @ rot
         @ Matrix.Diagonal((s, s, thick / (hi[2] - lo[2]), 1.0)) @ Matrix.Translation(-Vector(mid)))
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    if surf is not None:  # drape every vertex onto the (curved) body surface along -N
        for v in bm.verts:
            loc = surf.tree.ray_cast(v.co + N * 4.0, -N, 8.0)[0]
            if loc is not None:
                v.co = loc + N * (proud if top_layer[v] else proud - thick)
    return bm


VEC_DIR = C.REPO / 'tools/ps2_blender/vectors'


def svg_bm(fname, keep=None, res=3):
    """Import a shared vector (tools/ps2_blender/vectors) as a filled, extruded bmesh in
    the text convention of text_bm: glyphs in XY (unit-ish size), Z from -0.5 to 0.5.
    keep: only curve objects whose name starts with one of these ids."""
    import addon_utils
    addon_utils.enable('io_curve_svg', default_set=False)
    objs0, mats0, cols0 = set(bpy.data.objects), set(bpy.data.materials), set(bpy.data.collections)
    curves0 = set(bpy.data.curves)
    bpy.ops.import_curve.svg(filepath=str(VEC_DIR / fname))
    new = [o for o in bpy.data.objects if o not in objs0]
    use = [o for o in new if o.type == 'CURVE' and (not keep or any(o.name.startswith(k) for k in keep))]
    for o in use:
        o.data.resolution_u = res
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    bm = bmesh.new()
    for o in use:
        me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
        me.transform(o.matrix_world)
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    for o in new:
        bpy.data.objects.remove(o, do_unlink=True)
    for c in set(bpy.data.curves) - curves0:
        bpy.data.curves.remove(c)
    for m in set(bpy.data.materials) - mats0:
        bpy.data.materials.remove(m)
    for c in set(bpy.data.collections) - cols0:
        bpy.data.collections.remove(c)
    if not bm.faces:
        raise RuntimeError(f'no filled geometry from {fname} {keep}')
    co = np.array([v.co[:] for v in bm.verts])
    span = float((co.max(0) - co.min(0))[:2].max())
    bmesh.ops.scale(bm, vec=(1 / span, 1 / span, 1.0), verts=bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    for v in bm.verts:
        v.co.z = -0.5
    ext = bmesh.ops.extrude_face_region(bm, geom=list(bm.faces))
    bmesh.ops.translate(bm, vec=(0, 0, 1.0), verts=[v for v in ext['geom'] if isinstance(v, bmesh.types.BMVert)])
    return bm


def merge_bm(dst, src, mat):
    for f in src.faces:
        f.material_index = mat
    me = bpy.data.meshes.new('_merge')
    src.to_mesh(me)
    src.free()
    dst.from_mesh(me)
    bpy.data.meshes.remove(me)


def seam_y(x, z):
    """Height of the top/bottom shell parting line: ~33 mm around the front and centre
    (between the L1 and L2 slots), following the grip axis down toward the grip ends."""
    ax = np.abs(x)
    grip_axis = np.clip(26.5 + (z + 8.0) * (-13.5 / 42.5), 13.0, 26.5)
    w = sat((ax - 40.0) / 8.0) * sat((z + 25.0) / 10.0)
    return 33.0 + (grip_axis - 33.0) * w


def build_seam(root, body):
    """Parting line as a thin dark band (0.36 mm) lying 0.03 mm over the shell."""
    me = body.data
    me.calc_loop_triangles()
    co = np.array([v.co[:] for v in me.vertices]) / MM
    tris = np.array([t.vertices[:] for t in me.loop_triangles])
    f = co[:, 1] - seam_y(co[:, 0], co[:, 2])
    fs = f[tris]
    cross = (fs.min(1) < 0) & (fs.max(1) > 0)
    dp = L['dpad']['center_mm']
    bm = bmesh.new()
    for t in tris[cross]:
        pts = []
        for i, j in ((0, 1), (1, 2), (2, 0)):
            a, b = t[i], t[j]
            if (f[a] < 0) != (f[b] < 0):
                u = f[a] / (f[a] - f[b])
                pts.append(co[a] + (co[b] - co[a]) * u)
        if len(pts) != 2:
            continue
        p, q = Vector(pts[0]), Vector(pts[1])
        n = (Vector(co[t[1]]) - Vector(co[t[0]])).cross(Vector(co[t[2]]) - Vector(co[t[0]]))
        if n.length < 1e-9 or (q - p).length < 1e-6:
            continue
        n.normalize()
        mid = (p + q) / 2
        near_stick = min(math.hypot(abs(mid.x) - STICK_C[0], mid.z - STICK_C[1]), 99) < 12.0
        if near_stick or n.y > 0.95 or n.y < -0.95:
            continue
        side = n.cross(q - p).normalized() * 0.18
        lift = n * 0.03
        vs = [bm.verts.new(p - side + lift), bm.verts.new(q - side + lift),
              bm.verts.new(q + side + lift), bm.verts.new(p + side + lift)]
        bm.faces.new(vs)
    return make_object('DS2_SEAM', bm, [MATS['DS2_Seam']], root)


def build_screws(root):
    bm = bmesh.new()
    for x, y, z, r in SCREWS:
        # head face points down (-Y); Phillips recess as two dark crossed slots
        add_lathe(bm, [(0, y), (r, y), (r, y - 0.9), (r - 0.4, y - 1.2), (0, y - 1.25)], (x, 0, z), 20,
                  mat_fn=lambda yy: 0)
        for ang in (0, 90):
            add_box(bm, (x, y - 1.2, z), (0.5 if ang else r * 1.25, 0.2, r * 1.25 if ang else 0.5), 0.0, 1)
    return make_object('DS2_SCREWS', bm, [MATS['DS2_Screw'], MATS['DS2_Seam']], root)


class Surface:
    def __init__(self, body):
        bpy.context.view_layer.update()
        mw = body.matrix_world
        verts = [(mw @ v.co) / MM for v in body.data.vertices]
        polys = [tuple(p.vertices) for p in body.data.polygons]
        self.tree = BVHTree.FromPolygons(verts, polys)

    def hit(self, origin, direction):
        loc, nrm, _, _ = self.tree.ray_cast(Vector(origin), Vector(direction).normalized(), 200)
        if loc is None:
            raise RuntimeError(f'print ray missed the body from {origin}')
        return loc, nrm


def build_prints(root, body):
    grp = C.empty('TRADEMARK_PRINTS', root)
    surf = Surface(body)
    serif = load_font('SuperClarendon.ttc', 'Georgia Bold.ttf', 'Times New Roman Bold.ttf')
    sans = load_font('Arial.ttf')
    sans_b = load_font('Arial Bold.ttf', 'Arial.ttf')
    gray, blue = MATS['DS2_PrintGray'], MATS['DS2_PrintBlue']
    TOP = ((1, 0, 0), (0, 0, -1))

    def top_print(name, key, bm, width_only=False, dz=0.0, mat=None):
        p = L[key]
        cx, _, cz = p['center_mm']
        cz += dz
        w, h = p['size_mm']
        loc, _ = surf.hit((cx, 70, cz), (0, -1, 0))
        place_bm(bm, loc, TOP[0], TOP[1], (0, 1, 0), w, None if width_only else h, surf=surf)
        return make_object(name, bm, [mat or gray], grp)

    # official outlines from tools/ps2_blender/vectors (see its README)
    top_print('PRINT_SONY', 'print_sony', svg_bm('SONY.svg', res=2))
    wordmark = ['path3003', 'path3005', 'path3007', 'path3009', 'path3011', 'path3013', 'path3015',
                'path3017', 'path3019', 'path3021', 'path3023', 'path3025']        # "PlayStation" only
    top_print('PRINT_PLAYSTATION', 'print_playstation',
              svg_bm('PlayStation2_logo_commons.svg', keep=wordmark, res=2), True)
    top_print('PRINT_PS_LOGO', 'print_ps_logo', svg_bm('PS.svg', res=4))
    # SELECT / START labels nudged 0.8 mm toward the shoulders (inside the +-1.5 mm photo
    # tolerance) so they sit on the flat face and not on the stick-ring slope
    top_print('PRINT_SELECT', 'print_select', svg_bm('SELECT.svg', res=2), True, -0.8)
    top_print('PRINT_START', 'print_start', svg_bm('START.svg', res=2), True, -0.8)
    # no vector exists for ANALOG: closest system font (Arial)
    top_print('PRINT_ANALOG', 'print_analog', text_bm('ANALOG', sans), True)

    # molded arrow marks at the ends of the D-pad cross well
    dp = L['dpad']['center_mm']
    for name, fname, (ux, uz) in (('PRINT_DPAD_UP', 'DPAD_UP.svg', (0, -1)), ('PRINT_DPAD_DOWN', 'DPAD_DOWN.svg', (0, 1)),
                                  ('PRINT_DPAD_LEFT', 'DPAD_LEFT.svg', (-1, 0)), ('PRINT_DPAD_RIGHT', 'DPAD_RIGHT.svg', (1, 0))):
        cx, cz = dp[0] + ux * 16.4, dp[2] + uz * 16.4
        loc, _ = surf.hit((cx, 70, cz), (0, -1, 0))
        bm = svg_bm(fname, res=1)
        horiz = ux != 0
        place_bm(bm, loc, TOP[0], TOP[1], (0, 1, 0), None if horiz else 3.4, 3.4 if horiz else None, 0.35, 0.2)
        make_object(name, bm, [MATS['DS2_Emboss']], grp)

    # "DUALSHOCK 2" in blue on the sloped front face, read from the front
    p = L['print_dualshock2']
    cx, cy, _ = p['center_mm']
    w, h = p['size_mm']
    loc, nrm = surf.hit((cx, cy, -80), (0, 0, 1))
    right = Vector((1, 0, 0))          # reads left-to-right from the player's side / top view
    up = nrm.cross(right).normalized()
    bm = text_bm('DUALSHOCK 2', sans_b, spacing=1.05)
    place_bm(bm, loc, right, up, nrm, w, h, surf=surf)
    make_object('PRINT_DUALSHOCK2', bm, [blue], grp)
    print(f'[ds2] DUALSHOCK 2 print at {tuple(round(v, 2) for v in loc)} normal {tuple(round(v, 2) for v in nrm)}')

    # shoulder letters on the tower tops
    sl = L['shoulder_letters']
    for name, fname, key in (('PRINT_L', 'L.svg', 'L_center_mm'), ('PRINT_R', 'R.svg', 'R_center_mm')):
        cx, cy, cz = sl[key]
        cz += LETTER_DZ
        loc, nrm = surf.hit((cx, 70, cz), (0, -1, 0))
        right = Vector((1, 0, 0))
        up = nrm.cross(right).normalized()
        bm = svg_bm(fname, res=3)
        place_bm(bm, loc, right, up, nrm, None, sl['height_mm'], surf=surf)
        make_object(name, bm, [gray], grp)
    return grp


# ============================================================ assembly
def build():
    C.reset_scene()
    build_materials()
    root = C.empty('DUALSHOCK2')
    body = build_body(root)
    build_dpad(root)
    build_face_buttons(root)
    build_small_buttons(root)
    build_sticks(root)
    build_shoulders(root)
    build_prints(root, body)
    build_seam(root, body)
    build_screws(root)
    build_cable(root)
    build_plug(root)
    bpy.context.view_layer.update()
    tris = C.triangle_count(C.descendants(root))
    print(f'[ds2] total triangles: {tris}')
    for o in sorted(C.descendants(root), key=lambda o: o.name):
        if o.type == 'MESH':
            print(f'    {o.name:22s} {C.triangle_count(o):6d}')
    return root


def main():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    root = build()
    C.export_usdz(root, OUT_USDZ)
    C.save_blend(OUT_BLEND)
    print(f'[ds2] exported {OUT_USDZ}')
    if '--render' in argv:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import render_dualshock2
        render_dualshock2.render_all(root, RENDER_DIR)


if __name__ == '__main__':
    main()
