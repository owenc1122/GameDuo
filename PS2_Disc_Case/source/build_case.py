"""US (NTSC-U/C) PS2 DVD keep case (Amaray), runtime model `PS2-Case`.

Run from the repo root (reuses build_dvd.py's helpers and, for the .blend, its disc):
    Blender -b --factory-startup --python-exit-code 1 --python PS2_Disc_Case/source/build_case.py

Frame (contract_parts/PS2-Case.json): case closed, standing, front cover +Z,
spine on -X, root PS2_CASE = bottom-centre of the bbox: X [-67.5, 67.5],
Y [0, 190], Z [-7, 7]. Split plane Z = 0.

Double living hinge, like the real Amaray case: back tray <-back hinge-> spine
<-front hinge-> lid. Both hinge lines run along Y on the OUTER spine corners
(film side), where the PP living hinges are:
  back hinge  X -67.5, Z -7   (spine / back corner)
  front hinge X -67.5, Z +7   (spine / front corner)
CASE_SPINE rot_y 0 -> pi/2 folds the spine flat to the -X side of the tray; CASE_LID
(child of CASE_SPINE) rot_y 0 -> pi/2 then folds the lid flat beyond it. Fully open
(pi/2, pi/2): tray | spine | lid lie side by side, inner faces up, outer faces all
at Z = -7, total width 135 + 14 + 135 = 284 mm (X -216.5 .. 67.5), like the
reference inside photo.

Nodes
  PS2_CASE                          root empty
    CASE_TRAY                       empty: static back half
      TRAY_SHELL                    black PP back half (rounded corners, bevelled edges)
      HUB_ROSETTE                   seat, 6 rosette fingers, triangular button (+PUSH emboss);
                                    seat and spokes stop HUB_CLEAR below the disc underside
      DISC_RING                     4 raised retaining arcs around the disc
      MEMCARD_HOLDER, TRAY_EMBOSS   corner brackets (inner 57.0 x 42.5 = card + 0.5 play);
                                    embossed arrow / MEMORY CARD HOLDER / PUSH (the PS logo
                                    and the AMARAY maker mark are trademarks: TRADEMARK_PRINTS)
      SLEEVE_BACK, COVER_ART_BACK   clear film and insert back panel
      TRAY_HINGE_WEB                living-hinge strip (the lid has LID_HINGE_WEB)
      CASE_DISC_ANCHOR              empty at the hub, disc centre, rotated +90 deg about X
                                    so the disc's +Y (label) faces +Z (the lid)
    TRADEMARK_PRINTS                top-level print group: TRAY_PS_LOGO_EMBOSS (embossed PS
                                    logo on the tray floor) and TRAY_AMARAY_EMBOSS (embossed
                                    AMARAY maker mark); moving prints are in the SPINE / LID
                                    groups below
    CASE_SPINE_HINGE                empty ON the back hinge line, rotated pi about X so
                                    its local +Y = world -Y (contract hinge_axis_dir)
      CASE_SPINE                    identity rest transform = runtime pivot; +rot_y opens
        SPINE_PANEL                 spine wall
        SPINE_RIBS, SPINE_EMBOSS    two inner lengthwise ribs; inner patent-number emboss
        SLEEVE_SPINE, COVER_ART_SPINE
        TRADEMARK_PRINTS_SPINE      black band, white box + colour PS logo, wordmark
        CASE_LID                    at the front hinge line (local (0, 0, -14 mm)), zero
                                    rest rotation; +rot_y opens
          LID_SHELL, LID_CLIPS      front half (finger notch on the opening edge) + clips
          SLEEVE_FRONT, COVER_ART
          TRADEMARK_PRINTS_LID      black top banner, white wordmark, colour PS logo
  App: hide TRADEMARK_PRINTS, TRADEMARK_PRINTS_SPINE and TRADEMARK_PRINTS_LID together.

Insert UV space (one image for COVER_ART + COVER_ART_SPINE + COVER_ART_BACK), 273 x 183 mm:
  u = 0 .. 0.4744 back panel | 0.4744 .. 0.5256 spine | 0.5256 .. 1 front panel,
  v = 0 bottom .. 1 top (insert Y 3.5 .. 186.5 mm).
Logos come from tools/ps2_blender/vectors (official outlines); the small embossed
texts (MEMORY CARD HOLDER, PUSH, AMARAY, patent numbers) have no vector and use
Blender's built-in font. Self-check (printed as `self-check ...`, exits 1 on a hit): the
four hinge poses, the real disc at CASE_DISC_ANCHOR and a 56.5 x 42 x 7.5 memory-card
proxy in the holder, both against every case mesh with the case closed.
"""
import importlib.util
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix
from mathutils.bvhtree import BVHTree

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/ps2_blender"))
import common as C  # noqa: E402

