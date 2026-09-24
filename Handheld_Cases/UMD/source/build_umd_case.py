"""US (NTSC-U) PSP UMD retail case, runtime model `PSP-UMD-Case` (root UMD_CASE).

Run from the repo root:
    Blender -b --factory-startup --python-exit-code 1 --python Handheld_Cases/UMD/source/build_umd_case.py

Contract: Handheld_Cases/CONTRACT.md. Reuses tools/ps2_blender/common.py and the helpers of
PS2_Disc_Case/source/build_dvd.py + build_case.py (imported, never edited).

Frame: metres, Y up, case closed and standing, front cover +Z, spine on -X. Root UMD_CASE =
bottom centre of the closed bbox: X [-52, 52], Y [0, 177], Z [-7.25, 7.25] mm (104 x 177 x 14.5,
portrait). Split plane Z = 0 (tray walls stop at -0.05, lid walls start at +0.05).

Clear polypropylene book case with a clear outer film (pocket) over a paper insert, double
living hinge like the PS2 Amaray case: back tray <-back hinge-> spine <-front hinge-> lid.
  back hinge  X -52, Z -7.25   (spine / back corner)
  front hinge X -52, Z +7.25   (spine / front corner)

Nodes
  UMD_CASE                        root empty
    CASE_TRAY                     empty: static back half
      TRAY_SHELL                  clear PP back half, 1.2 mm walls, cut spring-tongue slot
      UMD_CRADLE_RIM              raised rim around the UMD outline (measured from
                                  PSP-UMD-Shell.usdz, +0.4 mm play), finger scoops left/right,
                                  slots top/bottom
      UMD_CRADLE_TABS             two snap tabs (top/bottom) whose lips hang 1 mm over the UMD
      UMD_CRADLE_FLOOR            two support rails, centre locating boss on a spring tongue,
                                  tongue ribs
      TRAY_SNAP_NUBS              closure nubs on the free-edge wall (lid tabs hook under them)
      SLEEVE_BACK, COVER_ART_BACK, INSERT_REVERSE_BACK   film, insert back panel (outer face,
                                  runtime texture slot) and the insert's plain reverse side
      CASE_MEDIUM_ANCHOR          empty at the UMD centre (disc axis, mid-thickness), axes = case
                                  axes: +Z label normal (toward the lid), +Y UMD up (round end up)
    TRADEMARK_PRINTS              molded "UMD" text on the tray floor inside the cradle
    CASE_SPINE_HINGE              empty on the back hinge line, rotated pi about X
      CASE_SPINE                  identity rest; +rot_y opens (0 -> pi/2)
        SPINE_PANEL, SLEEVE_SPINE, COVER_ART_SPINE, INSERT_REVERSE_SPINE
        CASE_LID                  at local (0, 0, -14.5 mm); +rot_y opens (0 -> pi/2)
          LID_SHELL, LID_MANUAL_CLIP, LID_SNAP_TABS
          SLEEVE_FRONT, COVER_ART, INSERT_REVERSE_FRONT

Insert sheet (one image for COVER_ART + COVER_ART_SPINE + COVER_ART_BACK), 213 x 172 mm:
  back 99.5 | spine 14.0 | front 99.5; u_splits = [99.5/213, 113.5/213]; v = 0 bottom .. 1 top
  (insert Y 2.5 .. 174.5 mm). COVER_ART* are single outward-facing sheets (the app replaces all
  their materials with the texture); the insert's white reverse side is separate geometry
  (INSERT_REVERSE_*) so the open clear case shows plain paper, not mirrored cover art.

UMD placement: the app's UMD (PSP-UMD.usdz + PSP-UMD-Shell.usdz, metres) has its label face on
its own -Z, round end +Y, disc centre at its origin. Under CASE_MEDIUM_ANCHOR it goes with the
fixed local transform  R_y(pi), translation 0, scale 1  (label -Z -> +Z toward the lid, read
face with the steel hub down on the rails; the locating boss enters the 18 mm hub opening).

Self-check (printed as `self-check ...`, exit 1 on any hit): the four hinge corner poses
(tray / spine / lid pairwise), and the real UMD meshes at CASE_MEDIUM_ANCHOR against every
case mesh with the case closed.
"""
import importlib.util
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tools/ps2_blender'))
import common as C  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


D = _load('build_dvd', REPO / 'PS2_Disc_Case/source/build_dvd.py')      # geometry / render helpers
P = _load('build_case', REPO / 'PS2_Disc_Case/source/build_case.py')    # shell / collision helpers

