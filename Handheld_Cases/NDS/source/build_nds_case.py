"""US (NTSC-U) Nintendo DS retail game case, runtime model `NDS-Case`.

Run from the repo root:
    Blender -b --factory-startup --python-exit-code 1 \
        --python Handheld_Cases/NDS/source/build_nds_case.py

Contract: Handheld_Cases/CONTRACT.md. Frame identical to PS2-Case: metres, Y up, case
closed and standing, front cover +Z, spine on -X, root NDS_CASE = bottom-centre of the
bbox: X [-67.5, 67.5], Y [0, 122], Z [-7.25, 7.25] (135 x 122 x 14.5 mm, LANDSCAPE).
Split plane Z = 0: tray (back half) z < 0, lid (front half) z > 0.

Double living hinge like the PS2 keep case: tray <-back hinge-> spine <-front hinge-> lid.
Both hinge lines run along Y on the OUTER spine corners:
  back hinge  X -67.5, Z -7.25     front hinge X -67.5, Z +7.25
CASE_SPINE rot_y 0 -> pi/2 folds the spine flat to the -X side of the tray; CASE_LID
(child of CASE_SPINE) rot_y 0 -> pi/2 lays the lid flat beyond it. Fully open: tray |
spine | lid side by side, inner faces up, outer faces at Z = -7.25, X -217 .. 67.5.

Nodes
  NDS_CASE                          root empty
    CASE_TRAY                       empty: static back half
      TRAY_SHELL                    dark-grey PP back half; 2 latch windows in the floor
                                    at the free edge
      TRAY_RAILS                    spine-side wall, top/bottom inner rails, tall inner wall
                                    21 mm from the free edge, free-edge comb (thin wall + ribs)
      DS_CARD_HOLDER                raised square frame with sloped foot around the card pocket
                                    (pocket = measured card + play), 4 corner retaining nubs
                                    above the card, gap in the right wall for the push tab
      DS_PUSH_TAB                   push-release pad right of the pocket + triangle
      GBA_HOLDER                    U bracket (open toward the top edge) + 2 hooks + the two
                                    panel lines up to the top rail (Game Boy Advance Game Pak)
      SLEEVE_BACK, COVER_ART_BACK   clear film and insert back panel
      TRAY_HINGE_WEB                living-hinge strip
      CASE_MEDIUM_ANCHOR            empty: DS card body centre in the holder, identity
                                    rotation (+Z label normal -> lid, +Y card up, contacts -Y)
    TRADEMARK_PRINTS                molded "NINTENDO DS" plain text on the tray floor
    CASE_SPINE_HINGE                empty on the back hinge line, rotated pi about X
      CASE_SPINE                    identity rest; +rot_y opens
        SPINE_PANEL, SPINE_RIBS     spine wall + 2 lengthwise inner ribs
        SPINE_EMBOSS                PP "5" recycling mark (not a trademark)
        SLEEVE_SPINE, COVER_ART_SPINE
        CASE_LID                    at the front hinge line (local (0, 0, -14.5 mm)); +rot_y opens
          LID_SHELL                 front half; 2 through-holes under the manual clips
          LID_RAILS                 spine-side wall, top/bottom rails, free-edge rail + comb,
                                    2 latch hooks that drop into the tray windows
          LID_CLIPS                 2 curled manual clips near the free edge
          SLEEVE_FRONT, COVER_ART
          TRADEMARK_PRINTS_LID      molded "Nintendo" oval (plain text)
  App: hide TRADEMARK_PRINTS and TRADEMARK_PRINTS_LID together.

Insert UV (one image for COVER_ART + COVER_ART_SPINE + COVER_ART_BACK):
  back 130.0 | spine 15.7 | front 130.0, height 116.0 mm (275.7 x 116 = the GameTDB
  coverfullHQ 1616 x 680 sheet, whose folds at 762 / 854 px match the measured 764 / 856 ±3).
  u_splits = [130/275.7, 145.7/275.7]; v = 0 bottom (case Y 3) .. 1 top (case Y 119).

Self-check (printed as `self-check ...`, exit 1 on any failure): the four hinge poses,
the app's real DS card mesh (Detailed-Cartridges.usdz / ndsStandard) at
CASE_MEDIUM_ANCHOR against every case mesh with the case closed, the card inside the
pocket, and the exported USDZ (node names, bbox, lid pivot, UV folds). Only when all pass
is the USDZ copied over DuoDS/Resources/NDS-Case.usdz.
"""
import importlib.util
import json
import math
import shutil
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tools/ps2_blender'))
import common as C  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


D = _load('build_dvd', REPO / 'PS2_Disc_Case/source/build_dvd.py')      # geometry/text/render
K = _load('build_case', REPO / 'PS2_Disc_Case/source/build_case.py')    # collision helpers

MM = 0.001
ASSET_DIR = Path(__file__).resolve().parents[1]
EXPORT = ASSET_DIR / 'exports/NDS-Case.usdz'
RUNTIME = REPO / 'DuoDS/Resources/NDS-Case.usdz'
CARDS_USDZ = REPO / 'DuoDS/Resources/Detailed-Cartridges.usdz'

# ------------------------------------------------------------ dimensions (mm)
W, H, T = 135.0, 122.0, 14.5
X0, X1 = -W / 2, W / 2            # sleeve outer spine face .. free edge
ZF = T / 2                        # sleeve outer faces +-7.25
SLEEVE_T = 0.15
SLEEVE_OPEN_X = 66.6              # film pocket stops short of the free edge
PL_X0 = -67.05                    # plastic spine outer face
PL_Z = 6.8                        # plastic outer front/back faces
WALL = 1.2
SPLIT_GAP = 0.05
HALF_X0 = -65.7                   # tray/lid spine-side edge (spine inner face -65.85)
SIDE_WALL_X = (-65.0, -64.2)      # spine-side walls of tray and lid (clear of the spine ribs)
FLOOR = -PL_Z + WALL              # tray floor top -5.6 (lid floor +5.6)
ART_Z0, ART_Z1 = PL_Z + 0.03, PL_Z + 0.11
ART_SPINE_X = (-67.15, -67.08)
BACK_HINGE = (X0, H / 2, -ZF)
FRONT_HINGE = (X0, H / 2, ZF)

