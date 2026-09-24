"""US (NTSC-U) Nintendo 3DS retail game case (CTR), runtime model `3DS-Case`.

Run from the repo root:
    Blender -b --factory-startup --python-exit-code 1 --python Handheld_Cases/3DS/source/build_3ds_case.py

Contract: Handheld_Cases/CONTRACT.md + ../contract.json (all numbers in mm there).
Frame: case closed, standing, front cover +Z, spine -X, root CTR_CASE = bottom centre
of the bbox: X [-67.5, 67.5], Y [0, 122], Z [-6, 6]. Split plane Z = 0.
White opaque PP, landscape (wider than tall), clear film over the outside, book style.

Double living hinge exactly like PS2_Disc_Case/source/build_case.py:
  back hinge  X -67.5, Z -6   (spine / back corner)  = CASE_SPINE_HINGE (rotated pi about X)
  front hinge X -67.5, Z +6   (spine / front corner) = CASE_LID at local (0, 0, -12 mm)
CASE_SPINE rot_y 0 -> pi/2 folds the spine flat to the -X side; CASE_LID (child of
CASE_SPINE) rot_y 0 -> pi/2 folds the lid beyond it. Fully open: tray | spine | lid, inner
faces up, outer faces at Z = -6, X -214.5 .. 67.5.

Nodes
  CTR_CASE                          root empty
    CASE_TRAY                       static back half
      TRAY_SHELL                    white PP back half (finger recess on the free edge)
      TRAY_RAIL                     inner rib along the free edge + 2 latch hooks
      CARD_HOLDER                   raised rim around the card pocket, open on +X for the tongue
      CARD_HOLDER_HOOKS             2 corner hooks (+X) and 2 nubs (-X) over the card label edge
      CARD_RELEASE_TONGUE           flexible push tongue on +X
      TRAY_EMBOSS                   triangle on the tongue (not a trademark)
      TRAY_HINGE_WEB, SLEEVE_BACK, COVER_ART_BACK
      CASE_MEDIUM_ANCHOR            empty at the card-body centre, identity rotation
    TRADEMARK_PRINTS                plain-text "Nintendo 3DS" molded on the tray floor
    CASE_SPINE_HINGE                empty ON the back hinge line, rotated pi about X
      CASE_SPINE                    identity rest transform; +rot_y opens
        SPINE_PANEL, SPINE_TABS, SLEEVE_SPINE, COVER_ART_SPINE
        CASE_LID                    local (0, 0, -12 mm); +rot_y opens
          LID_SHELL, LID_RAIL, LID_CLIPS (2 manual clips), LID_HINGE_WEB,
          SLEEVE_FRONT, COVER_ART

Insert UV (one image for COVER_ART_BACK | COVER_ART_SPINE | COVER_ART), 276 x 116.1 mm
= GameTDB coverfullHQ 1616 x 680 (back 0-777, spine 777-847, front 847-1616 px):
  u 0 .. 0.4808 back | 0.4808 .. 0.5243 spine | 0.5243 .. 1 front, v 0 bottom .. 1 top.
Self-check (exit 1 on failure): contract consistency, closed bbox, four hinge corner poses,
and the app's real 3DS card (Detailed-Cartridges.usdz, node threeDS) plus a box proxy
at CASE_MEDIUM_ANCHOR, all collision-free against every case mesh with the case closed.
"""
import importlib.util
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tools/ps2_blender'))
import common as C  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    'build_dvd', REPO / 'PS2_Disc_Case/source/build_dvd.py')
D = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(D)

MM = 0.001
ASSET_DIR = Path(__file__).resolve().parents[1]
SPEC = json.loads((ASSET_DIR / 'contract.json').read_text())
CARD_USDZ = REPO / 'DuoDS/Resources/Detailed-Cartridges.usdz'
RUNTIME_USDZ = REPO / SPEC['runtime_file']