MM = 0.001
ASSET_DIR = Path(__file__).resolve().parents[1]
UMD_FILE = REPO / 'DuoDS/Resources/PSP-UMD.usdz'
UMD_SHELL_FILE = REPO / 'DuoDS/Resources/PSP-UMD-Shell.usdz'

# ------------------------------------------------------------ dimensions (mm)
W, H, T = 104.0, 177.0, 14.5
X0, X1 = -W / 2, W / 2            # film outer spine face .. free edge
ZF = T / 2                        # film outer faces +-7.25
SLEEVE_T = 0.15
SLEEVE_OPEN_X = 51.1              # film pocket stops short of the free edge (insert slides in)
PL_X0 = X0 + 0.45                 # plastic spine outer face  -51.55
PL_Z = ZF - 0.45                  # plastic outer front/back faces 6.8
WALL = 1.2
SPLIT_GAP = 0.05
HALF_X0 = PL_X0 + WALL + 0.05     # tray/lid spine-side edge  -50.3
FLOOR_Z = -PL_Z + WALL            # tray floor top  -5.6
LID_FLOOR_Z = PL_Z - WALL         # lid floor (inside)  5.6
XWI = X1 - WALL                   # free-edge wall inner face  50.8

# insert (see REFERENCE_NOTES: wrap 213 = sleeve 8 3/8"; front/height = 0.579 median of scans)
INS_BACK, INS_SPINE, INS_FRONT, INS_H = 99.5, 14.0, 99.5, 172.0
INS_W = INS_BACK + INS_SPINE + INS_FRONT
U0 = INS_BACK / INS_W
U1 = (INS_BACK + INS_SPINE) / INS_W
INS_Y0 = (H - INS_H) / 2          # 2.5
INS_FREE_X = X0 + INS_FRONT       # 47.5: front / back panel free edge
ART_Z = PL_Z + 0.10               # outer face of the insert (6.9)
REV_Z = PL_Z + 0.05               # reverse (inner) face of the insert (6.85)
ART_SPINE_X = PL_X0 - 0.10
REV_SPINE_X = PL_X0 - 0.05

# hinges
BACK_HINGE = (X0, H / 2, -ZF)
FRONT_HINGE = (X0, H / 2, ZF)

# UMD cradle (anchor = UMD centre)
ANCHOR_XY = (0.0, 93.0)           # photo-scaled: rim 49 mm from the top, 120 mm from the top
RAIL_H_CLEAR = 0.05               # rail tops below the UMD read face
UMD_Z_READ = FLOOR_Z + 0.8        # UMD read face rests 0.8 mm above the floor (on the rails)
RIM_PLAY = 0.4                    # rim inner edge offset from the UMD outline
RIM_W = 2.4                       # rim wall width
RIM_TOP = -1.4                    # rim top (UMD label face sits 0.8 mm above it)
BOSS_R = 5.0
BOSS_INTO_HUB = 0.35              # boss top above the UMD read-face plane (inside the 18 mm hub hole)
RAIL_X = 15.0
MANUAL_CLIP = dict(x0=34.0, y=(H / 2 - 7.0, H / 2 + 7.0), z=(3.4, 4.2))
SNAP_Y = (17.0, 160.0)


def m(v):
    return v * MM


# ------------------------------------------------------------ UMD outline (measured)
def umd_measure():
    """Outline and thickness of the app's UMD shell in ANCHOR space (mm): UMD (x, y, z) ->
    (-x, y, -z), i.e. R_y(pi). Returns (convex hull CCW [(x, y)], z_min, z_max)."""
    from pxr import Usd, UsdGeom
    stage = Usd.Stage.Open(str(UMD_SHELL_FILE))
    pts = []
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            xf = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
            for p in UsdGeom.Mesh(prim).GetPointsAttr().Get():
                w = xf.Transform(p)
                pts.append((-w[0] / MM, w[1] / MM, -w[2] / MM))
    zs = [p[2] for p in pts]
    xy = sorted(set((round(x, 4), round(y, 4)) for x, y, _ in pts))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in xy:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(xy):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return lo[:-1] + up[:-1], min(zs), max(zs)


def resample(poly, n):
    """Closed polygon resampled to n points evenly spaced by arc length."""
    segs = [(poly[i], poly[(i + 1) % len(poly)]) for i in range(len(poly))]
    lens = [math.dist(a, b) for a, b in segs]
    total = sum(lens)
    out, acc, k = [], 0.0, 0
    for i in range(n):
        s = total * i / n
        while acc + lens[k] < s:
            acc += lens[k]
            k += 1
        t = (s - acc) / lens[k] if lens[k] else 0
        (ax, ay), (bx, by) = segs[k]
        out.append((ax + (bx - ax) * t, ay + (by - ay) * t))
    return out