# insert sheet (see module docstring)
INS_B, INS_S, INS_F, INS_H = 130.0, 15.7, 130.0, 116.0
INS_W = INS_B + INS_S + INS_F                     # 275.7
U0, U1 = INS_B / INS_W, (INS_B + INS_S) / INS_W   # folds
INS_Y0 = (H - INS_H) / 2                          # 3.0
X_FOLD = PL_X0 + (INS_S / 2 - PL_Z)               # -66.0: fold line on the front/back faces
ART_X1 = X_FOLD + INS_F                           # 64.0: free edge of the paper

# free-edge structure
TRAY_INNER_WALL_X = (45.8, 47.0)  # tall wall 21 mm from the tray free edge
TRAY_COMB_WALL_X = (63.5, 64.3)
LID_RAIL_X = (50.8, 52.4)         # tall rail 15 mm from the lid free edge (clips root here)
LID_COMB_WALL_X = (58.5, 59.3)
LATCH_Y = ((97.5, 106.5), (15.5, 24.5))   # tray floor windows / lid hooks (hooks inset 0.5)
LATCH_X = (64.3, 66.3)

# DS card holder (photo: centre 57 mm from the hinge edge, 77 mm from the top edge)
HOLD_C = (X0 + 57.0, H - 77.0)    # (-10.5, 45.0)
HOLD_OUTER = (47.0, 46.0)         # photo 46.9 x 45.5
HOLD_INNER_W = 38.0               # wall-to-wall (photo 38.4); the card is located by the clips
CARD_PLAY = 0.3                   # per side
CARD_CLEAR_Z = 0.10               # card underside (lowest molded text) above the floor
CLIP_Z0_ABOVE_CARD = 0.13         # holder clip lips start this far above the label face
CLIP_OVERHANG = 1.5               # lips reach this far over the card edge (photo: clip
                                  # blocks stand ~4.7 mm off the wall, the card edge 2.9)
HOLD_TOP = round(FLOOR + 5.0, 3)  # holder wall top (-0.6)
TAB_Y = (HOLD_C[1] - 9.0, HOLD_C[1] + 9.0)       # gap in the right wall for the push tab
FLOOR_WINDOW_W = 23.0             # recessed floor panel in the pocket (photo 23)

# GBA Game Pak U bracket (photo, full-res: arms at x 29.5 / 86.2 from hinge, bar 37 mm
# from the top, clip posts y 16.4-24.4 from the top with a floor window inboard)
GBA_X = (-38.0, 18.7)             # outer faces of the two arms
GBA_Y0 = H - 38.2                 # bar outer (lower) edge, 83.8
GBA_ARM_Y1 = H - 16.4             # arm / post top end, 105.6
GBA_POST_Y0 = H - 24.4            # post lower end, 97.6
GBA_WALL = 1.4
GBA_POST_W = 2.2
GBA_TOP = FLOOR + 5.2             # arms and bar
GBA_POST_TOP = FLOOR + 5.8

# manual clips on the lid (photo: straight edge 14.7 mm from the top / 93.5 mm from the
# top, paddle 6.4 -> 10.8 -> 8.2 mm wide, 19 mm long, hole 21 x 11 under it)
CLIP_EDGE_Y = (H - 14.7, H - 93.5)
# (s from the rail face toward the hinge, centre-line height above the lid floor, width)
CLIP_STATIONS = [(-0.4, 3.2, 6.4), (2.0, 3.0, 7.0), (5.0, 2.3, 8.6), (8.0, 1.6, 10.0),
                 (11.0, 1.25, 10.8), (13.5, 1.35, 10.6), (15.5, 1.9, 10.0), (17.0, 2.8, 9.2),
                 (18.0, 3.8, 8.7), (18.6, 4.7, 8.4), (18.4, 5.2, 8.2)]
CLIP_T = 0.8
CLIP_CROWN = 0.45                 # arched cross-section (toward the tray)

# camera fitted by eye to references/nds_case_na_inside_empty.jpg (mm, open-case world)
PHOTO_CAM = {'eye': (-10.0, 25.0, 520.0), 'target': (-78.0, 58.0, -5.0), 'lens': 58.0}

COLORS = {'case_plastic': '#36383B', 'emboss': '#3E4043', 'sleeve': '#FAFAFA',
          'cover_art_default': '#EDEDED'}


def m(v):
    return v * MM


def box(bm, x0, x1, y0, y1, z0, z1, M=None, mi=0):
    D.add_box(bm, m(min(x0, x1)), m(max(x0, x1)), m(min(y0, y1)), m(max(y0, y1)),
              m(min(z0, z1)), m(max(z0, z1)), M, mi)


def rrect_mm(x0, x1, y0, y1, r, segs=4):
    return D.rrect(m(x0), m(x1), m(y0), m(y1), tuple(m(v) for v in r), segs=segs)


def add_loft(bm, loops, mi=0):
    """Closed tube through `loops` = [(pts, z)] (equal point counts, metres), each loop
    joined to the next and the last to the first: a ring-shaped solid of revolution-free
    profile (e.g. a frame with a sloped foot)."""
    rings = [[bm.verts.new((x, y, z)) for x, y in pts] for pts, z in loops]
    n = len(rings[0])
    for a, b in zip(rings, rings[1:] + rings[:1]):
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((a[k], a[k2], b[k2], b[k])).material_index = mi