# ------------------------------------------------------------ dimensions (mm)
W, H, T = (SPEC['size_mm'][k] for k in ('width', 'height', 'thickness'))
X0, X1 = -W / 2, W / 2            # film outer spine face .. free edge
ZF = T / 2                        # film outer faces +-6
YC = H / 2
SLEEVE_T = 0.15
SLEEVE_OPEN_X = 66.6              # film stops short of the free edge
LAY = SPEC['layout_mm']
WALL = LAY['wall']
PL_Z = LAY['plastic_outer_z']     # plastic outer front/back faces
PL_X0 = -67.05                    # plastic spine outer face
SPLIT_GAP = LAY['split_gap']
HALF_X0 = -65.7                   # tray/lid spine-side edge (spine inner face -65.75)
FLOOR_Z = LAY['tray_floor_z']     # -4.35 tray inner floor (lid floor = +4.35)
ART_Z0, ART_Z1 = 5.58, 5.66       # insert front/back panel depth
ART_SPINE_X = (-67.15, -67.08)
CORNER_R = 2.0                    # free-side corner radius (spine side 0.3)

INS = SPEC['insert_mm']
IB, IS, IF, IH = INS['back'], INS['spine'], INS['front'], INS['height']
IW = IB + IS + IF
S1, S2 = IB / IW, (IB + IS) / IW
IY0 = (H - IH) / 2
BACK_FREE_X = X0 + IB             # 65.2
FRONT_FREE_X = X0 + IF            # 63.8

BACK_HINGE = SPEC['hinges_mm']['back']
FRONT_HINGE = SPEC['hinges_mm']['front']

ANC = SPEC['medium_anchor']
AX, AY, AZ = ANC['position_mm']
CARD = ANC['medium']
CARD_LABEL_Z = AZ + 1.9           # world z of the card's label plane (card-local z = 0)

HOLD = LAY['card_holder']


def m(v):
    return v * MM


def box_obj(name, x0, x1, y0, y1, z0, z1, mats, uv_fn=None, parent=None):
    bm = D.new_bm()
    D.add_box(bm, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1))
    return D.finish(name, bm, mats, uv_fn=uv_fn, parent=parent)


def rplate(name, spec, mats, segs=5):
    x0, x1, y0, y1, z0, z1, radii = spec
    return D.plate(name, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1),
                   tuple(m(r) for r in radii), segs=segs, mats=mats)


def shell(name, outer, inner, mats, extra_cutters=()):
    """Rounded plate minus rounded cavity with a small edge bevel (baked), then the optional
    cutters (finger recess, clip windows). The bevel is baked BEFORE the cutters: a live
    bevel on the thin strips they leave (0.3-0.4 mm) overlaps itself and breaks the
    tessellation of the rim face (a triangle spanning the whole cavity)."""
    obj = rplate(name, outer, mats)
    C.boolean(obj, rplate(name + '_cut', inner, mats))
    C.bevel(obj, m(0.35), segments=2, angle_deg=40)
    C.apply_all(obj)
    for cut in extra_cutters:
        C.boolean(obj, cut)
    return resmooth(obj)


def resmooth(obj, angle_deg=50):
    """Re-mark sharp edges after booleans / baked bevels (new edges come in smooth, which
    smears the vertex normals of the big flat floor n-gons into visible shading wedges).
    50 deg keeps the 45-deg bevel segments smooth and every 90-deg edge sharp."""
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    C._smooth_by_angle(bm, angle_deg)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def notch_cutter(name, fr):
    """Finger recess in the free-edge wall, straddling the split plane (rounded ends)."""
    return rplate(name, (X1 - fr['depth'], X1 + 1.0, fr['y'][0], fr['y'][1],
                         fr['z'][0], fr['z'][1], (0.6, 0, 0, 0.6)), [])


def bake_into(obj, parent):
    """Parent with identity local transform, geometry moved into parent space."""
    bpy.context.view_layer.update()
    M = parent.matrix_world.inverted() @ obj.matrix_world
    obj.data.transform(M)
    obj.parent = parent
    obj.matrix_parent_inverse = Matrix.Identity(4)
    obj.matrix_basis = Matrix.Identity(4)
    return obj


# insert UV (x, y, z in metres, closed-case world space)
def uv_front(co):
    return (S2 + (co.x / MM - X0) / IW, (co.y / MM - IY0) / IH)


def uv_back(co):
    return ((BACK_FREE_X - co.x / MM) / IW, (co.y / MM - IY0) / IH)


def uv_spine(co):
    return (S1 + (co.z / MM + ZF) / IW, (co.y / MM - IY0) / IH)