def offset(poly, d):
    """Offset a CCW convex polygon outward by d (vertex normals from neighbour chords)."""
    n = len(poly)
    out = []
    for i in range(n):
        (px, py), (nx_, ny_) = poly[i - 1], poly[(i + 1) % n]
        tx, ty = nx_ - px, ny_ - py
        ln = math.hypot(tx, ty)
        out.append((poly[i][0] + ty / ln * d, poly[i][1] - tx / ln * d))
    return out


def add_ring(bm, inner, outer, z0, z1):
    """Closed wall between two matching loops (metres, XY), extruded z0..z1."""
    n = len(inner)
    ib = [bm.verts.new((x, y, z0)) for x, y in inner]
    ob = [bm.verts.new((x, y, z0)) for x, y in outer]
    it = [bm.verts.new((x, y, z1)) for x, y in inner]
    ot = [bm.verts.new((x, y, z1)) for x, y in outer]
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((it[i], ot[i], ot[j], it[j]))
        bm.faces.new((ib[i], ib[j], ob[j], ob[i]))
        bm.faces.new((ob[i], ob[j], ot[j], ot[i]))
        bm.faces.new((ib[i], it[i], it[j], ib[j]))


def sheet(name, corners, mat, uv_fn, parent=None):
    """Single one-sided quad (corners CCW as seen from the side it faces), metres."""
    bm = D.new_bm()
    bm.faces.new([bm.verts.new(c) for c in corners])
    return D.finish(name, bm, [mat], uv_fn=uv_fn, recalc=False, parent=parent)


# insert UV (closed-case world space, metres)
def uv_front(co):
    return (U1 + (co.x / MM - X0) / INS_W, (co.y / MM - INS_Y0) / INS_H)


def uv_back(co):
    return ((INS_FREE_X - co.x / MM) / INS_W, (co.y / MM - INS_Y0) / INS_H)


def uv_spine(co):
    return (U0 + (co.z / MM + INS_SPINE / 2) / INS_W, (co.y / MM - INS_Y0) / INS_H)