_spec = importlib.util.spec_from_file_location('build_dvd', Path(__file__).with_name('build_dvd.py'))
D = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(D)

MM = 0.001
ASSET_DIR = Path(__file__).resolve().parents[1]

# ------------------------------------------------------------ dimensions (mm)
X0, X1 = -67.5, 67.5              # sleeve outer spine face .. free edge
ZF = 7.0                          # sleeve outer faces +-7
SLEEVE_T = 0.15
SLEEVE_OPEN_X = 66.6              # film pocket stops short of the free edge (insert slides in)
PL_X0 = -67.05                    # plastic spine outer face
PL_Z = 6.55                       # plastic outer front/back faces
WALL = 1.3
SPLIT_GAP = 0.05                  # tray walls stop at -0.05, lid walls start at +0.05
HALF_X0 = -65.7                   # tray/lid spine-side edge (spine inner face -65.75)
ART_Z0, ART_Z1 = 6.58, 6.66       # cover art (front/back) depth
ART_SPINE_X = (-67.15, -67.08)
BANNER_Z = 6.70
PRINT_Z = 6.74
SPINE_BAND_X = -67.19
SPINE_BOX_X = -67.22
SPINE_TOP_X = -67.25
INSERT_W, INSERT_H = 273.0, 183.0
INSERT_Y0 = 3.5
BACK_HINGE = (-67.5, 95.0, -7.0)
HUB_CLEAR = 0.05                  # hub seat / spoke tops below the disc data face
MC_PLAY = 0.5                     # memory-card holder: inner size = card + play
MC_WALL = 1.2                     # holder bracket wall thickness (outside the inner size)
MC_CARD = (56.5, 7.5, 42.0)       # PS2 memory card lying flat in the holder: X, Z, Y (mm)
FRONT_HINGE = (-67.5, 95.0, 7.0)


def m(v):
    return v * MM


def memcard_inner(mc):
    """Holder inner size (X, Y) mm = the card it holds + MC_PLAY."""
    fx, fy = mc['fits_card_mm']
    return fx + MC_PLAY, fy + MC_PLAY


def box_obj(name, x0, x1, y0, y1, z0, z1, mats, uv_fn=None, parent=None):
    bm = D.new_bm()
    D.add_box(bm, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1))
    return D.finish(name, bm, mats, uv_fn=uv_fn, parent=parent)


def rplate(name, spec, mats):
    x0, x1, y0, y1, z0, z1, radii = spec
    return D.plate(name, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1),
                   tuple(m(r) for r in radii), segs=5, mats=mats)


def shell(name, outer, inner, mats, extra_cutters=()):
    """Rounded plate minus rounded cavity (and optional cutters), small edge bevel."""
    obj = rplate(name, outer, mats)
    C.boolean(obj, rplate(name + '_cut', inner, mats))
    for cut in extra_cutters:
        C.boolean(obj, cut)
    C.bevel(obj, m(0.35), segments=2, angle_deg=40)
    return obj


def bake_into(obj, parent):
    """Parent with identity local transform, geometry moved into parent space."""
    bpy.context.view_layer.update()
    M = parent.matrix_world.inverted() @ obj.matrix_world
    obj.data.transform(M)
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Identity(4)
    obj.matrix_basis = Matrix.Identity(4)
    return obj


def circle(cx, cy, r, n=48):
    return [(cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n))
            for k in range(n)]