def build():
    col = SPEC['colors']
    plastic = C.mat('CASE_plastic', C.hex_rgba(col['case_plastic']), rough=0.55)
    emboss = C.mat('CASE_emboss', C.hex_rgba(col['emboss']), rough=0.5)
    sleeve = C.mat('CASE_sleeve', C.hex_rgba('#FAFAFA'), rough=0.03, alpha=0.04)
    art = C.mat('COVER_ART_default', C.hex_rgba(col['cover_art_default']), rough=0.45)

    root = C.empty('CTR_CASE')

    # ================================================================ tray (static)
    tray = C.empty('CASE_TRAY', parent=root)
    fr = LAY['finger_recess']
    notch_t = notch_cutter('TRAY_NOTCH', fr)
    obj = shell('TRAY_SHELL',
                (HALF_X0, X1, 0, H, -PL_Z, -SPLIT_GAP, (0.3, CORNER_R, CORNER_R, 0.3)),
                (PL_X0 - 1, X1 - WALL, WALL, H - WALL, FLOOR_Z, 1.0,
                 (0, CORNER_R - WALL, CORNER_R - WALL, 0)),
                [plastic], extra_cutters=(notch_t,))
    C.set_parent(obj, tray)

    # free-edge inner rib + two latch hooks near the corners
    rx0, rx1 = LAY['free_edge_rail_x']
    bm = D.new_bm()
    D.add_box(bm, m(rx0), m(rx1), m(16.0), m(H - 16.0), m(FLOOR_Z - 0.05), m(-0.8))
    for y0 in (6.0, H - 12.0):
        D.add_box(bm, m(63.6), m(X1 - WALL + 0.05), m(y0), m(y0 + 6.0),
                  m(FLOOR_Z - 0.05), m(-0.3))
        D.add_box(bm, m(62.6), m(63.65), m(y0 + 1.0), m(y0 + 5.0), m(-2.2), m(-0.3))  # hook lip
    D.finish('TRAY_RAIL', bm, [plastic], parent=tray)

    # card holder: rim around the pocket, gap on +X for the release tongue
    hx, hy = HOLD['center']
    (px0, px1), (py0, py1) = HOLD['pocket_rel_anchor']['x'], HOLD['pocket_rel_anchor']['y']
    rim, rim_top = HOLD['rim'], HOLD['rim_top_z']
    gy0, gy1 = HOLD['tongue_gap_y_rel_anchor']
    holder = rplate('CARD_HOLDER', (hx + px0 - rim, hx + px1 + rim, hy + py0 - rim, hy + py1 + rim,
                                    FLOOR_Z - 0.05, rim_top, (1.6, 1.6, 1.6, 1.6)), [plastic])
    C.boolean(holder, rplate('HOLDER_POCKET', (hx + px0, hx + px1, hy + py0, hy + py1,
                                               FLOOR_Z - 1, rim_top + 1, (0.8, 0.8, 0.8, 0.8)), []))
    C.boolean(holder, box_obj('HOLDER_GAP', hx + px1 - 1, hx + px1 + rim + 1, hy + gy0, hy + gy1,
                              FLOOR_Z - 1, rim_top + 1, []))
    C.bevel(holder, m(0.3), segments=2, angle_deg=40)
    C.apply_all(holder)
    C.set_parent(resmooth(holder), tray)

    # hooks / nubs: underside just above the label plane, overhanging the card edge
    hz0, hz1 = CARD_LABEL_Z + 0.085, CARD_LABEL_Z + 0.75
    bm = D.new_bm()
    for sy in (-1, 1):
        ya, yb = sorted((hy + sy * 14.5, hy + sy * 17.5))
        D.add_box(bm, m(hx + 16.3), m(hx + px1 + rim - 0.4), m(ya), m(yb), m(hz0), m(hz1))
        D.add_box(bm, m(hx + px1 + 0.05), m(hx + px1 + rim - 0.4), m(ya), m(yb),
                  m(rim_top - 0.1), m(hz0 + 0.01))
        ya, yb = sorted((hy + sy * 7.0, hy + sy * 11.0))
        D.add_box(bm, m(hx + px0 - rim + 0.4), m(hx - 15.3), m(ya), m(yb), m(hz0), m(hz1))
        D.add_box(bm, m(hx + px0 - rim + 0.4), m(hx + px0 - 0.05), m(ya), m(yb),
                  m(rim_top - 0.1), m(hz0 + 0.01))
    D.finish('CARD_HOLDER_HOOKS', bm, [plastic], parent=tray)

    # release tongue (+X) with a molded triangle pointing at the card
    tg = HOLD['release_tongue_rel_anchor']
    (tx0, tx1), (ty0, ty1) = tg['x'], tg['y']
    bm = D.new_bm()
    D.add_prism(bm, D.rrect(m(hx + tx0), m(hx + tx1), m(hy + ty0), m(hy + ty1),
                            (0, m(2.0), m(2.0), 0), segs=4),
                m(FLOOR_Z - 0.05), m(tg['top_z']))
    D.finish('CARD_RELEASE_TONGUE', bm, [plastic], smooth_angle=35, parent=tray)
    Mt = D.basis((0, 0, m(tg['top_z'] + 0.04)), (1, 0, 0), (0, 1, 0))
    bm = D.new_bm()
    tcx = hx + (tx0 + tx1) / 2 + 0.8
    D.add_flat(bm, [(m(tcx - 2.6), m(hy)), (m(tcx + 2.0), m(hy - 3.0)), (m(tcx + 2.0), m(hy + 3.0))], Mt)
    D.finish('TRAY_EMBOSS', bm, [emboss], recalc=False, parent=tray)

    # plain-text molded "Nintendo 3DS" on the tray floor (trademark group, hideable)
    prints_root = C.empty('TRADEMARK_PRINTS', parent=root)
    Me = D.basis((0, 0, m(FLOOR_Z + 0.12)), (0, 1, 0), (-1, 0, 0))   # reads bottom -> top
    bm = D.new_bm()
    D.add_text(bm, 'Nintendo 3DS', m(YC), m(-44.0), m(40.0), m(4.6), Me, res=1, fit='width')
    D.finish('TRAY_NINTENDO_3DS_EMBOSS', bm, [emboss], recalc=False, parent=prints_root)

    # film (back), insert back panel, living-hinge web
    box_obj('SLEEVE_BACK', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2, -ZF, -ZF + SLEEVE_T, [sleeve],
            parent=tray)
    box_obj('COVER_ART_BACK', PL_X0, BACK_FREE_X, IY0, IY0 + IH, -ART_Z1, -ART_Z0, [art],
            uv_fn=uv_back, parent=tray)
    box_obj('TRAY_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, H - 0.6, -PL_Z - 0.022, -PL_Z - 0.01,
            [plastic], parent=tray)
    C.empty('CASE_MEDIUM_ANCHOR', parent=tray, location=(m(AX), m(AY), m(AZ)),
            rotation=tuple(ANC['rotation_euler_rad']))

    # ================================================================ spine
    spine_hinge = C.empty('CASE_SPINE_HINGE', parent=root,
                          location=tuple(m(v) for v in BACK_HINGE), rotation=(math.pi, 0, 0))
    spine = C.empty('CASE_SPINE', parent=spine_hinge)
    spine_objs = [rplate('SPINE_PANEL', (PL_X0, PL_X0 + WALL + 0.0, 0, H, -PL_Z, PL_Z,
                                         (1.0, 0, 0, 1.0)), [plastic])]
    C.bevel(spine_objs[0], m(0.35), segments=2, angle_deg=40)
    xi = PL_X0 + WALL                                        # inner spine face -65.85
    bm = D.new_bm()
    for y0, y1 in LAY['spine_tabs_y']:                       # two small molded tabs
        D.add_box(bm, m(xi - 0.05), m(xi + 0.9), m(y0), m(y1), m(-1.6), m(1.6))
    for yr in (21.0, H - 22.0):                              # two short cross ribs
        D.add_box(bm, m(xi - 0.05), m(xi + 0.5), m(yr), m(yr + 1.0), m(-4.2), m(4.2))
    spine_objs.append(D.finish('SPINE_TABS', bm, [plastic]))
    spine_objs.append(box_obj('SLEEVE_SPINE', X0, X0 + SLEEVE_T, 0.2, H - 0.2, -ZF + 0.2, ZF - 0.2,
                              [sleeve]))
    spine_objs.append(box_obj('COVER_ART_SPINE', ART_SPINE_X[0], ART_SPINE_X[1], IY0, IY0 + IH,
                              -PL_Z - 0.05, PL_Z + 0.05, [art], uv_fn=uv_spine))

    # ================================================================ lid
    lid = C.empty('CASE_LID', parent=spine, location=(0, 0, m(BACK_HINGE[2] - FRONT_HINGE[2])))
    notch_l = notch_cutter('LID_NOTCH', fr)
    lz = LAY['lid_floor_z']                                  # +4.35 lid inner floor
    mc = LAY['manual_clips']
    (wx0, wx1), wh = mc['window_x'], mc['window_h']
    cutters = [notch_l]
    for cy in mc['centers_y']:                               # clip windows (0.3 mm skin left)
        cutters.append(rplate(f'LID_CLIP_WIN_{int(cy)}', (wx0, wx1, cy - wh / 2, cy + wh / 2,
                                                          lz - 0.5, PL_Z - 0.3, (1.0,) * 4), []))
    lid_objs = [shell('LID_SHELL',
                      (HALF_X0, X1, 0, H, SPLIT_GAP, PL_Z, (0.3, CORNER_R, CORNER_R, 0.3)),
                      (PL_X0 - 1, X1 - WALL, WALL, H - WALL, -1.0, lz,
                       (0, CORNER_R - WALL, CORNER_R - WALL, 0)), [plastic],
                      extra_cutters=cutters)]
    bm = D.new_bm()
    D.add_box(bm, m(rx0), m(rx1), m(16.0), m(H - 16.0), m(0.8), m(lz + 0.05))
    for y0 in (6.0, H - 12.0):                               # latch keepers opposite the hooks
        D.add_box(bm, m(63.6), m(X1 - WALL + 0.05), m(y0), m(y0 + 6.0), m(1.2), m(lz + 0.05))
    lid_objs.append(D.finish('LID_RAIL', bm, [plastic]))
    # manual clips: tongue from the free-edge side of the window, raised head, lip toward -X
    bm = D.new_bm()
    for cy in mc['centers_y']:
        D.add_prism(bm, D.rrect(m(47.0), m(wx1 + 0.3), m(cy - 3.0), m(cy + 3.0)),
                    m(lz - 0.55), m(PL_Z - 0.25))
        D.add_prism(bm, D.rrect(m(41.0), m(47.5), m(cy - 4.2), m(cy + 4.2), (m(1.0), 0, 0, m(1.0)),
                                segs=4), m(lz - 1.6), m(PL_Z - 0.25))
        D.add_prism(bm, D.rrect(m(38.6), m(41.2), m(cy - 4.2), m(cy + 4.2), (m(1.0), 0, 0, m(1.0)),
                                segs=4), m(lz - 1.6), m(lz - 0.95))
    lid_objs.append(D.finish('LID_CLIPS', bm, [plastic], smooth_angle=35))
    lid_objs.append(box_obj('LID_HINGE_WEB', PL_X0, HALF_X0 + 0.05, 0.6, H - 0.6,
                            PL_Z + 0.01, PL_Z + 0.022, [plastic]))
    lid_objs.append(box_obj('SLEEVE_FRONT', X0 + 0.2, SLEEVE_OPEN_X, 0.2, H - 0.2, ZF - SLEEVE_T, ZF,
                            [sleeve]))
    lid_objs.append(box_obj('COVER_ART', PL_X0, FRONT_FREE_X, IY0, IY0 + IH, ART_Z0, ART_Z1, [art],
                            uv_fn=uv_front))

    for o in spine_objs:
        bake_into(o, spine)
    for o in lid_objs:
        bake_into(o, lid)
    return root