# ------------------------------------------------------------ build
def build(hull):
    plastic = C.mat('CASE_plastic_clear', C.hex_rgba('#C8DBE1'), rough=0.06, alpha=0.28)
    frosted = C.mat('CASE_emboss_frosted', C.hex_rgba('#E6EEF0'), rough=0.40, alpha=0.60)
    sleeve = C.mat('CASE_sleeve', C.hex_rgba('#FAFAFA'), rough=0.03, alpha=0.05)
    art = C.mat('COVER_ART_default', C.hex_rgba('#EDEDED'), rough=0.45)
    paper = C.mat('INSERT_paper_reverse', C.hex_rgba('#F2F1EB'), rough=0.65)

    root = C.empty('UMD_CASE')
    ax, ay = ANCHOR_XY
    az = UMD_Z_READ + UMD_HALF_T                      # anchor z: read face + half thickness

    # ================================================================ tray (static)
    tray = C.empty('CASE_TRAY', parent=root)
    # spring tongue: U-shaped slot through the floor around the locating boss
    slot_r, slot_w, slot_len = 7.0, 0.8, 16.0
    zc0, zc1 = -PL_Z - 0.5, FLOOR_Z + 0.5
    cutters = []
    for sx in (-1, 1):
        xa = ax + sx * slot_r
        cutters.append(P.box_obj('_SLOT_LEG', xa - slot_w / 2, xa + slot_w / 2, ay - slot_len, ay,
                                 zc0, zc1, []))
    bm = D.new_bm()
    D.add_arc(bm, m(ax), m(ay), m(slot_r - slot_w / 2), m(slot_r + slot_w / 2), 0.0, math.pi,
              m(zc0), m(zc1), n=16)
    cutters.append(D.finish('_SLOT_ARC', bm, []))
    obj = P.shell('TRAY_SHELL',
                  (HALF_X0, X1, 0, H, -PL_Z, -SPLIT_GAP, (0.3, 3.0, 3.0, 0.3)),
                  (PL_X0 - 1, XWI, WALL, H - WALL, FLOOR_Z, 1.0, (0, 1.7, 1.7, 0)),
                  [plastic], extra_cutters=cutters)
    C.set_parent(obj, tray)

    # cradle rim around the measured UMD outline
    base = resample(hull, 144)
    inner = [(ax + x, ay + y) for x, y in offset(base, RIM_PLAY)]
    outer = [(ax + x, ay + y) for x, y in offset(base, RIM_PLAY + RIM_W)]
    bm = D.new_bm()
    add_ring(bm, [(m(x), m(y)) for x, y in inner], [(m(x), m(y)) for x, y in outer],
             m(FLOOR_Z - 0.05), m(RIM_TOP))
    rim = D.finish('UMD_CRADLE_RIM', bm, [plastic], smooth_angle=35)
    top_y = max(y for _, y in hull)
    bot_y = min(y for _, y in hull)
    rim_cut = [P.box_obj('_RIM_SLOT', ax - 4.0, ax + 4.0, ay + top_y - 2, ay + top_y + 6,
                         FLOOR_Z - 1, 1.0, []),
               P.box_obj('_RIM_SLOT', ax - 4.0, ax + 4.0, ay + bot_y - 6, ay + bot_y + 2,
                         FLOOR_Z - 1, 1.0, [])]
    side_x = max(x for x, _ in hull) + RIM_PLAY + RIM_W / 2
    for sx in (-1, 1):                                # finger scoops (lens-shaped dips)
        rim_cut.append(C.cylinder('_RIM_SCOOP', m(16.0), m(8.0), verts=48,
                                  location=(m(ax + sx * side_x), m(ay), m(RIM_TOP - 3.0 + 16.0)),
                                  rotation=(0, math.pi / 2, 0)))
    for cut in rim_cut:
        C.boolean(rim, cut)
    C.bevel(rim, m(0.4), segments=2, angle_deg=40)
    C.set_parent(rim, tray)

    # snap tabs in the rim slots: flexible post + lip hanging 1 mm over the UMD edge
    lip_z0 = az + UMD_HALF_T + 0.15                   # 0.15 above the UMD label face
    bm = D.new_bm()
    for sy, edge in ((1, top_y), (-1, bot_y)):
        post = sorted((ay + edge + sy * (RIM_PLAY + 0.1), ay + edge + sy * (RIM_PLAY + 1.3)))
        lip = sorted((ay + edge - sy * 1.0, post[1] if sy > 0 else post[0]))
        D.add_box(bm, m(ax - 2.8), m(ax + 2.8), m(post[0]), m(post[1]), m(FLOOR_Z - 0.05),
                  m(lip_z0 + 0.55))
        D.add_box(bm, m(ax - 2.8), m(ax + 2.8), m(lip[0]), m(lip[1]), m(lip_z0), m(lip_z0 + 0.55))
    tabs = D.finish('UMD_CRADLE_TABS', bm, [plastic])
    C.bevel(tabs, m(0.15), segments=1, angle_deg=40)
    C.set_parent(tabs, tray)

    # floor: two support rails, locating boss on the tongue, tongue ribs
    rail_top = UMD_Z_READ - RAIL_H_CLEAR
    bm = D.new_bm()
    for sx in (-1, 1):
        D.add_box(bm, m(ax + sx * RAIL_X - 0.7), m(ax + sx * RAIL_X + 0.7),
                  m(ay + bot_y + 2.0), m(ay + top_y - 1.5), m(FLOOR_Z - 0.05), m(rail_top))
    D.add_prism(bm, [(m(x), m(y)) for x, y in P.circle(ax, ay, BOSS_R, 32)],
                m(FLOOR_Z - 0.05), m(UMD_Z_READ + BOSS_INTO_HUB))
    for r in (8.0, 10.0, 12.0):
        D.add_arc(bm, m(ax), m(ay), m(r), m(r + 0.6), math.radians(245), math.radians(295),
                  m(FLOOR_Z - 0.05), m(FLOOR_Z + 0.3), n=6)
    floor = D.finish('UMD_CRADLE_FLOOR', bm, [plastic], smooth_angle=35)
    C.bevel(floor, m(0.2), segments=2, angle_deg=40)
    C.set_parent(floor, tray)

    # closure nubs on the free-edge wall (the lid's snap tabs hook under them)
    bm = D.new_bm()
    for y in SNAP_Y:
        D.add_box(bm, m(XWI - 0.5), m(XWI + 0.1), m(y - 3.0), m(y + 3.0), m(-3.8), m(-2.8))
    D.finish('TRAY_SNAP_NUBS', bm, [plastic], parent=tray)

    # molded "UMD" text on the floor inside the cradle (a Sony trademark -> TRADEMARK_PRINTS)
    prints_root = C.empty('TRADEMARK_PRINTS', parent=root)
    Me = D.basis((0, 0, m(FLOOR_Z + 0.12)), (1, 0, 0), (0, 1, 0))
    bm = D.new_bm()
    D.add_text(bm, 'UMD', m(ax), m(ay + 16.0), m(15.0), m(5.0), Me, res=2)
    D.finish('TRAY_UMD_EMBOSS', bm, [frosted], recalc=False, parent=prints_root)

    # film, insert back panel (outer face) and its reverse
    P.box_obj('SLEEVE_BACK', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2, -ZF, -ZF + SLEEVE_T, [sleeve],
              parent=tray)
    y0, y1 = m(INS_Y0), m(INS_Y0 + INS_H)
    xa, xb = m(PL_X0), m(INS_FREE_X)
    sheet('COVER_ART_BACK', [(xb, y0, -m(ART_Z)), (xa, y0, -m(ART_Z)), (xa, y1, -m(ART_Z)),
                             (xb, y1, -m(ART_Z))], art, uv_back, parent=tray)
    sheet('INSERT_REVERSE_BACK', [(xa, y0, -m(REV_Z)), (xb, y0, -m(REV_Z)), (xb, y1, -m(REV_Z)),
                                  (xa, y1, -m(REV_Z))], paper, uv_back, parent=tray)
    C.empty('CASE_MEDIUM_ANCHOR', parent=tray, location=(m(ax), m(ay), m(az)))

    # ================================================================ spine
    spine_hinge = C.empty('CASE_SPINE_HINGE', parent=root,
                          location=tuple(m(v) for v in BACK_HINGE), rotation=(math.pi, 0, 0))
    spine = C.empty('CASE_SPINE', parent=spine_hinge)
    panel = P.rplate('SPINE_PANEL', (PL_X0, PL_X0 + WALL, 0, H, -PL_Z, PL_Z, (1.0, 0, 0, 1.0)),
                     [plastic])
    C.bevel(panel, m(0.35), segments=2, angle_deg=40)
    spine_objs = [panel,
                  P.box_obj('SLEEVE_SPINE', X0, X0 + SLEEVE_T, 0.2, H - 0.2, -ZF + 0.2, ZF - 0.2,
                            [sleeve])]
    zs = m(INS_SPINE / 2 - 0.15)
    xs, xr = m(ART_SPINE_X), m(REV_SPINE_X)
    spine_objs.append(sheet('COVER_ART_SPINE', [(xs, y0, zs), (xs, y0, -zs), (xs, y1, -zs),
                                                (xs, y1, zs)], art, uv_spine))
    spine_objs.append(sheet('INSERT_REVERSE_SPINE', [(xr, y0, -zs), (xr, y0, zs), (xr, y1, zs),
                                                     (xr, y1, -zs)], paper, uv_spine))

    # ================================================================ lid
    lid = C.empty('CASE_LID', parent=spine, location=(0, 0, m(BACK_HINGE[2] - FRONT_HINGE[2])))
    lid_objs = [P.shell('LID_SHELL',
                        (HALF_X0, X1, 0, H, SPLIT_GAP, PL_Z, (0.3, 3.0, 3.0, 0.3)),
                        (PL_X0 - 1, XWI, WALL, H - WALL, -1.0, LID_FLOOR_Z, (0, 1.7, 1.7, 0)),
                        [plastic])]
    # manual clip: flat tongue from the free-edge wall, mid-height, with a raised grip pad
    mc = MANUAL_CLIP
    bm = D.new_bm()
    D.add_prism(bm, D.rrect(m(mc['x0']), m(XWI + 0.3), m(mc['y'][0]), m(mc['y'][1]),
                            (m(3.0), 0, 0, m(3.0)), segs=6), m(mc['z'][0]), m(mc['z'][1]))
    D.add_box(bm, m(mc['x0'] + 3.0), m(mc['x0'] + 13.0), m(H / 2 - 3.0), m(H / 2 + 3.0),
              m(mc['z'][0] - 0.3), m(mc['z'][0] + 0.05))
    clip = D.finish('LID_MANUAL_CLIP', bm, [plastic], smooth_angle=35)
    C.bevel(clip, m(0.2), segments=1, angle_deg=40)
    lid_objs.append(clip)
    # closure snap tabs hanging into the tray along its free-edge wall
    bm = D.new_bm()
    for y in SNAP_Y:
        D.add_box(bm, m(XWI - 1.4), m(XWI - 0.6), m(y - 2.6), m(y + 2.6), m(-4.6), m(LID_FLOOR_Z))
        D.add_box(bm, m(XWI - 1.4), m(XWI - 0.15), m(y - 2.6), m(y + 2.6), m(-4.6), m(-4.0))
    lid_objs.append(D.finish('LID_SNAP_TABS', bm, [plastic]))
    lid_objs.append(P.box_obj('SLEEVE_FRONT', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2,
                              ZF - SLEEVE_T, ZF, [sleeve]))
    lid_objs.append(sheet('COVER_ART', [(xa, y0, m(ART_Z)), (xb, y0, m(ART_Z)), (xb, y1, m(ART_Z)),
                                        (xa, y1, m(ART_Z))], art, uv_front))
    lid_objs.append(sheet('INSERT_REVERSE_FRONT', [(xb, y0, m(REV_Z)), (xa, y0, m(REV_Z)),
                                                   (xa, y1, m(REV_Z)), (xb, y1, m(REV_Z))],
                          paper, uv_front))

    for o in spine_objs:
        P.bake_into(o, spine)
    for o in lid_objs:
        P.bake_into(o, lid)
    return root