def quad(bm, M, u0, u1, v0, v1, mi=0):
    D.add_flat(bm, [(m(u0), m(v0)), (m(u1), m(v0)), (m(u1), m(v1)), (m(u0), m(v1))], M, mi)


# insert UV (x, y, z in metres, closed-case world space)
def uv_front(co):
    return (0.5256 + (co.x / MM - X0) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def uv_back(co):
    return ((62.0 - co.x / MM) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def uv_spine(co):
    return (0.4744 + (co.z / MM + ZF) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def build():
    spec = C.load_contract('PS2-Case')
    L, col = spec['layout'], spec['colors']
    plastic = C.mat('CASE_plastic', C.hex_rgba(col['case_plastic']), rough=0.62)
    emboss = C.mat('CASE_emboss', C.hex_rgba('#303035'), rough=0.5)
    # clear PP/PET film: near-colourless, very transparent, glossy (specular does the work)
    sleeve = C.mat('CASE_sleeve', C.hex_rgba('#FAFAFA'), rough=0.03, alpha=0.04)
    art = C.mat('COVER_ART_default', C.hex_rgba('#EDEDED'), rough=0.45)
    ink_banner = C.mat('PRINT_banner_black', C.hex_rgba(col['banner']), rough=0.35)
    ink_white = C.mat('PRINT_wordmark_white', C.hex_rgba(col['wordmark']), rough=0.4)
    ps_cols = [C.mat(f'PRINT_ps_{k}', C.hex_rgba(col[f'ps_{k}']), rough=0.4)
               for k in ('red', 'yellow', 'green', 'blue')]
    box_white = C.mat('PRINT_logo_box_white', C.hex_rgba(col['spine_logo_box']), rough=0.4)
    MIS = (0, 1, 2, 3)

    root = C.empty('PS2_CASE')

    # ================================================================ tray (static)
    tray = C.empty('CASE_TRAY', parent=root)
    obj = shell('TRAY_SHELL',
                (HALF_X0, X1, 0, 190, -PL_Z, -SPLIT_GAP, (0.3, 3.0, 3.0, 0.3)),
                (PL_X0 - 1, X1 - WALL, WALL, 190 - WALL, -PL_Z + WALL, 1.0, (0, 1.7, 1.7, 0)),
                [plastic])
    C.set_parent(obj, tray)
    floor_z = -PL_Z + WALL                                   # -5.25

    # hub: base disc, seat (disc rests on its top), 6 rosette fingers, button
    hub = L['hub']
    hx, hy = hub['center_mm'][0], hub['center_mm'][1]
    seat_z = hub['disc_seat_z_mm']                           # -3.2 = disc data face
    top_z = seat_z - HUB_CLEAR                               # seat / spoke tops, under the disc
    bm = D.new_bm()
    D.add_prism(bm, [(m(x), m(y)) for x, y in circle(hx, hy, hub['platform_d_mm'] / 2)],
                m(floor_z - 0.05), m(floor_z + 0.6))
    D.add_prism(bm, [(m(x), m(y)) for x, y in circle(hx, hy, 16.5)],
                m(floor_z + 0.6), m(top_z))
    for k in range(hub['rosette_fingers']):
        a = math.radians(30 + 60 * k)
        R = Matrix.Translation((m(hx), m(hy), 0)) @ Matrix.Rotation(a, 4, 'Z')
        D.add_box(bm, m(4.0), m(7.3), m(-1.4), m(1.4), m(top_z - 0.05), m(-1.35), R)
        D.add_box(bm, m(6.6), m(7.8), m(-1.4), m(1.4), m(-1.9), m(-1.35), R)
        D.add_box(bm, m(9.0), m(17.5), m(-0.5), m(0.5), m(floor_z + 0.55), m(top_z), R)  # ribs
    tri = [(m(hx + 3.6 * math.cos(math.radians(90 + 120 * k))),
            m(hy + 3.6 * math.sin(math.radians(90 + 120 * k)))) for k in range(3)]
    D.add_prism(bm, tri, m(top_z - 0.05), m(-1.6))
    D.finish('HUB_ROSETTE', bm, [plastic], smooth_angle=35, parent=tray)

    # segmented retaining ring around the disc
    ring = L['disc_ring']
    bm = D.new_bm()
    r0, r1 = ring['inner_d_mm'] / 2, ring['outer_d_mm'] / 2
    for c in (45, 135, 225, 315):
        D.add_arc(bm, m(hx), m(hy), m(r0), m(r1), math.radians(c - 25), math.radians(c + 25),
                  m(floor_z - 0.05), m(floor_z + ring['height_above_floor_mm']), n=12)
    D.finish('DISC_RING', bm, [plastic], smooth_angle=35, parent=tray)

    # memory-card holder: 4 corner L-brackets whose walls stand OUTSIDE the inner size
    # (card 56.5 x 42 in X x Y + MC_PLAY), so the inner pocket really fits a card
    mc = L['memory_card_holder']
    (mx, my), (iw, ih) = mc['center_mm'], memcard_inner(mc)
    top = floor_z + mc['wall_height_mm']
    t = MC_WALL
    bm = D.new_bm()
    for sx in (-1, 1):
        for sy in (-1, 1):
            cx, cy = mx + sx * iw / 2, my + sy * ih / 2           # inner corner
            ox, oy = cx + sx * t, cy + sy * t                     # outer corner
            ax = sorted((ox, ox - sx * 17))
            ay = sorted((oy, oy - sy * 12))
            D.add_box(bm, m(ax[0]), m(ax[1]), m(min(cy, oy)), m(max(cy, oy)),
                      m(floor_z - 0.05), m(top))
            D.add_box(bm, m(min(cx, ox)), m(max(cx, ox)), m(ay[0]), m(ay[1]),
                      m(floor_z - 0.05), m(top))
    D.finish('MEMCARD_HOLDER', bm, [plastic], parent=tray)

    # embossed marks on the tray floor / hub button (flat, slightly lighter plastic)
    Me = D.basis((0, 0, m(floor_z + 0.15)), (1, 0, 0), (0, 1, 0))
    # the embossed PS logo is a trademark: own mesh under the root-level TRADEMARK_PRINTS
    # (tray is static under the root, so the logo stays in place when the group moves/hides)
    prints_root = C.empty('TRADEMARK_PRINTS', parent=root)
    bm = D.new_bm()
    D.add_ps_logo(bm, m(mx + 3), m(my + 7.5), m(13.0), m(10.0), Me)
    D.finish('TRAY_PS_LOGO_EMBOSS', bm, [emboss], recalc=False, parent=prints_root)
    bm = D.new_bm()
    D.add_flat(bm, [(m(mx - 22), m(my + 7.5)), (m(mx - 17.5), m(my + 4.5)),
                    (m(mx - 17.5), m(my + 10.5))], Me)
    D.add_text(bm, 'MEMORY CARD', m(mx + 1), m(my - 5.5), m(30.0), m(3.4), Me, res=1)
    D.add_text(bm, 'HOLDER', m(mx + 1), m(my - 10.5), m(16.5), m(3.4), Me, res=1)
    Mb = D.basis((0, 0, m(-1.58)), (1, 0, 0), (0, 1, 0))
    D.add_text(bm, 'PUSH', m(hx), m(hy - 0.6), m(3.0), m(0.9), Mb, res=1)
    D.finish('TRAY_EMBOSS', bm, [emboss], recalc=False, parent=tray)
    # AMARAY is the case maker's trademark: own mesh in TRADEMARK_PRINTS, hidden with it
    bm = D.new_bm()
    D.add_text(bm, 'AMARAY', m(-55.0), m(22.0), m(12.0), m(2.2), Me, res=1)
    D.finish('TRAY_AMARAY_EMBOSS', bm, [emboss], recalc=False, parent=prints_root)

    # film (back) and insert back panel
    box_obj('SLEEVE_BACK', X0 + 0.2, SLEEVE_OPEN_X, 0.2, 189.8, -ZF, -ZF + SLEEVE_T, [sleeve],
            parent=tray)
    box_obj('COVER_ART_BACK', PL_X0, 62.0, INSERT_Y0, 186.5, -ART_Z1, -ART_Z0, [art],
            uv_fn=uv_back, parent=tray)
    # living-hinge web: dark PP strip just inside the insert where it overhangs the tray
    # edge, so the open hinge gap shows plastic (as on the real case), not paper
    box_obj('TRAY_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, 189.4, -6.572, -6.56, [plastic],
            parent=tray)
    C.empty('CASE_DISC_ANCHOR', parent=tray,
            location=(m(hx), m(hy), m(seat_z + 0.6)), rotation=(math.pi / 2, 0, 0))


    # ================================================================ spine
    spine_hinge = C.empty('CASE_SPINE_HINGE', parent=root,
                          location=tuple(m(v) for v in BACK_HINGE), rotation=(math.pi, 0, 0))
    spine = C.empty('CASE_SPINE', parent=spine_hinge)
    spine_objs = [rplate('SPINE_PANEL', (PL_X0, PL_X0 + WALL, 0, 190, -PL_Z, PL_Z,
                                         (1.0, 0, 0, 1.0)), [plastic])]
    C.bevel(spine_objs[0], m(0.35), segments=2, angle_deg=40)
    bm = D.new_bm()
    xi = PL_X0 + WALL                                        # inner spine face -65.75
    for z0 in (-4.9, 4.3):                                   # two lengthwise ribs
        D.add_box(bm, m(xi - 0.05), m(xi + 0.6), m(2.0), m(188.0), m(z0), m(z0 + 0.6))
    D.finish('SPINE_RIBS', bm, [plastic], parent=None)
    spine_objs.append(bpy.data.objects['SPINE_RIBS'])
    Mi = D.basis((m(xi + 0.03), 0, 0), (0, -1, 0), (0, 0, -1))   # reads down, faces +X
    bm = D.new_bm()
    D.add_text(bm, 'US PAT No 5788068', m(-155.0), m(-2.2), m(32.0), m(1.9), Mi, res=1)
    D.add_text(bm, 'EP PAT No 789348, JP No 2863317', m(-139.0), m(2.2), m(62.0), m(1.9), Mi,
               res=1)
    spine_objs.append(D.finish('SPINE_EMBOSS', bm, [emboss], recalc=False))
    spine_objs.append(box_obj('SLEEVE_SPINE', X0, X0 + SLEEVE_T, 0.2, 189.8, -6.8, 6.8, [sleeve]))
    spine_objs.append(box_obj('COVER_ART_SPINE', ART_SPINE_X[0], ART_SPINE_X[1], INSERT_Y0, 186.5,
                              -6.6, 6.6, [art], uv_fn=uv_spine))
    spine_prints = C.empty('TRADEMARK_PRINTS_SPINE', parent=spine)
    sb = L['spine_banner']
    Ms = D.basis((m(SPINE_BAND_X), 0, 0), (0, 0, 1), (0, 1, 0))   # x=+Z, y=+Y, normal -X
    bm = D.new_bm()
    quad(bm, Ms, -6.6, 6.6, *sb['band_y_mm'])
    sp_prints = [D.finish('SPINE_BAND', bm, [ink_banner], recalc=False)]
    lb = sb['logo_box']
    (bz, by), (bw, bh) = lb['center_zy_mm'], lb['size_mm']
    bm = D.new_bm()
    quad(bm, D.basis((m(SPINE_BOX_X), 0, 0), (0, 0, 1), (0, 1, 0)),
         bz - bw / 2, bz + bw / 2, by - bh / 2, by + bh / 2)
    sp_prints.append(D.finish('SPINE_LOGO_BOX', bm, [box_white], recalc=False))
    bm = D.new_bm()
    D.add_ps_logo(bm, m(bz), m(by), m(8.4), m(8.0),
                  D.basis((m(SPINE_TOP_X), 0, 0), (0, 0, 1), (0, 1, 0)), mis=MIS)
    sp_prints.append(D.finish('SPINE_PS_LOGO', bm, ps_cols, recalc=False))
    wm = sb['wordmark']
    wz, wy = wm['center_zy_mm']
    bm = D.new_bm()
    D.add_ps2_wordmark(bm, m(-wy), m(wz), m(wm['length_mm']), m(wm['height_mm']),
                       D.basis((m(SPINE_BOX_X), 0, 0), (0, -1, 0), (0, 0, 1)), res=3)
    sp_prints.append(D.finish('SPINE_WORDMARK', bm, [ink_white], recalc=False))

    # ================================================================ lid
    lid = C.empty('CASE_LID', parent=spine, location=(0, 0, m(BACK_HINGE[2] - FRONT_HINGE[2])))
    notch = C.cylinder('LID_NOTCH', m(3.5), m(4.0), verts=24,
                       location=(m(X1 - 0.6), m(95.0), 0), rotation=(0, math.pi / 2, 0))
    lid_objs = [shell('LID_SHELL',
                      (HALF_X0, X1, 0, 190, SPLIT_GAP, PL_Z, (0.3, 3.0, 3.0, 0.3)),
                      (PL_X0 - 1, X1 - WALL, WALL, 190 - WALL, -1.0, PL_Z - WALL,
                       (0, 1.7, 1.7, 0)), [plastic], extra_cutters=(notch,))]
    cl = L['clips']
    bm = D.new_bm()
    z1 = PL_Z - WALL - cl['gap_above_lid_floor_mm']
    for cx, cy in cl['centers_mm']:
        hw = cl['width_y_mm'] / 2
        D.add_prism(bm, D.rrect(m(cl['x_span_mm'][0]), m(X1 - WALL + 0.3), m(cy - hw), m(cy + hw),
                                (m(hw), 0, 0, m(hw)), segs=6),
                    m(z1 - cl['thickness_mm']), m(z1))
    lid_objs.append(D.finish('LID_CLIPS', bm, [plastic], smooth_angle=35))
    lid_objs.append(box_obj('LID_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, 189.4, 6.56, 6.572,
                            [plastic]))
    lid_objs.append(box_obj('SLEEVE_FRONT', X0 + 0.2, SLEEVE_OPEN_X, 0.2, 189.8, ZF - SLEEVE_T, ZF,
                            [sleeve]))
    lid_objs.append(box_obj('COVER_ART', PL_X0, 62.0, INSERT_Y0, 186.5, ART_Z0, ART_Z1, [art],
                            uv_fn=uv_front))
    lid_prints = C.empty('TRADEMARK_PRINTS_LID', parent=lid)
    lg = L['logo']
    br = lg['banner_rect_mm']
    bm = D.new_bm()
    quad(bm, D.basis((0, 0, m(BANNER_Z)), (1, 0, 0), (0, 1, 0)), PL_X0, br['x'][1], *br['y'])
    lp = [D.finish('FRONT_BANNER', bm, [ink_banner], recalc=False)]
    Mp = D.basis((0, 0, m(PRINT_Z)), (1, 0, 0), (0, 1, 0))
    w = lg['wordmark']
    bm = D.new_bm()
    D.add_ps2_wordmark(bm, m(w['center_mm'][0]), m(w['center_mm'][1]), m(w['size_mm'][0]),
                       m(w['size_mm'][1]), Mp, res=3)
    lp.append(D.finish('FRONT_WORDMARK', bm, [ink_white], recalc=False))
    p = lg['ps_symbol']
    bm = D.new_bm()
    D.add_ps_logo(bm, m(p['center_mm'][0]), m(p['center_mm'][1]), m(p['size_mm'][0]),
                  m(p['size_mm'][1]), Mp, mis=MIS)
    lp.append(D.finish('FRONT_PS_LOGO', bm, ps_cols, recalc=False))

    for o in spine_objs:
        bake_into(o, spine)
    for o in sp_prints:
        bake_into(o, spine_prints)
    for o in lid_objs:
        bake_into(o, lid)
    for o in lp:
        bake_into(o, lid_prints)
    return root


# ------------------------------------------------------------ self check
def case_groups(root):
    """Case meshes split into the three rigid groups tray / spine / lid."""
    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    lid_set = set(C.descendants(lid))
    spine_set = set(C.descendants(spine)) - lid_set
    groups = {'tray': [], 'spine': [], 'lid': []}
    for o in C.descendants(root):
        if o.type == 'MESH':
            groups['lid' if o in lid_set else 'spine' if o in spine_set else 'tray'].append(o)
    return groups


def group_collisions(root, groups=None):
    """Pairwise triangle overlaps between meshes of different groups in the current pose
    (default groups: tray / spine / lid of the case under `root`)."""
    groups = groups or case_groups(root)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    trees = {}
    for g, objs in groups.items():
        for o in objs:
            ev = o.evaluated_get(dg)
            me = ev.to_mesh()
            me.calc_loop_triangles()
            vs = [o.matrix_world @ v.co for v in me.vertices]
            tris = [tuple(t.vertices) for t in me.loop_triangles]
            ev.to_mesh_clear()
            trees[o.name] = (g, BVHTree.FromPolygons(vs, tris, all_triangles=True))
    hits = []
    names = list(trees)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if trees[a][0] != trees[b][0] and trees[a][1].overlap(trees[b][1]):
                hits.append(f'{a}x{b}')
    return hits


def contents_check(root, disc_root):
    """Case closed: the disc (parented to CASE_DISC_ANCHOR) and a memory-card proxy box
    (MC_CARD, lying on the tray floor centred in the holder) against every case mesh.
    Returns {label: collision list}; the proxy is deleted afterwards."""
    L = C.load_contract('PS2-Case')['layout']
    mc = L['memory_card_holder']
    (mx, my), (cw, ct, ch) = mc['center_mm'], MC_CARD
    floor_z = -PL_Z + WALL
    card = box_obj('_MC_PROXY', mx - cw / 2, mx + cw / 2, my - ch / 2, my + ch / 2,
                   floor_z + 0.2, floor_z + 0.2 + ct, [])      # clears the 0.15 mm embosses
    case_meshes = [o for g in case_groups(root).values() for o in g]
    disc_meshes = [o for o in C.descendants(disc_root) if o.type == 'MESH']
    out = {
        'disc': group_collisions(root, {'case': case_meshes, 'disc': disc_meshes}),
        'memory card proxy': group_collisions(root, {'case': case_meshes, 'card': [card]}),
    }
    iw, ih = memcard_inner(mc)
    print(f'self-check memory card holder inner {iw:.1f} x {ih:.1f} mm for a {cw} x {ch} mm card')
    bpy.data.objects.remove(card, do_unlink=True)
    return out


def test_pattern(w_px=1092, h_px=732):
    """Neutral UV test image in insert space (NOT game art): tinted panels (back blue,
    spine yellow, front green), 10 mm grid, red panel folds, a black diagonal and a
    black 60 mm-radius circle centred on the spine, which must run on unbroken
    across back | spine | front if the three COVER_ART meshes share one UV layout."""
    import numpy as np
    u = (np.arange(w_px) + 0.5) / w_px
    v = (np.arange(h_px) + 0.5) / h_px
    U, V = np.meshgrid(u, v)
    img = np.ones((h_px, w_px, 4), dtype=np.float32)
    img[..., :3] = (0.62, 0.75, 0.92)
    img[(U >= 0.4744) & (U < 0.5256), :3] = (0.95, 0.85, 0.45)
    img[U >= 0.5256, :3] = (0.62, 0.90, 0.62)
    xm, ym = U * INSERT_W, V * INSERT_H
    px = INSERT_W / w_px
    grid = (np.abs((xm + 5) % 10 - 5) < px * 0.8) | (np.abs((ym + 5) % 10 - 5) < px * 0.8)
    img[grid, :3] *= 0.7
    for f in (0.4744, 0.5256):
        img[np.abs(U - f) * INSERT_W < px * 1.2, :3] = (0.85, 0.1, 0.1)
    diag = np.abs(ym - xm * INSERT_H / INSERT_W) < px * 1.8
    ring = np.abs(np.hypot(xm - INSERT_W / 2, ym - INSERT_H / 2) - 60.0) < px * 1.8
    img[diag | ring, :3] = 0.05
    im = bpy.data.images.new('UV_TEST_PATTERN', w_px, h_px)
    im.pixels.foreach_set(img.ravel())
    return im


def main():
    C.reset_scene()
    root = build()
    print(f'PS2-Case triangles: {C.triangle_count(C.descendants(root))}')
    C.export_usdz(root, ASSET_DIR / 'exports/PS2-Case.usdz')

    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    half = math.pi / 2
    failed = False
    for a, b in ((0, 0), (half, 0), (0, half), (half, half)):
        spine.rotation_euler[1], lid.rotation_euler[1] = a, b
        hits = group_collisions(root)
        failed |= bool(hits)
        print(f'self-check spine={a:.4f} lid={b:.4f}: collisions {hits or "none"}')
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0

    # the disc sits on the hub anchor (in the .blend only, not part of the export)
    disc = D.build()
    C.set_parent(disc, bpy.data.objects['CASE_DISC_ANCHOR'], keep_world=False)
    disc.location, disc.rotation_euler = (0, 0, 0), (0, 0, 0)
    for label, hits in contents_check(root, disc).items():
        failed |= bool(hits)
        print(f'self-check {label} in closed case: collisions {hits or "none"}')
    if failed:
        print('self-check FAILED')
        sys.exit(1)

    cam = D.setup_render(res=(1024, 768), samples=32, world_rgb=(0.11, 0.115, 0.13))
    D.area_light('KeyLight', (-0.2, 0.45, 0.55), (0, 0.095, 0), 0.4, 3.2)
    # fill kept out of the front cover's mirror direction (glossy black banner)
    D.area_light('FillLight', (-0.45, 0.05, 0.05), (0, 0.095, 0), 0.5, 0.9)
    D.look_at(cam, (-0.26, 0.19, 0.38), (0.0, 0.094, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed.png')

    spine.rotation_euler[1] = lid.rotation_euler[1] = half
    D.area_light('KeyLight', (-0.05, 0.3, 0.65), (-0.0745, 0.095, 0), 0.6, 3)
    D.look_at(cam, (-0.07, 0.03, 0.60), (-0.0745, 0.093, -0.005))
    D.render(ASSET_DIR / 'renders/case_open.png')

    # render-only UV proof: test pattern through the three insert meshes, prints hidden
    im = test_pattern()
    tm = bpy.data.materials.new('UV_TEST')
    tm.use_nodes = True
    nt = tm.node_tree
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = im
    nt.links.new(tex.outputs['Color'], nt.nodes['Principled BSDF'].inputs['Base Color'])
    nt.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.45
    arts = [bpy.data.objects[n] for n in ('COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK')]
    prints = [o for g in ('TRADEMARK_PRINTS_SPINE', 'TRADEMARK_PRINTS_LID')
              for o in bpy.data.objects[g].children]
    for o in arts:
        o.data.materials[0] = tm
    for o in prints:
        o.hide_render = True
    # outside of the fully open case = the insert laid flat (back | spine | front)
    D.area_light('UnderKey', (-0.07, 0.25, -0.6), (-0.0745, 0.095, 0), 0.6, 3)
    D.look_at(cam, (-0.0745, 0.095, -0.60), (-0.0745, 0.095, 0.0))
    D.render(ASSET_DIR / 'renders/case_open_cover_outside.png')
    bpy.data.objects.remove(bpy.data.objects['UnderKey'], do_unlink=True)
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    D.area_light('KeyLight', (-0.2, 0.45, 0.55), (0, 0.095, 0), 0.4, 3.2)
    D.look_at(cam, (-0.26, 0.19, 0.38), (0.0, 0.094, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed_cover.png')
    art_default = bpy.data.materials['COVER_ART_default']
    for o in arts:
        o.data.materials[0] = art_default
    for o in prints:
        o.hide_render = False
    bpy.data.materials.remove(tm)
    bpy.data.images.remove(im)
    C.save_blend(ASSET_DIR / 'PS2_Disc_Case.blend')


if __name__ == '__main__':
    main()