# ------------------------------------------------------------ self check
def case_meshes(root, exclude=()):
    ex = set(exclude)
    return [o for o in C.descendants(root) if o.type == 'MESH' and o not in ex]


def case_groups(root, exclude=()):
    """Case meshes split into the three rigid groups tray / spine / lid."""
    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    lid_set = set(C.descendants(lid))
    spine_set = set(C.descendants(spine)) - lid_set
    groups = {'tray': [], 'spine': [], 'lid': []}
    for o in case_meshes(root, exclude):
        groups['lid' if o in lid_set else 'spine' if o in spine_set else 'tray'].append(o)
    return groups


def _tree(o, dg):
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    vs = [o.matrix_world @ v.co for v in me.vertices]
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    ev.to_mesh_clear()
    return BVHTree.FromPolygons(vs, tris, all_triangles=True), vs


def group_collisions(groups):
    """Pairwise triangle overlaps between meshes of different groups in the current pose."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    trees = {o.name: (g, _tree(o, dg)[0]) for g, objs in groups.items() for o in objs}
    hits = []
    names = list(trees)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if trees[a][0] != trees[b][0] and trees[a][1].overlap(trees[b][1]):
                hits.append(f'{a}x{b}')
    return hits


def bad_tessellation(objs):
    """Meshes whose n-gon triangulation (what USD export writes) does not cover each
    polygon exactly: sum of triangle areas != polygon area (a triangle spilling across a
    hole or a self-overlapping n-gon). Returns [name, ...]."""
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    bad = []
    for o in objs:
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        tri_area = [0.0] * len(me.polygons)
        for t in me.loop_triangles:
            tri_area[t.polygon_index] += t.area
        if any(abs(a - p.area) > 1e-8 + 0.02 * p.area   # 0.01 mm2 / 2 %: non-planar bevel quads pass
               for a, p in zip(tri_area, me.polygons)):
            bad.append(o.name)
        ev.to_mesh_clear()
    return bad


def world_bbox(objs):
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    pts = [v for o in objs for v in _tree(o, dg)[1]]
    return ([min(p[i] for p in pts) / MM for i in range(3)],
            [max(p[i] for p in pts) / MM for i in range(3)])


def import_card(anchor):
    """The app's real 3DS card (Detailed-Cartridges.usdz /root/threeDS, millimetres),
    attached to CASE_MEDIUM_ANCHOR as the app does: position (0, 0, +1.9 mm), scale 0.001.
    Returns (card root object, card mesh objects)."""
    before = set(bpy.data.objects)
    bpy.ops.wm.usd_import(filepath=str(CARD_USDZ), prim_path_mask='/root/threeDS',
                          import_cameras=False, import_lights=False, set_frame_range=False,
                          create_collection=False, create_world_material=False)
    new = set(bpy.data.objects) - before
    card = next(o for o in new if o.name.startswith('threeDS'))
    keep = {card, *card.children_recursive}
    for o in new - keep:
        bpy.data.objects.remove(o, do_unlink=True)
    att = CARD['attach_to_anchor']
    card.parent = anchor
    card.matrix_parent_inverse = Matrix.Identity(4)
    card.location = Vector(att['position_m'])
    card.rotation_euler = tuple(att['rotation_euler_rad'])
    card.scale = (att['uniform_scale'],) * 3
    bpy.context.view_layer.update()
    meshes = [o for o in keep if o.type == 'MESH']
    lo, hi = world_bbox(meshes)
    print('self-check card world bbox mm: ' + ', '.join(f'{a:.3f}..{b:.3f}' for a, b in zip(lo, hi)))
    return card, meshes


def card_proxy():
    """Box proxy of the 3DS card: 33 x 35 x 3.8 body + 1 x 3.6 key tab at +X, top-right."""
    zb, zl = CARD_LABEL_Z - 3.8, CARD_LABEL_Z
    bm = D.new_bm()
    D.add_box(bm, m(AX - 16.5), m(AX + 16.5), m(AY - 17.5), m(AY + 17.5), m(zb), m(zl))
    D.add_box(bm, m(AX + 16.45), m(AX + 17.5), m(AY + 11.2), m(AY + 14.8), m(zb), m(zl))
    return D.finish('_CARD_PROXY', bm, [])


def test_pattern(w_px=1616, h_px=680):
    """Neutral UV test image in insert space (NOT game art) at the GameTDB coverfullHQ size:
    tinted panels (back blue, spine yellow, front green), 10 mm grid, red folds at the
    contract u_splits, a black diagonal and a 45 mm-radius circle centred on the spine
    (must run unbroken across back | spine | front), and a white strip where the app draws
    the vertical NINTENDO 3DS banner (front far right, 14 mm), with a black 'up' arrow."""
    import numpy as np
    u = (np.arange(w_px) + 0.5) / w_px
    v = (np.arange(h_px) + 0.5) / h_px
    U, V = np.meshgrid(u, v)
    img = np.ones((h_px, w_px, 4), dtype=np.float32)
    img[..., :3] = (0.62, 0.75, 0.92)
    img[(U >= S1) & (U < S2), :3] = (0.95, 0.85, 0.45)
    img[U >= S2, :3] = (0.62, 0.90, 0.62)
    xm, ym = U * IW, V * IH
    img[xm > IW - 14.0, :3] = (0.97, 0.97, 0.97)
    px = IW / w_px
    grid = (np.abs((xm + 5) % 10 - 5) < px * 0.8) | (np.abs((ym + 5) % 10 - 5) < px * 0.8)
    img[grid, :3] *= 0.7
    for f in (S1, S2):
        img[np.abs(U - f) * IW < px * 1.2, :3] = (0.85, 0.1, 0.1)
    diag = np.abs(ym - xm * IH / IW) < px * 1.8
    ring = np.abs(np.hypot(xm - (IB + IS / 2), ym - IH / 2) - 45.0) < px * 1.8
    arrow = ((np.abs(xm - (IW - 7.0)) < 0.8) & (ym > 70) & (ym < 100)) | \
            ((ym > 100) & (ym < 108) & (np.abs(xm - (IW - 7.0)) < (108 - ym) * 0.5))
    img[diag | ring | arrow, :3] = 0.05
    im = bpy.data.images.new('UV_TEST_PATTERN', w_px, h_px)
    im.pixels.foreach_set(img.ravel())
    return im


def main():
    C.reset_scene()
    failed = False

    # contract consistency: u_splits must be exactly the insert_mm ratios
    us = SPEC['u_splits']
    ok = abs(us[0] - S1) < 1e-9 and abs(us[1] - S2) < 1e-9
    gp = SPEC['gametdb_coverfullHQ']
    px_err = [abs(S1 * gp['size_px'][0] - gp['splits_px'][0]),
              abs(S2 * gp['size_px'][0] - gp['splits_px'][1])]
    ok &= max(px_err) < 1.0
    print(f'self-check u_splits {S1:.6f} {S2:.6f} (contract {us}); GameTDB fold error px '
          f'{px_err[0]:.2f} {px_err[1]:.2f}: {"ok" if ok else "MISMATCH"}')
    failed |= not ok

    root = build()
    tris = C.triangle_count(C.descendants(root))
    print(f'3DS-Case triangles: {tris} (budget {SPEC["triangle_budget"]})')
    failed |= tris > SPEC['triangle_budget']

    lo, hi = world_bbox(case_meshes(root))
    want = [SPEC['bbox_mm'][k] for k in 'xyz']
    bb_ok = all(abs(lo[i] - want[i][0]) < 0.05 and abs(hi[i] - want[i][1]) < 0.05 for i in range(3))
    print('self-check closed bbox mm: ' + ', '.join(f'{a:.3f}..{b:.3f}' for a, b in zip(lo, hi))
          + f' ({"ok" if bb_ok else "WRONG"})')
    failed |= not bb_ok
    bad = bad_tessellation(case_meshes(root))
    print(f'self-check n-gon tessellation: {"bad " + str(bad) if bad else "ok"}')
    failed |= bool(bad)

    spine, lid = bpy.data.objects['CASE_SPINE'], bpy.data.objects['CASE_LID']
    half = math.pi / 2
    for a, b in ((0, 0), (half, 0), (0, half), (half, half)):
        spine.rotation_euler[1], lid.rotation_euler[1] = a, b
        hits = group_collisions(case_groups(root))
        failed |= bool(hits)
        print(f'self-check spine={a:.4f} lid={b:.4f}: collisions {hits or "none"}')
    lo, hi = world_bbox(case_meshes(root))
    print('self-check fully open bbox mm: ' + ', '.join(f'{a:.2f}..{b:.2f}' for a, b in zip(lo, hi)))
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    if failed:
        print('self-check FAILED')
        sys.exit(1)

    C.export_usdz(root, ASSET_DIR / 'exports/3DS-Case.usdz')

    # contents: the app's real 3DS card at the anchor, plus a box proxy, case closed
    anchor = bpy.data.objects['CASE_MEDIUM_ANCHOR']
    card, card_objs = import_card(anchor)
    cmeshes = case_meshes(root, exclude=card_objs)
    hits = group_collisions({'case': cmeshes, 'card': card_objs})
    failed |= bool(hits)
    print(f'self-check real threeDS card in closed case: collisions {hits or "none"}')
    proxy = card_proxy()
    hits = group_collisions({'case': cmeshes, 'card': [proxy]})
    failed |= bool(hits)
    print(f'self-check 33 x 35 x 3.8 card proxy (+key tab) in closed case: collisions {hits or "none"}')
    bpy.data.objects.remove(proxy, do_unlink=True)
    for a, b in ((half, 0), (0, half), (half, half)):
        spine.rotation_euler[1], lid.rotation_euler[1] = a, b
        hits = group_collisions({'lid+spine': [o for g in ('spine', 'lid')
                                               for o in case_groups(root, card_objs)[g]],
                                 'card': card_objs})
        failed |= bool(hits)
        print(f'self-check card vs lid/spine at spine={a:.4f} lid={b:.4f}: collisions {hits or "none"}')
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    if failed:
        print('self-check FAILED')
        sys.exit(1)
    print('self-check passed')

    import shutil
    shutil.copyfile(ASSET_DIR / 'exports/3DS-Case.usdz', RUNTIME_USDZ)
    print(f'copied to {RUNTIME_USDZ}')

    # ------------------------------------------------------------ renders
    cam = D.setup_render(res=(1024, 768), samples=48, world_rgb=(0.16, 0.165, 0.18))
    tgt = (0.0, m(YC), 0.0)
    D.area_light('KeyLight', (-0.15, 0.30, 0.38), tgt, 0.3, 1.6)
    D.area_light('FillLight', (0.30, 0.05, 0.10), tgt, 0.4, 0.5)
    D.look_at(cam, (0.15, 0.21, 0.23), (-0.004, m(YC) - 0.004, 0.0))   # front + top + free edge
    D.render(ASSET_DIR / 'renders/case_closed.png')
    D.look_at(cam, (-0.17, 0.125, 0.25), (0.0, m(YC) - 0.001, 0.0))   # front + spine
    D.render(ASSET_DIR / 'renders/case_closed_spine.png')

    spine.rotation_euler[1] = lid.rotation_euler[1] = half
    ox = (X1 + (X1 - W - T - W)) / 2 * MM                  # centre of the open spread
    D.area_light('KeyLight', (ox + 0.02, 0.20, 0.45), (ox, m(YC), 0), 0.5, 2.2)
    D.area_light('FillLight', (ox - 0.25, -0.05, 0.25), (ox, m(YC), 0), 0.5, 0.5)
    D.look_at(cam, (ox, m(YC) - 0.12, 0.40), (ox, m(YC) - 0.004, -0.004))
    D.render(ASSET_DIR / 'renders/case_open.png')
    D.look_at(cam, (m(AX) - 0.03, m(AY) - 0.075, 0.12), (m(AX) + 0.006, m(AY), m(AZ)))
    D.render(ASSET_DIR / 'renders/case_open_holder_detail.png')

    # render-only UV proof: test pattern through the three insert meshes
    im = test_pattern()
    tm = bpy.data.materials.new('UV_TEST')
    tm.use_nodes = True
    nt = tm.node_tree
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = im
    nt.links.new(tex.outputs['Color'], nt.nodes['Principled BSDF'].inputs['Base Color'])
    nt.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.45
    arts = [bpy.data.objects[n] for n in ('COVER_ART', 'COVER_ART_SPINE', 'COVER_ART_BACK')]
    for o in arts:
        o.data.materials[0] = tm
    # outside of the fully open case = the insert laid flat (back | spine | front)
    D.area_light('UnderKey', (ox, m(YC) + 0.05, -0.5), (ox, m(YC), 0), 0.6, 2.4)
    D.look_at(cam, (ox, m(YC), -0.62), (ox, m(YC), 0.0))
    D.render(ASSET_DIR / 'renders/case_open_cover_outside.png')
    bpy.data.objects.remove(bpy.data.objects['UnderKey'], do_unlink=True)
    spine.rotation_euler[1] = lid.rotation_euler[1] = 0.0
    D.area_light('KeyLight', (-0.15, 0.30, 0.38), tgt, 0.3, 1.6)
    D.area_light('FillLight', (0.30, 0.05, 0.10), tgt, 0.4, 0.5)
    D.look_at(cam, (-0.17, 0.125, 0.25), (0.0, m(YC) - 0.001, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed_cover.png')
    D.look_at(cam, (0.17, 0.10, -0.25), (0.0, m(YC) - 0.001, 0.0))
    D.area_light('BackKey', (0.15, 0.30, -0.38), tgt, 0.3, 1.6)
    D.render(ASSET_DIR / 'renders/case_closed_cover_back.png')
    bpy.data.objects.remove(bpy.data.objects['BackKey'], do_unlink=True)
    art_default = bpy.data.materials['COVER_ART_default']
    for o in arts:
        o.data.materials[0] = art_default
    bpy.data.materials.remove(tm)
    bpy.data.images.remove(im)
    blend = ASSET_DIR / '3DS_Case.blend'
    blend.unlink(missing_ok=True)                            # no stale .blend1 backups
    C.save_blend(blend)


if __name__ == '__main__':
    main()