# ------------------------------------------------------------ UMD (render / check only)
def import_umd(anchor):
    """Real app UMD (shell + PSP-UMD.usdz meshes) under a preview empty at the anchor with the
    documented fixed transform R_y(pi). Curves (vector lettering) and the duplicate shell of
    PSP-UMD.usdz are dropped. Returns the preview empty."""
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(UMD_SHELL_FILE))
    shell_objs = set(bpy.data.objects) - before
    mid = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(UMD_FILE))
    umd_objs = set(bpy.data.objects) - mid
    for o in list(umd_objs):
        if o.type == 'CURVES' or o.type == 'CURVE' or o.name.startswith('White_shell'):
            umd_objs.discard(o)
            bpy.data.objects.remove(o, do_unlink=True)
    new = shell_objs | umd_objs
    for o in [o for o in new if o.type not in {'MESH', 'EMPTY'}]:   # lights etc.
        new.discard(o)
        bpy.data.objects.remove(o, do_unlink=True)
    while True:                                       # drop empties left without children
        bare = [o for o in new if o.type == 'EMPTY' and not o.children]
        if not bare:
            break
        for o in bare:
            new.discard(o)
            bpy.data.objects.remove(o, do_unlink=True)
    holder = C.empty('UMD_PREVIEW', parent=anchor, rotation=(0, math.pi, 0))
    bpy.context.view_layer.update()
    for o in new:
        if o.parent is None:
            basis = o.matrix_basis.copy()
            o.parent = holder
            o.matrix_parent_inverse = Matrix.Identity(4)
            o.matrix_basis = basis
    return holder