def stadium(cx, cy, w, h, n=10):
    r = h / 2
    pts = []
    for k in range(n + 1):
        a = -math.pi / 2 + math.pi * k / n
        pts.append((cx + w / 2 - r + r * math.cos(a), cy + r * math.sin(a)))
    for k in range(n + 1):
        a = math.pi / 2 + math.pi * k / n
        pts.append((cx - w / 2 + r + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def holder_clip_y():
    """Y centres of the holder clips (photo: 4.8 mm below the pocket top, 3.5 above the
    bottom)."""
    _, _, py0, py1 = card_pocket()
    return (py1 - 4.8, py0 + 3.5)


def card_pocket():
    """Pocket inner rect (x0, x1, y0, y1) mm = measured card + CARD_PLAY per side."""
    cw, ch = CARD['size_mm'][0], CARD['size_mm'][1]
    cx, cy = HOLD_C
    return (cx - cw / 2 - CARD_PLAY, cx + cw / 2 + CARD_PLAY,
            cy - ch / 2 - CARD_PLAY, cy + ch / 2 + CARD_PLAY)


# measured from DuoDS/Resources/Detailed-Cartridges.usdz /root/ndsStandard (mm, card local
# frame): body X +-16.5, Y +-17.5, Z -3.8 .. 0 (label face at Z 0, facing +Z; contacts at -Y);
# lowest point = molded text on the back at Z -3.915; top = label platform at Z +0.043.
# measure_card() re-reads the file and fails the build if these drift.
CARD = {'size_mm': [33.0, 35.0, 3.8], 'body_z_mm': [-3.8, 0.0], 'min_z_mm': -3.915,
        'max_z_mm': 0.043}
CARD_BODY_CZ = (CARD['body_z_mm'][0] + CARD['body_z_mm'][1]) / 2        # -1.9
CARD_ORIGIN_Z = FLOOR + CARD_CLEAR_Z - CARD['min_z_mm']                 # label plane in case
ANCHOR = (HOLD_C[0], HOLD_C[1], CARD_ORIGIN_Z + CARD_BODY_CZ)           # body centre


# ------------------------------------------------------------ UV (closed-case world, metres)
def uv_front(co):
    return (U1 + (co.x / MM - X_FOLD) / INS_W, (co.y / MM - INS_Y0) / INS_H)


def uv_back(co):
    return ((INS_B - (co.x / MM - X_FOLD)) / INS_W, (co.y / MM - INS_Y0) / INS_H)


def uv_spine(co):
    return (U0 + (co.z / MM + INS_S / 2) / INS_W, (co.y / MM - INS_Y0) / INS_H)


def resmooth(obj, angle_deg=35):
    """Re-mark smooth faces / sharp edges by angle after booleans (EXACT booleans leave
    long thin triangles whose interpolated normals show as shading streaks otherwise)."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    C._smooth_by_angle(bm, angle_deg)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def shell(name, outer, inner, mats, cutters=()):
    obj = K.rplate(name, outer, mats)
    C.boolean(obj, K.rplate(name + '_cut', inner, mats))
    for cut in cutters:
        C.boolean(obj, cut)
    resmooth(obj)
    C.bevel(obj, m(0.35), segments=2, angle_deg=40)
    return obj


def cutter(name, x0, x1, y0, y1, z0, z1, r=0.0):
    return K.rplate(name, (x0, x1, y0, y1, z0, z1, (r, r, r, r)), [])


# ================================================================ build
def build():
    plastic = C.mat('CASE_plastic', C.hex_rgba(COLORS['case_plastic']), rough=0.45)
    emboss = C.mat('CASE_emboss', C.hex_rgba(COLORS['emboss']), rough=0.45)
    sleeve = C.mat('CASE_sleeve', C.hex_rgba(COLORS['sleeve']), rough=0.03, alpha=0.04)
    art = C.mat('COVER_ART_default', C.hex_rgba(COLORS['cover_art_default']), rough=0.45)

    root = C.empty('NDS_CASE')

    # ================================================================ tray (static)
    tray = C.empty('CASE_TRAY', parent=root)
    windows = [cutter(f'WIN{i}', LATCH_X[0], LATCH_X[1], y0, y1, -PL_Z - 1, FLOOR + 0.5, 0.4)
               for i, (y0, y1) in enumerate(LATCH_Y)]
    px0, px1, py0, py1 = card_pocket()
    hx, hy = HOLD_C
    # DS pocket: recessed floor panel + a molding slot under each clip lip (see-through)
    windows.append(cutter('FLOORWIN', hx - FLOOR_WINDOW_W / 2, hx + FLOOR_WINDOW_W / 2,
                          py0 + 0.8, py1 - 0.8, FLOOR - 0.4, FLOOR + 1, 0.3))
    for i, (yc, (xa, xb)) in enumerate((yc, xs) for yc in holder_clip_y()
                                       for xs in ((px0, px0 + 2.0), (px1 - 2.0, px1))):
        windows.append(cutter(f'CLIPSLOT{i}', xa, xb, yc - 1.6, yc + 1.6, -PL_Z - 1, FLOOR + 1, 0.2))
    # GBA: floor window inboard of each clip post, under its hook
    for i, (xa, xb) in enumerate(((GBA_X[0] + GBA_POST_W, GBA_X[0] + GBA_POST_W + 2.2),
                                  (GBA_X[1] - GBA_POST_W - 2.2, GBA_X[1] - GBA_POST_W))):
        windows.append(cutter(f'GBAWIN{i}', xa, xb, GBA_ARM_Y1 - 12.6, GBA_ARM_Y1 - 0.8,
                              -PL_Z - 1, FLOOR + 1, 0.2))
    obj = shell('TRAY_SHELL',
                (HALF_X0, X1, 0, H, -PL_Z, -SPLIT_GAP, (0.3, 3.0, 3.0, 0.3)),
                (PL_X0 - 1, X1 - WALL, WALL, H - WALL, FLOOR, 1.0, (0, 1.7, 1.7, 0)),
                [plastic], windows)
    C.set_parent(obj, tray)

    bm = D.new_bm()
    zt = -SPLIT_GAP
    box(bm, *SIDE_WALL_X, WALL - 0.1, H - WALL + 0.1, FLOOR - 0.05, zt)          # spine side
    rx0, rx1 = SIDE_WALL_X[1] - 0.1, TRAY_INNER_WALL_X[0] + 0.1                  # low rails
    box(bm, rx0, rx1, 3.4, 4.2, FLOOR - 0.05, FLOOR + 1.6)
    for xa, xb in ((rx0, GBA_X[0] - 1.0), (GBA_X[1] + 1.0, rx1)):   # top rail stops at the GBA
        box(bm, xa, xb, H - 4.2, H - 3.4, FLOOR - 0.05, FLOOR + 1.6)
    box(bm, *TRAY_INNER_WALL_X, WALL - 0.1, H - WALL + 0.1, FLOOR - 0.05, zt)    # tall wall
    box(bm, *TRAY_COMB_WALL_X, WALL - 0.1, H - WALL + 0.1, FLOOR - 0.05, -2.0)
    for k in range(12):                                                          # comb ribs
        yc = 6.0 + k * 10.0
        if any(y0 - 1.0 < yc < y1 + 1.0 for y0, y1 in LATCH_Y):
            continue
        box(bm, TRAY_COMB_WALL_X[1] - 0.1, X1 - WALL + 0.1, yc - 0.4, yc + 0.4, FLOOR - 0.05, -3.0)
    D.finish('TRAY_RAILS', bm, [plastic], parent=tray)

    # ---- DS card holder: thick raised frame (vertical foot, rounded shoulder, flat top)
    ow, oh = HOLD_OUTER[0] / 2, HOLD_OUTER[1] / 2
    ix0, ix1 = hx - HOLD_INNER_W / 2, hx + HOLD_INNER_W / 2       # wall faces -29.5 / 8.5

    def ring(inset, r, z):
        return (rrect_mm(hx - ow + inset, hx + ow - inset, hy - oh + inset, hy + oh - inset,
                         (r, r, r, r)), m(z))

    def iring(grow, r, z):
        return (rrect_mm(ix0 - grow, ix1 + grow, py0 - grow, py1 + grow, (r, r, r, r)), m(z))
    loops = [ring(0.0, 3.5, FLOOR - 0.05), ring(0.0, 3.5, FLOOR + 2.4),
             ring(0.45, 3.05, HOLD_TOP - 1.0), ring(1.3, 2.2, HOLD_TOP),
             iring(0.4, 1.0, HOLD_TOP), iring(0.0, 0.6, HOLD_TOP - 0.4),
             iring(0.0, 0.6, FLOOR - 0.05)]
    bm = D.new_bm()
    add_loft(bm, loops)
    holder = D.finish('DS_CARD_HOLDER', bm, [plastic], smooth_angle=35, parent=tray)
    C.boolean(holder, cutter('TABGAP', ix1 - 0.5, hx + ow + 2, TAB_Y[0], TAB_Y[1],
                             FLOOR + 0.3, HOLD_TOP + 1, 0.0))
    resmooth(holder)
    # 4 snap clips on the left / right walls: a post that locates the card edge (0.3 play)
    # and a lip over the card edge, entirely above the card's label face
    card_top = CARD_ORIGIN_Z + CARD['body_z_mm'][1]
    lz0 = card_top + CLIP_Z0_ABOVE_CARD
    bm = D.new_bm()
    for wall_x, edge_x, sgn in ((ix0, px0, 1), (ix1, px1, -1)):
        for yc in holder_clip_y():
            box(bm, wall_x - sgn * 0.3, edge_x, yc - 2.3, yc + 2.3, FLOOR - 0.05, lz0 + 0.9)
            box(bm, wall_x - sgn * 0.3, edge_x + sgn * (CARD_PLAY + CLIP_OVERHANG),
                yc - 2.3, yc + 2.3, lz0, lz0 + 0.9)
    D.finish('DS_CARD_CLIPS', bm, [plastic], parent=tray)

    # push tab: raised rounded pad in the right-wall gap, recessed triangle pointing -X
    pad = K.rplate('DS_PUSH_TAB', (px1 + 0.3, hx + ow + 6.9, hy - 8.6, hy + 8.6,
                                   FLOOR - 0.05, FLOOR + 1.2, (0.6, 3.5, 3.5, 0.6)), [plastic])
    tx = hx + ow + 0.4
    bm = D.new_bm()
    D.add_prism(bm, [(m(tx - 3.2), m(hy)), (m(tx + 2.4), m(hy - 5.2)), (m(tx + 2.4), m(hy + 5.2))],
                m(FLOOR + 0.95), m(FLOOR + 2.0))
    C.boolean(pad, D.finish('TABTRI', bm, []))
    resmooth(pad)
    C.bevel(pad, m(0.2), segments=2, angle_deg=40)
    C.set_parent(pad, tray)

    # ---- GBA U bracket: tall arms + bar, clip post with a hook at each arm top, panel
    # lines from the posts to the top wall
    gx0, gx1 = GBA_X
    gw, pw = GBA_WALL, GBA_POST_W
    bm = D.new_bm()
    box(bm, gx0, gx1, GBA_Y0, GBA_Y0 + gw, FLOOR - 0.05, GBA_TOP)
    for sgn, xo in ((1, gx0), (-1, gx1)):
        box(bm, xo, xo + sgn * gw, GBA_Y0, GBA_ARM_Y1, FLOOR - 0.05, GBA_TOP)
        box(bm, xo, xo + sgn * pw, GBA_POST_Y0, GBA_ARM_Y1, FLOOR - 0.05, GBA_POST_TOP)   # post
        box(bm, xo, xo + sgn * (pw + 1.0), GBA_POST_Y0 + 0.8, GBA_ARM_Y1,
            GBA_POST_TOP - 0.9, GBA_POST_TOP)                                             # hook
        box(bm, xo + sgn * 0.5, xo + sgn * 0.9, GBA_ARM_Y1, H - 1.3,
            FLOOR - 0.05, FLOOR + 0.08, mi=1)                                             # line
    obj = D.finish('GBA_HOLDER', bm, [plastic, emboss], parent=tray)
    C.bevel(obj, m(0.2), segments=1, angle_deg=40)

    # film (back) and insert back panel, living-hinge web
    K.box_obj('SLEEVE_BACK', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2, -ZF, -ZF + SLEEVE_T, [sleeve],
              parent=tray)
    K.box_obj('COVER_ART_BACK', PL_X0, ART_X1, INS_Y0, H - INS_Y0, -ART_Z1, -ART_Z0, [art],
              uv_fn=uv_back, parent=tray)
    K.box_obj('TRAY_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, H - 0.6, -PL_Z - 0.022, -PL_Z - 0.01,
              [plastic], parent=tray)
    C.empty('CASE_MEDIUM_ANCHOR', parent=tray, location=tuple(m(v) for v in ANCHOR))

    # molded "NINTENDO DS" on the tray floor (plain text, not the logo): trademark group
    prints_root = C.empty('TRADEMARK_PRINTS', parent=root)
    Mt = D.basis((0, 0, m(FLOOR - 0.02)), (0, 1, 0), (-1, 0, 0))   # reads upward, faces +Z
    bm = D.new_bm()
    D.add_text(bm, 'DS', m(62.7), m(-31.6), m(22.0), m(9.6), Mt, depth=m(0.2), res=2)
    D.add_text(bm, 'NINTENDO', m(33.5), m(-34.3), m(29.0), m(4.4), Mt, depth=m(0.2), res=2)
    D.finish('TRAY_NDS_EMBOSS', bm, [emboss], parent=prints_root)

    # ================================================================ spine
    spine_hinge = C.empty('CASE_SPINE_HINGE', parent=root,
                          location=tuple(m(v) for v in BACK_HINGE), rotation=(math.pi, 0, 0))
    spine = C.empty('CASE_SPINE', parent=spine_hinge)
    spine_objs = [K.rplate('SPINE_PANEL', (PL_X0, PL_X0 + WALL, 0, H, -PL_Z, PL_Z,
                                           (1.0, 0, 0, 1.0)), [plastic])]
    C.bevel(spine_objs[0], m(0.35), segments=2, angle_deg=40)
    xi = PL_X0 + WALL                                        # inner spine face -65.85
    bm = D.new_bm()
    for z0 in (-5.2, 4.6):
        box(bm, xi - 0.05, xi + 0.6, 2.0, H - 2.0, z0, z0 + 0.6)
    spine_objs.append(D.finish('SPINE_RIBS', bm, [plastic]))
    # PP "5" recycling mark (not a trademark), inner face near the bottom, reads upward
    Mi = D.basis((m(xi + 0.02), 0, 0), (0, 1, 0), (0, 0, 1))   # x = +Y, y = +Z, normal +X
    bm = D.new_bm()
    tri_pts = [(m(14.0 + 3.0 * math.cos(math.radians(a))), m(3.0 * math.sin(math.radians(a))))
               for a in (0, 120, 240)]
    inner = [(m(14.0 + 2.3 * math.cos(math.radians(a))), m(2.3 * math.sin(math.radians(a))))
             for a in (0, 120, 240)]
    for k in range(3):
        a, b, c, d = tri_pts[k], tri_pts[(k + 1) % 3], inner[(k + 1) % 3], inner[k]
        D.add_flat(bm, [a, b, c, d], Mi)
    D.add_text(bm, '5', m(13.6), 0, m(1.6), m(2.2), Mi, res=1)
    D.add_text(bm, 'PP', m(8.6), 0, m(3.2), m(1.8), Mi, res=1)
    spine_objs.append(D.finish('SPINE_EMBOSS', bm, [emboss], recalc=False))
    spine_objs.append(K.box_obj('SLEEVE_SPINE', X0, X0 + SLEEVE_T, 0.2, H - 0.2, -ZF + 0.2,
                                ZF - 0.2, [sleeve]))
    spine_objs.append(K.box_obj('COVER_ART_SPINE', ART_SPINE_X[0], ART_SPINE_X[1], INS_Y0,
                                H - INS_Y0, -6.6, 6.6, [art], uv_fn=uv_spine))

    # ================================================================ lid
    lid = C.empty('CASE_LID', parent=spine, location=(0, 0, m(BACK_HINGE[2] - FRONT_HINGE[2])))
    rail = LID_RAIL_X[0]
    holes = [K.rplate(f'CLIPHOLE{i}', (rail - 21.0, rail - 0.1, ye - 11.6, ye - 0.6,
                                       PL_Z - WALL - 1, PL_Z + 1, (4.5, 0.5, 0.5, 4.5)), [])
             for i, ye in enumerate(CLIP_EDGE_Y)]
    lid_objs = [shell('LID_SHELL',
                      (HALF_X0, X1, 0, H, SPLIT_GAP, PL_Z, (0.3, 3.0, 3.0, 0.3)),
                      (PL_X0 - 1, X1 - WALL, WALL, H - WALL, -1.0, PL_Z - WALL, (0, 1.7, 1.7, 0)),
                      [plastic], holes)]
    lf = PL_Z - WALL                                          # lid floor +5.6
    bm = D.new_bm()
    box(bm, *SIDE_WALL_X, WALL - 0.1, H - WALL + 0.1, SPLIT_GAP, lf + 0.05)
    for y0, y1 in ((H - 6.2, H - 5.4), (5.4, 6.2)):
        box(bm, SIDE_WALL_X[1] - 0.1, LID_RAIL_X[0] + 0.1, y0, y1, lf - 1.4, lf + 0.05)
    box(bm, *LID_RAIL_X, WALL - 0.1, H - WALL + 0.1, SPLIT_GAP, lf + 0.05)
    box(bm, *LID_COMB_WALL_X, WALL - 0.1, H - WALL + 0.1, 3.2, lf + 0.05)
    for k in range(12):
        yc = 6.0 + k * 10.0
        box(bm, LID_COMB_WALL_X[1] - 0.1, X1 - WALL + 0.1, yc - 0.4, yc + 0.4, 3.4, lf + 0.05)
    for y0, y1 in LATCH_Y:                                    # latch hooks into the tray windows
        box(bm, LATCH_X[0] + 0.4, LATCH_X[1] - 0.4, y0 + 0.5, y1 - 0.5, -1.5, lf + 0.05)
    lid_objs.append(D.finish('LID_RAILS', bm, [plastic]))

    # manual clips: broad paddle rooted in the free-edge rail, dipping toward the lid floor
    # (holds the manual) and curling up at the tip over the floor hole
    bm = D.new_bm()
    th = CLIP_T / 2
    prof = [(rail - sx, lf - h) for sx, h, _ in CLIP_STATIONS]
    for ye in CLIP_EDGE_Y:
        rows = []
        for i, (x, z) in enumerate(prof):
            a = Vector(prof[max(i - 1, 0)])
            b = Vector(prof[min(i + 1, len(prof) - 1)])
            d = (b - a).normalized()
            n = Vector((-d.y, d.x)) * th
            w = CLIP_STATIONS[i][2]
            nc = n.normalized() * CLIP_CROWN
            rows.append([bm.verts.new((m(x + sx * n.x + c * nc.x), m(y), m(z + sx * n.y + c * nc.y)))
                         for sx, y, c in ((1, ye - w, 0), (1, ye - w / 2, 1), (1, ye, 0),
                                          (-1, ye, 0), (-1, ye - w / 2, 1), (-1, ye - w, 0))])
        for r0, r1 in zip(rows, rows[1:]):
            for k in range(6):
                bm.faces.new((r0[k], r0[(k + 1) % 6], r1[(k + 1) % 6], r1[k]))
        bm.faces.new(rows[0])
        bm.faces.new(list(reversed(rows[-1])))
    clips = D.finish('LID_CLIPS', bm, [plastic], smooth_angle=50)
    sub = clips.modifiers.new('Smooth', 'SUBSURF')
    sub.levels = sub.render_levels = 1
    lid_objs.append(clips)
    lid_objs.append(K.box_obj('LID_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, H - 0.6, PL_Z + 0.01,
                              PL_Z + 0.022, [plastic]))
    lid_objs.append(K.box_obj('SLEEVE_FRONT', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2,
                              ZF - SLEEVE_T, ZF, [sleeve]))
    lid_objs.append(K.box_obj('COVER_ART', PL_X0, ART_X1, INS_Y0, H - INS_Y0, ART_Z0, ART_Z1,
                              [art], uv_fn=uv_front))

    # molded "Nintendo" oval on the lid inner face (plain text + stadium ring)
    lid_prints = C.empty('TRADEMARK_PRINTS_LID', parent=lid)
    Ml = D.basis((0, 0, m(lf + 0.02)), (-1, 0, 0), (0, 1, 0))   # reads left-to-right when open
    oc = (4.0, 64.0)                                            # local x = -X, y = Y
    bm = D.new_bm()
    outer = stadium(m(oc[0]), m(oc[1]), m(30.5), m(7.4))
    inner = stadium(m(oc[0]), m(oc[1]), m(29.5), m(6.4))
    Z0, Z1 = 0.0, m(0.2)
    ring = [([Ml @ Vector((x, y, Z0)) for x, y in outer]), ([Ml @ Vector((x, y, Z1)) for x, y in outer]),
            ([Ml @ Vector((x, y, Z1)) for x, y in inner]), ([Ml @ Vector((x, y, Z0)) for x, y in inner])]
    vs = [[bm.verts.new(p) for p in loop] for loop in ring]
    n = len(outer)
    for a, b in zip(vs, vs[1:] + vs[:1]):
        for k in range(n):
            bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
    D.add_text(bm, 'Nintendo', m(oc[0]), m(oc[1]), m(24.0), m(4.6), Ml, depth=m(0.2), res=2)
    lp = [D.finish('LID_NINTENDO_EMBOSS', bm, [emboss])]

    for o in spine_objs:
        K.bake_into(o, spine)
    for o in lid_objs:
        K.bake_into(o, lid)
    for o in lp:
        K.bake_into(o, lid_prints)
    return root


# ================================================================ DS card (real app mesh)
def import_card():
    """Import ndsStandard from the app's Detailed-Cartridges.usdz (mm units, Z-up stage,
    imported unconverted). Returns (card root object, its meshes); everything else from
    the file is deleted."""
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(CARDS_USDZ))
    new = [o for o in bpy.data.objects if o not in before]
    card = next(o for o in new if o.name.split('.')[0] == 'ndsStandard')
    keep = set(C.descendants(card))
    C.set_parent(card, None)
    for o in new:
        if o not in keep:
            bpy.data.objects.remove(o, do_unlink=True)
    card.name = 'DS_CARD_ndsStandard'
    return card, [o for o in keep if o.type == 'MESH']


def measure_card(card, meshes):
    """Card-local bbox (mm) of the imported mesh; must match CARD."""
    bpy.context.view_layer.update()
    inv = card.matrix_world.inverted()
    pts = [inv @ o.matrix_world @ v.co for o in meshes for v in o.data.vertices]
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    return lo, hi


def place_card(card, anchor):
    """Card origin (label plane) sits -CARD_BODY_CZ (1.9 mm) above the body centre = the
    anchor, axes identical, mm -> m. Unparented (so it is never exported with the case)."""
    bpy.context.view_layer.update()
    card.matrix_world = (anchor.matrix_world @ Matrix.Translation((0, 0, m(-CARD_BODY_CZ)))
                         @ Matrix.Scale(MM, 4))
    bpy.context.view_layer.update()


# ================================================================ checks
def hinge_check(root):
    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    ok = True
    half = math.pi / 2
    for a, b in ((0, 0), (half, 0), (0, half), (half, half)):
        spine.rotation_euler[1], lid.rotation_euler[1] = a, b
        hits = K.group_collisions(root)
        ok &= not hits
        print(f'self-check spine={a:.4f} lid={b:.4f}: collisions {hits or "none"}')
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    bpy.context.view_layer.update()
    return ok


def card_check(root, card, meshes):
    ok = True
    lo, hi = measure_card(card, meshes)
    exp_lo = (-CARD['size_mm'][0] / 2, -CARD['size_mm'][1] / 2, CARD['min_z_mm'])
    exp_hi = (CARD['size_mm'][0] / 2, CARD['size_mm'][1] / 2, CARD['max_z_mm'])
    drift = max(abs(a - b) for a, b in zip(lo + hi, exp_lo + exp_hi))
    print(f'self-check card mesh bbox (card local, mm) {[round(v, 3) for v in lo]} .. '
          f'{[round(v, 3) for v in hi]}  (drift vs CARD {drift:.3f})')
    ok &= drift < 0.05
    case_meshes = [o for g in K.case_groups(root).values() for o in g]
    hits = K.group_collisions(root, {'case': case_meshes, 'card': meshes})
    ok &= not hits
    print(f'self-check DS card in closed case: collisions {hits or "none"}')
    # the card really lies in the pocket: world bbox inside the pocket rect, above the floor
    ws = [(o.matrix_world @ v.co) / MM for o in meshes for v in o.data.vertices]
    wlo = [min(p[i] for p in ws) for i in range(3)]
    whi = [max(p[i] for p in ws) for i in range(3)]
    px0, px1, py0, py1 = card_pocket()
    inside = (px0 < wlo[0] and whi[0] < px1 and py0 < wlo[1] and whi[1] < py1
              and wlo[2] > FLOOR and whi[2] < HOLD_TOP)
    ok &= inside
    print(f'self-check card world bbox x {wlo[0]:.2f}..{whi[0]:.2f} y {wlo[1]:.2f}..{whi[1]:.2f} '
          f'z {wlo[2]:.3f}..{whi[2]:.3f} in pocket x {px0:.2f}..{px1:.2f} y {py0:.2f}..{py1:.2f} '
          f'above floor {FLOOR} below wall top {HOLD_TOP}: {"ok" if inside else "FAIL"}')
    return ok


def usd_check(path):
    """Re-open the export: node names, bbox, pivots, insert UV folds."""
    from pxr import Gf, Usd, UsdGeom
    st = Usd.Stage.Open(str(path))
    ok = st.GetDefaultPrim().GetName() == 'NDS_CASE'
    prims = {p.GetName(): p for p in st.Traverse()}
    need = ['CASE_TRAY', 'CASE_SPINE_HINGE', 'CASE_SPINE', 'CASE_LID', 'CASE_MEDIUM_ANCHOR',
            'COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK', 'TRADEMARK_PRINTS',
            'TRADEMARK_PRINTS_LID']
    missing = [n for n in need if n not in prims]
    ok &= not missing
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), ['default', 'render'])
    rng = cache.ComputeWorldBound(st.GetDefaultPrim()).ComputeAlignedRange()
    lo, hi = [v / MM for v in rng.GetMin()], [v / MM for v in rng.GetMax()]
    exp = ((X0, 0, -ZF), (X1, H, ZF))
    bb_ok = all(abs(a - b) < 0.05 for a, b in zip(lo + hi, exp[0] + exp[1]))
    ok &= bb_ok
    lid_t = UsdGeom.Xformable(prims['CASE_LID']).GetLocalTransformation().ExtractTranslation()
    hinge = UsdGeom.Xformable(prims['CASE_SPINE_HINGE']).GetLocalTransformation()
    lid_ok = (lid_t - Gf.Vec3d(0, 0, -m(T))).GetLength() < 1e-7
    ok &= lid_ok
    anc = UsdGeom.Xformable(prims['CASE_MEDIUM_ANCHOR']).GetLocalTransformation()
    print(f'self-check usdz defaultPrim {st.GetDefaultPrim().GetName()}, missing {missing or "none"}')
    print(f'self-check usdz bbox mm {[round(v, 3) for v in lo]} .. {[round(v, 3) for v in hi]}: '
          f'{"ok" if bb_ok else "FAIL"}')
    print(f'self-check usdz CASE_LID local {tuple(round(v / MM, 3) for v in lid_t)} mm, '
          f'CASE_SPINE_HINGE at {tuple(round(v / MM, 3) for v in hinge.ExtractTranslation())} mm; '
          f'anchor at {tuple(round(v / MM, 3) for v in anc.ExtractTranslation())} mm')
    # UV folds: u range of each insert mesh (the paper is continuous across the folds)
    for name in ('COVER_ART_BACK', 'COVER_ART_SPINE', 'COVER_ART'):
        mesh = next(p for p in Usd.PrimRange(prims[name]) if p.IsA(UsdGeom.Mesh))
        pv = UsdGeom.PrimvarsAPI(mesh).GetPrimvar('st') or UsdGeom.PrimvarsAPI(mesh).GetPrimvar('UVMap')
        uvs = pv.Get()
        us = [uv[0] for uv in uvs]
        vs = [uv[1] for uv in uvs]
        print(f'self-check usdz {name} u {min(us):.4f}..{max(us):.4f} v {min(vs):.4f}..{max(vs):.4f}')
    return ok


def test_pattern(w_px=1103, h_px=464):
    """Neutral UV test image in insert space (NOT game art): back blue, spine yellow, front
    green, 10 mm grid, red folds, a black diagonal and a black 50 mm-radius circle centred
    on the spine, which must continue unbroken across back | spine | front."""
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
    ring = np.abs(np.hypot(xm - INS_W / 2, ym - INS_H / 2) - 50.0) < px * 1.8
    img[diag | ring, :3] = 0.05
    # "TOP" bar + arrow near the top of the front panel to show orientation
    img[(V > 0.9) & (V < 0.93) & (U > 0.8) & (U < 0.95), :3] = (0.1, 0.1, 0.6)
    im = bpy.data.images.new('UV_TEST_PATTERN', w_px, h_px)
    im.pixels.foreach_set(img.ravel())
    return im


def write_contract(tris, card_lo, card_hi):
    px0, px1, py0, py1 = card_pocket()
    data = {
        'asset': 'NDS-Case',
        'description': 'US (NTSC-U) Nintendo DS retail game case, opaque dark grey PP, clear '
                       'outer film, book style (spine on -X), LANDSCAPE',
        'root_node': 'NDS_CASE',
        'runtime_file': 'DuoDS/Resources/NDS-Case.usdz',
        'units': 'metres in the USDZ (metersPerUnit 1, upAxis Y); mm in this file',
        'frame': 'case closed, standing, front cover +Z, spine -X; root = bbox bottom centre',
        'size_mm': [W, H, T],
        'bbox_mm': {'x': [X0, X1], 'y': [0.0, H], 'z': [-ZF, ZF]},
        'hinges': {
            'back_hinge_line_mm': list(BACK_HINGE), 'front_hinge_line_mm': list(FRONT_HINGE),
            'CASE_SPINE_HINGE': 'at the back hinge line, rotation (pi, 0, 0): local +Y = world -Y',
            'CASE_SPINE': 'identity rest; local rot_y 0 (closed) -> pi/2',
            'CASE_LID': 'local position (0, 0, -14.5 mm) in CASE_SPINE, zero rest rotation; '
                        'local rot_y 0 -> pi/2',
            'fully_open': 'tray | spine | lid flat, inner faces +Z, outer faces z = -7.25, '
                          'x -217.0 .. 67.5 mm',
        },
        'insert_mm': {'back': INS_B, 'spine': INS_S, 'front': INS_F, 'height': INS_H},
        'u_splits': [round(U0, 6), round(U1, 6)],
        'insert_uv': {
            'layout': 'back | spine | front as seen from outside, u 0 = back free edge, '
                      'u 1 = front free edge, v 0 = bottom, v 1 = top',
            'insert_y_on_case_mm': [INS_Y0, H - INS_Y0],
            'front_fold_x_mm': X_FOLD, 'paper_free_edge_x_mm': ART_X1,
            'gametdb_coverfullHQ': '1616 x 680 px maps 1:1 (5.862 px/mm): folds at 762.0 / '
                                   '854.0 px (measured 764 / 856 +-3)',
            'mesh_u_coverage': 'back 0 .. {:.4f}, spine {:.4f} .. {:.4f}, front {:.4f} .. 1'.format(
                (INS_B + X_FOLD - PL_X0) / INS_W, U0 + (INS_S / 2 - 6.6) / INS_W,
                U1 - (INS_S / 2 - 6.6) / INS_W, U1 + (PL_X0 - X_FOLD) / INS_W),
        },
        'medium': {
            'model': 'DuoDS/Resources/Detailed-Cartridges.usdz /root/ndsStandard (mm units)',
            'card_local_bbox_mm': {'min': [round(v, 3) for v in card_lo],
                                   'max': [round(v, 3) for v in card_hi]},
            'card_axes': '+Z = label face normal (label plane at Z 0), +Y = up, contacts at -Y',
            'CASE_MEDIUM_ANCHOR_mm': [round(v, 3) for v in ANCHOR],
            'anchor_rotation': 'identity: +Z toward the lid (label normal), +Y card up, +X right',
            'placement': 'ndsStandard as child of CASE_MEDIUM_ANCHOR: position (0, 0, +1.9 mm) '
                         '(card origin = label plane, 1.9 mm above the body centre), rotation '
                         'identity, uniform scale 0.001 (mm -> m)',
            'card_locating_rect_mm': {'x': [round(px0, 2), round(px1, 2)],
                                      'y': [round(py0, 2), round(py1, 2)],
                                      'size': [round(px1 - px0, 2), round(py1 - py0, 2)],
                                      'note': 'card + 0.3 per side: X by the 4 clip posts, '
                                              'Y by the frame walls'},
            'holder_inner_wall_to_wall_mm': [HOLD_INNER_W, round(py1 - py0, 2)],
            'holder_outer_mm': list(HOLD_OUTER), 'holder_center_mm': list(HOLD_C),
            'holder_top_z_mm': HOLD_TOP,
            'card_underside_above_floor_mm': CARD_CLEAR_Z, 'tray_floor_z_mm': FLOOR,
        },
        'gba_bracket_mm': {'x': list(GBA_X), 'y': [GBA_Y0, GBA_ARM_Y1],
                           'inner_width': round(GBA_X[1] - GBA_X[0] - 2 * GBA_WALL, 2)},
        'manual_clips_straight_edge_y_mm': list(CLIP_EDGE_Y),
        'colors': COLORS,
        'nodes': ['NDS_CASE', 'CASE_TRAY', 'CASE_SPINE_HINGE', 'CASE_SPINE', 'CASE_LID',
                  'CASE_MEDIUM_ANCHOR', 'COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK',
                  'TRADEMARK_PRINTS', 'TRADEMARK_PRINTS_LID'],
        'trademark_groups': ['TRADEMARK_PRINTS', 'TRADEMARK_PRINTS_LID'],
        'triangles': tris,
        'generated_by': 'Handheld_Cases/NDS/source/build_nds_case.py',
    }
    (ASSET_DIR / 'contract.json').write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def render_photo_view(cam, card):
    """Empty open case from roughly the reference photo's viewpoint (camera above the tray
    side, slightly below centre, aimed at the lid's hinge edge), 1920 x 956 like the photo;
    source/compare_photo.py pastes it next to the photo."""
    sc = bpy.context.scene
    old = (sc.render.resolution_x, sc.render.resolution_y, cam.data.lens)
    for o in C.descendants(card):
        o.hide_render = True
    sc.render.resolution_x, sc.render.resolution_y = 1920, 956
    cam.data.lens = PHOTO_CAM['lens']
    # the photo's light comes from the right and slightly above (shadows fall left / down)
    D.area_light('PhotoKey', (0.45, 0.20, 0.28), (-0.075, 0.061, 0), 0.15, 7.0)
    others = [bpy.data.objects[n] for n in ('KeyLight', 'FillLight') if n in bpy.data.objects]
    for li in others:
        li.hide_render = True
    D.look_at(cam, tuple(m(v) for v in PHOTO_CAM['eye']), tuple(m(v) for v in PHOTO_CAM['target']))
    D.render(ASSET_DIR / 'renders/case_open_photo_view.png')
    bpy.data.objects.remove(bpy.data.objects['PhotoKey'], do_unlink=True)
    for li in others:
        li.hide_render = False
    for o in C.descendants(card):
        o.hide_render = False
    sc.render.resolution_x, sc.render.resolution_y, cam.data.lens = old


def main():
    C.reset_scene()
    root = build()
    tris = C.triangle_count(C.descendants(root))
    print(f'NDS-Case triangles: {tris}')
    ok = tris <= 40000
    ok &= hinge_check(root)

    anchor = bpy.data.objects['CASE_MEDIUM_ANCHOR']
    card, card_meshes = import_card()
    card_lo, card_hi = measure_card(card, card_meshes)
    place_card(card, anchor)
    ok &= card_check(root, card, card_meshes)
    if not ok:
        print('self-check FAILED')
        sys.exit(1)

    # export without the card (unparented; it joins the anchor only in the .blend)
    C.export_usdz(root, EXPORT)
    if not usd_check(EXPORT):
        print('self-check FAILED (usdz)')
        sys.exit(1)
    shutil.copyfile(EXPORT, RUNTIME)
    print(f'self-check passed; copied {EXPORT.name} -> {RUNTIME}')
    write_contract(tris, card_lo, card_hi)
    C.set_parent(card, anchor)

    # ---------------------------------------------------------------- renders
    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    cam = D.setup_render(res=(1280, 800), samples=48, world_rgb=(0.20, 0.205, 0.22))
    D.area_light('KeyLight', (-0.30, 0.30, 0.30), (0, 0.06, 0), 0.35, 3.0)
    D.area_light('FillLight', (0.40, 0.10, 0.25), (0, 0.06, 0), 0.5, 1.0)
    D.look_at(cam, (-0.28, 0.20, 0.24), (-0.012, 0.056, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed.png')

    spine.rotation_euler[1] = lid.rotation_euler[1] = math.pi / 2
    D.area_light('KeyLight', (-0.12, 0.25, 0.5), (-0.075, 0.061, 0), 0.6, 3.0)
    D.area_light('FillLight', (0.30, -0.10, 0.35), (-0.075, 0.061, 0), 0.6, 0.8)
    D.look_at(cam, (-0.075, -0.03, 0.44), (-0.075, 0.059, -0.005))
    D.render(ASSET_DIR / 'renders/case_open.png')
    D.look_at(cam, (0.04, -0.02, 0.16), (-0.012, 0.050, -0.004))
    D.render(ASSET_DIR / 'renders/case_open_holder_detail.png')
    render_photo_view(cam, card)

    # render-only UV proof: test pattern through the three insert meshes
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
    D.area_light('UnderKey', (-0.075, 0.2, -0.6), (-0.075, 0.061, 0), 0.6, 3.0)
    D.look_at(cam, (-0.075, 0.061, -0.44), (-0.075, 0.061, 0.0))
    D.render(ASSET_DIR / 'renders/case_open_cover_outside.png')
    bpy.data.objects.remove(bpy.data.objects['UnderKey'], do_unlink=True)
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    D.area_light('KeyLight', (-0.18, 0.30, 0.45), (0, 0.06, 0), 0.35, 3.0)
    D.area_light('FillLight', (0.40, 0.10, 0.20), (0, 0.06, 0), 0.5, 1.0)
    D.look_at(cam, (-0.22, 0.12, 0.30), (-0.01, 0.058, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed_cover.png')
    art_default = bpy.data.materials['COVER_ART_default']
    for o in arts:
        o.data.materials[0] = art_default
    bpy.data.materials.remove(tm)
    bpy.data.images.remove(im)
    C.save_blend(ASSET_DIR / 'NDS_Case.blend')


if __name__ == '__main__':
    main()