# ------------------------------------------------------------ outputs
def write_contract(az):
    ax, ay = ANCHOR_XY
    data = {
        'asset': 'PSP-UMD-Case',
        'root': 'UMD_CASE',
        'runtime_file': 'DuoDS/Resources/PSP-UMD-Case.usdz',
        'units': 'metres (values below in mm)',
        'size_mm': [W, H, T],
        'bbox_mm': {'x': [X0, X1], 'y': [0.0, H], 'z': [-ZF, ZF]},
        'insert_mm': {'back': INS_BACK, 'spine': INS_SPINE, 'front': INS_FRONT, 'height': INS_H},
        'u_splits': [round(U0, 6), round(U1, 6)],
        'insert_y_mm': [INS_Y0, INS_Y0 + INS_H],
        'hinges_mm': {'back': list(BACK_HINGE), 'front': list(FRONT_HINGE)},
        'motions': [{'node': 'CASE_SPINE', 'axis': 'rot_y', 'range_rad': [0, math.pi / 2]},
                    {'node': 'CASE_LID', 'axis': 'rot_y', 'range_rad': [0, math.pi / 2]}],
        'medium_anchor': {
            'node': 'CASE_MEDIUM_ANCHOR', 'parent': 'CASE_TRAY',
            'position_mm': [ax, ay, round(az, 3)], 'rotation': 'identity (axes = case axes)',
            'axes': {'+Z': 'UMD label face normal, toward the lid',
                     '+Y': 'UMD up: round (disc-arc) end up, flat end with the corners down',
                     '+X': 'toward the case free edge; the UMD read window lies on +X'},
            'umd_to_anchor': {'files': ['DuoDS/Resources/PSP-UMD.usdz',
                                        'DuoDS/Resources/PSP-UMD-Shell.usdz'],
                              'rotation_euler_xyz_rad': [0, math.pi, 0],
                              'translation_mm': [0, 0, 0], 'scale': 1.0,
                              'note': 'UMD model: label face -Z, round end +Y, disc centre at '
                                      'origin; set the UMD root local transform under the anchor '
                                      'to R_y(pi) (SceneKit eulerAngles.y = pi), no scale'},
        },
        'trademark_groups': ['TRADEMARK_PRINTS'],
        'cover_art_nodes': ['COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK'],
    }
    (ASSET_DIR / 'contract.json').write_text(json.dumps(data, indent=1) + '\n')


def test_pattern(w_px=1278, h_px=1032):
    """Neutral UV test image in insert space: back blue | spine yellow | front green, 10 mm grid,
    red folds, a black diagonal and a 60 mm-radius circle centred on the spine; they must run on
    unbroken across back | spine | front. Letters B / F mark the panels' upper halves."""
    import numpy as np
    u = (np.arange(w_px) + 0.5) / w_px
    v = (np.arange(h_px) + 0.5) / h_px
    U, V = np.meshgrid(u, v)
    img = np.ones((h_px, w_px, 4), dtype=np.float32)
    img[..., :3] = (0.62, 0.75, 0.92)
    img[(U >= U0) & (U < U1), :3] = (0.95, 0.85, 0.45)
    img[U >= U1, :3] = (0.62, 0.90, 0.62)
    xm, ym = U * INS_W, V * INS_H
    px = INS_W / w_px
    grid = (np.abs((xm + 5) % 10 - 5) < px * 0.8) | (np.abs((ym + 5) % 10 - 5) < px * 0.8)
    img[grid, :3] *= 0.7
    for f in (U0, U1):
        img[np.abs(U - f) * INS_W < px * 1.2, :3] = (0.85, 0.1, 0.1)
    diag = np.abs(ym - xm * INS_H / INS_W) < px * 1.8
    ring = np.abs(np.hypot(xm - (INS_BACK + INS_SPINE / 2), ym - INS_H / 2) - 60.0) < px * 1.8
    img[diag | ring, :3] = 0.05
    # top band (v > 0.9) dark on both panels: shows which way is up
    img[(V > 0.93) & ((U < U0) | (U >= U1)), :3] = (0.2, 0.2, 0.25)
    im = bpy.data.images.new('UV_TEST_PATTERN', w_px, h_px)
    im.pixels.foreach_set(img.ravel())
    return im


def main():
    global UMD_HALF_T
    C.reset_scene()
    hull, zmin, zmax = umd_measure()
    UMD_HALF_T = (zmax - zmin) / 2
    xs = [x for x, _ in hull]
    ys = [y for _, y in hull]
    print(f'UMD shell (anchor frame): x {min(xs):.2f}..{max(xs):.2f}  y {min(ys):.2f}..{max(ys):.2f}'
          f'  z {zmin:.2f}..{zmax:.2f} mm, hull {len(hull)} pts')
    root = build(hull)
    tris = C.triangle_count(C.descendants(root))
    print(f'PSP-UMD-Case triangles: {tris}')
    C.export_usdz(root, ASSET_DIR / 'exports/PSP-UMD-Case.usdz')
    anchor = bpy.data.objects['CASE_MEDIUM_ANCHOR']
    write_contract(anchor.location.z / MM)

    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    half = math.pi / 2
    failed = tris > 40000
    for a, b in ((0, 0), (half, 0), (0, half), (half, half)):
        spine.rotation_euler[1], lid.rotation_euler[1] = a, b
        hits = P.group_collisions(root)
        failed |= bool(hits)
        print(f'self-check spine={a:.4f} lid={b:.4f}: collisions {hits or "none"}')
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0

    umd = import_umd(anchor)
    umd_meshes = [o for o in C.descendants(umd) if o.type == 'MESH']
    case_meshes = [o for g in P.case_groups(root).values() for o in g if o not in umd_meshes]
    hits = P.group_collisions(root, {'case': case_meshes, 'umd': umd_meshes})
    failed |= bool(hits)
    print(f'self-check UMD ({len(umd_meshes)} meshes) at CASE_MEDIUM_ANCHOR in closed case: '
          f'collisions {hits or "none"}')
    # the anchor must be exactly where the imported UMD's shell centre lands (+0.5 mm in Y: the
    # UMD origin is the disc centre, its shell bbox centre is 0.5 mm lower)
    bpy.context.view_layer.update()
    sh = [o for o in umd_meshes if o.name.startswith('White_shell')][0]
    ws = [sh.matrix_world @ v.co for v in sh.data.vertices]
    lo = [min(p[i] for p in ws) / MM for i in range(3)]
    hi = [max(p[i] for p in ws) / MM for i in range(3)]
    print('self-check UMD shell world bbox mm: ' +
          ' '.join(f'{a:.2f}..{b:.2f}' for a, b in zip(lo, hi)))
    if failed:
        print('self-check FAILED')
        sys.exit(1)
    print('self-check OK')

    # ---------------------------------------------------------------- renders
    sc = bpy.context.scene
    cam = D.setup_render(res=(1024, 1024), samples=48, world_rgb=(0.11, 0.115, 0.13))
    sc.cycles.transparent_max_bounces = 64
    sc.cycles.max_bounces = 16
    umd.hide_render = True
    for o in umd.children_recursive:
        o.hide_render = True
    D.area_light('KeyLight', (-0.2, 0.40, 0.45), (0, 0.088, 0), 0.4, 3.2)
    D.area_light('FillLight', (-0.40, 0.05, 0.05), (0, 0.088, 0), 0.5, 0.9)
    D.look_at(cam, (-0.22, 0.17, 0.33), (0.0, 0.086, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed.png')

    # open, UMD in the cradle
    for o in [umd, *umd.children_recursive]:
        o.hide_render = False
    spine.rotation_euler[1] = lid.rotation_euler[1] = half
    cx = (X1 + (X0 - T - W)) / 2 * MM
    D.area_light('KeyLight', (cx + 0.05, 0.25, 0.55), (cx, 0.088, 0), 0.6, 3)
    D.area_light('FillLight', (cx - 0.3, 0.05, 0.2), (cx, 0.088, 0), 0.5, 0.6)
    sc.render.resolution_x, sc.render.resolution_y = 1280, 1024
    D.look_at(cam, (cx, 0.03, 0.50), (cx, 0.086, -0.005))
    D.render(ASSET_DIR / 'renders/case_open_top.png')
    D.look_at(cam, (cx + 0.05, -0.10, 0.36), (cx + 0.004, 0.084, -0.005))
    D.render(ASSET_DIR / 'renders/case_open.png')
    # cradle close-up (compare with the reference photo)
    sc.render.resolution_x, sc.render.resolution_y = 1024, 1024
    D.look_at(cam, (0.05, 0.02, 0.17), (0.0, 0.09, -0.004))
    D.render(ASSET_DIR / 'renders/cradle_detail.png')
    for o in [umd, *umd.children_recursive]:
        o.hide_render = True
    D.render(ASSET_DIR / 'renders/cradle_empty.png')
    for o in [umd, *umd.children_recursive]:
        o.hide_render = False

    # UV proof: test pattern through the three insert meshes
    im = test_pattern()
    tm = bpy.data.materials.new('UV_TEST')
    tm.use_nodes = True
    nt = tm.node_tree
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = im
    nt.links.new(tex.outputs['Color'], nt.nodes['Principled BSDF'].inputs['Base Color'])
    arts = [bpy.data.objects[n] for n in ('COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK')]
    for o in arts:
        o.data.materials[0] = tm
    sc.render.resolution_x, sc.render.resolution_y = 1280, 1024
    D.area_light('UnderKey', (cx, 0.20, -0.6), (cx, 0.088, 0), 0.6, 3)
    D.look_at(cam, (cx, 0.088, -0.52), (cx, 0.088, 0.0))
    D.render(ASSET_DIR / 'renders/case_open_cover_outside.png')
    bpy.data.objects.remove(bpy.data.objects['UnderKey'], do_unlink=True)
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    for o in [umd, *umd.children_recursive]:
        o.hide_render = True
    sc.render.resolution_x, sc.render.resolution_y = 1024, 1024
    D.area_light('KeyLight', (-0.2, 0.40, 0.45), (0, 0.088, 0), 0.4, 3.2)
    D.area_light('FillLight', (-0.40, 0.05, 0.05), (0, 0.088, 0), 0.5, 0.9)
    D.look_at(cam, (-0.22, 0.17, 0.33), (0.0, 0.086, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed_cover.png')
    art_default = bpy.data.materials['COVER_ART_default']
    for o in arts:
        o.data.materials[0] = art_default
    for o in [umd, *umd.children_recursive]:
        o.hide_render = False
    bpy.data.materials.remove(tm)
    bpy.data.images.remove(im)
    C.save_blend(ASSET_DIR / 'PSP_UMD_Case.blend')


UMD_HALF_T = 2.1

if __name__ == '__main__':
    main()
