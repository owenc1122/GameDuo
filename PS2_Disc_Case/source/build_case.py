"""US (NTSC-U/C) PS2 DVD keep case, runtime model `PS2-Case`.

Run from the repo root (after build_dvd.py, whose helpers and disc it reuses):
    Blender -b --factory-startup --python-exit-code 1 --python PS2_Disc_Case/source/build_case.py

Frame (contract_parts/PS2-Case.json): case closed, standing, front cover +Z,
spine on -X, root PS2_CASE = bottom-centre of the bbox: X [-67.5, 67.5],
Y [0, 190], Z [-7, 7]. Split plane Z = 0.

Nodes
  PS2_CASE                        root empty
    CASE_TRAY                     empty: static back half
      TRAY_SHELL, TRAY_SPINE      black PP back tray + full-height spine wall
      HUB_ROSETTE                 disc seat, 6 rosette fingers, triangular PUSH button
      DISC_RING                   4 raised retaining arcs around the disc
      MEMCARD_HOLDER(_EMBOSS)     corner brackets + embossed PS logo / text / arrow
      SLEEVE_BACK                 clear overwrap, back + spine part
      COVER_ART_BACK              insert back panel + spine (same 0-1 insert UV space)
      CASE_DISC_ANCHOR            empty at the hub, disc centre; rotated +90 deg about X
                                  so the disc's +Y (label) faces +Z (toward the lid)
    TRADEMARK_PRINTS              empty: spine prints (black band, white box + colour
                                  PS logo, vertical "PlayStation 2")
    CASE_LID_HINGE                empty ON the hinge axis (X -67.5, Z 0: outer spine face,
                                  mid-thickness), rotated pi about X so its local +Y
                                  = world -Y (contract hinge_axis_dir [0,-1,0])
      CASE_LID                    empty, identity rest transform = runtime pivot;
                                  +rot_y opens: free edge (+X) swings toward +Z, and at
                                  pi the lid lies flat at -X, inner face up, level
                                  with the tray (outer faces both at Z = -7)
        LID_SHELL, LID_CLIPS      front half + 2 manual clips on the inner free edge
        SLEEVE_FRONT              clear overwrap, front part
        COVER_ART                 insert front panel (UV 0.5256-1 of the insert image)
        TRADEMARK_PRINTS_LID      empty: black top banner, white wordmark, colour PS logo

Insert UV space (one image for COVER_ART + COVER_ART_BACK), 273 x 183 mm:
  u = 0 .. 0.4744 back panel | 0.4744 .. 0.5256 spine | 0.5256 .. 1 front panel,
  v = 0 bottom .. 1 top (insert Y 3.5 .. 186.5 mm).
The spine stays with the tray (single-axis hinge model), so the spine strip of the
insert lives in COVER_ART_BACK; COVER_ART holds the front panel only.
"""
import importlib.util
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix

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
PL_X0 = -67.05                    # plastic spine outer face
PL_Z = 6.55                       # plastic outer front/back faces
WALL = 1.3
SPLIT_GAP = 0.05                  # tray walls stop at -0.05, lid walls start at +0.05
LID_X0 = -65.7                    # lid spine-side edge (tray spine wall inner face -65.75)
ART_Z0, ART_Z1 = 6.58, 6.66       # cover art (front/back) depth
ART_SPINE_X = (-67.15, -67.08)
BANNER_Z = 6.70
PRINT_Z = 6.74
SPINE_BAND_X = -67.19
SPINE_BOX_X = -67.22
SPINE_TOP_X = -67.25
INSERT_W, INSERT_H = 273.0, 183.0
INSERT_Y0 = 3.5
HINGE = (-67.5, 95.0, 0.0)


def m(v):
    return v * MM


def box_obj(name, x0, x1, y0, y1, z0, z1, mats, uv_fn=None, parent=None):
    bm = D.new_bm()
    D.add_box(bm, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1))
    return D.finish(name, bm, mats, uv_fn=uv_fn, parent=parent)


def shell(name, outer, inner, mats, parent):
    """Rounded plate minus rounded cavity; outer/inner = (x0,x1,y0,y1,z0,z1,radii) mm."""
    def mk(nm, spec):
        x0, x1, y0, y1, z0, z1, radii = spec
        return D.plate(nm, m(x0), m(x1), m(y0), m(y1), m(z0), m(z1),
                       tuple(m(r) for r in radii), segs=5, mats=mats)
    obj = mk(name, outer)
    C.boolean(obj, mk(name + '_cut', inner))
    C.set_parent(obj, parent)
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


# insert UV (x, y, z in metres)
def uv_front(co):
    return (0.5256 + (co.x / MM - X0) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def uv_back(co):
    return ((62.0 - co.x / MM) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def uv_spine(co):
    return (0.4744 + (co.z / MM + ZF) / INSERT_W, (co.y / MM - INSERT_Y0) / INSERT_H)


def build():
    spec = C.load_contract('PS2-Case')
    L, col = spec['layout'], spec['colors']
    plastic = C.mat('CASE_plastic', C.hex_rgba(col['case_plastic']), rough=0.55)
    emboss = C.mat('CASE_emboss', C.hex_rgba('#34343A'), rough=0.5)
    # neutral-grey tint so the film reads as gloss, not a white veil over black PP
    sleeve = C.mat('CASE_sleeve', C.hex_rgba('#9A9A9A'), rough=0.04, alpha=0.12)
    art = C.mat('COVER_ART_default', C.hex_rgba('#EDEDED'), rough=0.6)
    ink_banner = C.mat('PRINT_banner_black', C.hex_rgba(col['banner']), rough=0.45)
    ink_white = C.mat('PRINT_wordmark_white', C.hex_rgba(col['wordmark']), rough=0.45)
    ps_cols = [C.mat(f'PRINT_ps_{k}', C.hex_rgba(col[f'ps_{k}']), rough=0.45)
               for k in ('red', 'yellow', 'green', 'blue')]
    box_white = C.mat('PRINT_logo_box_white', C.hex_rgba(col['spine_logo_box']), rough=0.45)

    root = C.empty('PS2_CASE')

    # ================================================================ tray
    tray = C.empty('CASE_TRAY', parent=root)
    shell('TRAY_SHELL',
          (PL_X0, X1, 0, 190, -PL_Z, -SPLIT_GAP, (1.0, 3.0, 3.0, 1.0)),
          (PL_X0 + WALL, X1 - WALL, WALL, 190 - WALL, -PL_Z + WALL, 1.0, (0.3, 1.7, 1.7, 0.3)),
          [plastic], tray)
    spine = D.plate('TRAY_SPINE', m(PL_X0), m(PL_X0 + WALL), 0, m(190), m(-0.5), m(PL_Z),
                    (m(1.0), 0, 0, m(1.0)), mats=[plastic])
    C.set_parent(spine, tray)
    floor_z = -PL_Z + WALL                                   # -5.25

    # hub: base disc, seat (disc rests on its top), 6 rosette fingers, PUSH button
    hub = L['hub']
    hx, hy = hub['center_mm'][0], hub['center_mm'][1]
    seat_z = hub['disc_seat_z_mm']                           # -3.2
    bm = D.new_bm()
    D.add_prism(bm, [(m(x), m(y)) for x, y in circle(hx, hy, hub['platform_d_mm'] / 2)],
                m(floor_z - 0.05), m(floor_z + 0.6))
    D.add_prism(bm, [(m(x), m(y)) for x, y in circle(hx, hy, 16.5)],
                m(floor_z + 0.6), m(seat_z))
    for k in range(hub['rosette_fingers']):
        a = math.radians(30 + 60 * k)
        R = Matrix.Translation((m(hx), m(hy), 0)) @ Matrix.Rotation(a, 4, 'Z')
        D.add_box(bm, m(4.0), m(7.3), m(-1.4), m(1.4), m(seat_z - 0.05), m(-1.35), R)
        D.add_box(bm, m(6.6), m(7.8), m(-1.4), m(1.4), m(-1.9), m(-1.35), R)
    tri = [(m(hx + 3.6 * math.cos(math.radians(90 + 120 * k))),
            m(hy + 3.6 * math.sin(math.radians(90 + 120 * k)))) for k in range(3)]
    D.add_prism(bm, tri, m(seat_z - 0.05), m(-1.6))
    D.finish('HUB_ROSETTE', bm, [plastic], smooth_angle=35, parent=tray)

    # segmented retaining ring around the disc
    ring = L['disc_ring']
    bm = D.new_bm()
    r0, r1 = ring['inner_d_mm'] / 2, ring['outer_d_mm'] / 2
    for c in (45, 135, 225, 315):
        D.add_arc(bm, m(hx), m(hy), m(r0), m(r1), math.radians(c - 25), math.radians(c + 25),
                  m(floor_z - 0.05), m(floor_z + ring['height_above_floor_mm']), n=12)
    D.finish('DISC_RING', bm, [plastic], smooth_angle=35, parent=tray)

    # memory-card holder: 4 corner L-brackets + flat emboss (logo, arrow, text)
    mc = L['memory_card_holder']
    (mx, my), (mw, mh) = mc['center_mm'], mc['outer_size_mm']
    top = floor_z + mc['wall_height_mm']
    t = 1.2
    bm = D.new_bm()
    for sx in (-1, 1):
        for sy in (-1, 1):
            cx, cy = mx + sx * mw / 2, my + sy * mh / 2
            ax = sorted((cx, cx - sx * 17))
            ay = sorted((cy, cy - sy * 12))
            D.add_box(bm, m(ax[0]), m(ax[1]), m(min(cy, cy - sy * t)), m(max(cy, cy - sy * t)),
                      m(floor_z - 0.05), m(top))
            D.add_box(bm, m(min(cx, cx - sx * t)), m(max(cx, cx - sx * t)), m(ay[0]), m(ay[1]),
                      m(floor_z - 0.05), m(top))
    D.finish('MEMCARD_HOLDER', bm, [plastic], parent=tray)
    Me = D.basis((0, 0, m(floor_z + 0.15)), (1, 0, 0), (0, 1, 0))
    bm = D.new_bm()
    D.add_ps_logo(bm, m(mx + 3), m(my + 7.5), m(13.0), m(9.0), Me)
    D.add_flat(bm, [(m(mx - 22), m(my + 7.5)), (m(mx - 17.5), m(my + 4.5)),
                    (m(mx - 17.5), m(my + 10.5))], Me)
    D.add_text(bm, 'MEMORY CARD', m(mx + 1), m(my - 5.5), m(30.0), m(3.4), Me, res=1)
    D.add_text(bm, 'HOLDER', m(mx + 1), m(my - 10.5), m(16.5), m(3.4), Me, res=1)
    D.finish('MEMCARD_EMBOSS', bm, [emboss], recalc=False, parent=tray)

    # sleeve (back + spine) and insert (back + spine)
    bm = D.new_bm()
    D.add_box(bm, m(X0 + SLEEVE_T), m(X1), m(0.2), m(189.8), m(-ZF), m(-ZF + SLEEVE_T))
    D.add_box(bm, m(X0), m(X0 + SLEEVE_T), m(0.2), m(189.8), m(-ZF), m(ZF))
    D.finish('SLEEVE_BACK', bm, [sleeve], parent=tray)
    bm = D.new_bm()
    D.add_box(bm, m(PL_X0), m(62.0), m(INSERT_Y0), m(186.5), m(-ART_Z1), m(-ART_Z0))
    D.add_box(bm, m(ART_SPINE_X[0]), m(ART_SPINE_X[1]), m(INSERT_Y0), m(186.5), m(-6.6), m(6.6))
    obj = D.finish('COVER_ART_BACK', bm, [art], parent=tray)
    # per-face UV: spine faces (x < plastic spine face) use the spine mapping
    uvl = obj.data.uv_layers.active.data
    for poly in obj.data.polygons:
        spine_face = all(obj.data.vertices[v].co.x < m(PL_X0 - 0.01) for v in poly.vertices)
        for li in poly.loop_indices:
            co = obj.data.vertices[obj.data.loops[li].vertex_index].co
            uvl[li].uv = uv_spine(co) if spine_face else uv_back(co)

    C.empty('CASE_DISC_ANCHOR', parent=tray,
            location=(m(hx), m(hy), m(seat_z + 0.6)), rotation=(math.pi / 2, 0, 0))

    # spine prints (static)
    prints = C.empty('TRADEMARK_PRINTS', parent=root)
    sb = L['spine_banner']
    Ms = D.basis((m(SPINE_BAND_X), 0, 0), (0, 0, 1), (0, 1, 0))   # local x=+Z, y=+Y, normal -X
    bm = D.new_bm()
    y0, y1 = sb['band_y_mm']
    D.add_flat(bm, [(m(-6.6), m(y0)), (m(6.6), m(y0)), (m(6.6), m(y1)), (m(-6.6), m(y1))], Ms)
    D.finish('SPINE_BAND', bm, [ink_banner], recalc=False, parent=prints)
    lb = sb['logo_box']
    (bz, by), (bw, bh) = lb['center_zy_mm'], lb['size_mm']
    Mb = D.basis((m(SPINE_BOX_X), 0, 0), (0, 0, 1), (0, 1, 0))
    bm = D.new_bm()
    D.add_flat(bm, [(m(bz - bw / 2), m(by - bh / 2)), (m(bz + bw / 2), m(by - bh / 2)),
                    (m(bz + bw / 2), m(by + bh / 2)), (m(bz - bw / 2), m(by + bh / 2))], Mb)
    D.finish('SPINE_LOGO_BOX', bm, [box_white], recalc=False, parent=prints)
    Mt = D.basis((m(SPINE_TOP_X), 0, 0), (0, 0, 1), (0, 1, 0))
    bm = D.new_bm()
    D.add_ps_logo(bm, m(bz), m(by), m(8.2), m(7.0), Mt, mis=(0, 1, 3, 2))
    D.finish('SPINE_PS_LOGO', bm, ps_cols, recalc=False, parent=prints)
    wm = sb['wordmark']
    Mw = D.basis((m(SPINE_BOX_X), 0, 0), (0, -1, 0), (0, 0, 1))  # reads downward, up = +Z
    bm = D.new_bm()
    wz, wy = wm['center_zy_mm']
    D.add_text(bm, wm['text'], m(-wy), m(wz), m(wm['length_mm']), m(wm['height_mm']), Mw)
    D.finish('SPINE_WORDMARK', bm, [ink_white], recalc=False, parent=prints)

    # ================================================================ lid
    hinge = C.empty('CASE_LID_HINGE', parent=root, location=tuple(m(v) for v in HINGE),
                    rotation=(math.pi, 0, 0))
    lid = C.empty('CASE_LID', parent=hinge)
    lid_objs = []
    lid_objs.append(shell('LID_SHELL',
                          (LID_X0, X1, 0, 190, SPLIT_GAP, PL_Z, (0.3, 3.0, 3.0, 0.3)),
                          (PL_X0 - 1, X1 - WALL, WALL, 190 - WALL, -1.0, PL_Z - WALL,
                           (0, 1.7, 1.7, 0)), [plastic], root))
    cl = L['clips']
    bm = D.new_bm()
    z1 = PL_Z - WALL - cl['gap_above_lid_floor_mm']
    for cx, cy in cl['centers_mm']:
        hw = cl['width_y_mm'] / 2
        D.add_prism(bm, D.rrect(m(cl['x_span_mm'][0]), m(X1 - WALL + 0.3), m(cy - hw), m(cy + hw),
                                (m(hw), 0, 0, m(hw)), segs=6),
                    m(z1 - cl['thickness_mm']), m(z1))
    lid_objs.append(D.finish('LID_CLIPS', bm, [plastic], smooth_angle=35))
    lid_objs.append(box_obj('SLEEVE_FRONT', X0 + 0.2, X1, 0.2, 189.8, ZF - SLEEVE_T, ZF, [sleeve]))
    lid_objs.append(box_obj('COVER_ART', PL_X0, 62.0, INSERT_Y0, 186.5, ART_Z0, ART_Z1, [art],
                            uv_fn=uv_front))
    lid_prints = C.empty('TRADEMARK_PRINTS_LID', parent=lid)
    lg = L['logo']
    br = lg['banner_rect_mm']
    Mf = D.basis((0, 0, m(BANNER_Z)), (1, 0, 0), (0, 1, 0))
    bm = D.new_bm()
    D.add_flat(bm, [(m(PL_X0), m(br['y'][0])), (m(br['x'][1]), m(br['y'][0])),
                    (m(br['x'][1]), m(br['y'][1])), (m(PL_X0), m(br['y'][1]))], Mf)
    banner = D.finish('FRONT_BANNER', bm, [ink_banner], recalc=False)
    Mp = D.basis((0, 0, m(PRINT_Z)), (1, 0, 0), (0, 1, 0))
    w = lg['wordmark']
    bm = D.new_bm()
    D.add_text(bm, w['text'], m(w['center_mm'][0]), m(w['center_mm'][1]),
               m(w['size_mm'][0]), m(w['size_mm'][1]), Mp)
    wordmark = D.finish('FRONT_WORDMARK', bm, [ink_white], recalc=False)
    p = lg['ps_symbol']
    bm = D.new_bm()
    D.add_ps_logo(bm, m(p['center_mm'][0]), m(p['center_mm'][1]), m(p['size_mm'][0]),
                  m(p['size_mm'][1]), Mp, mis=(0, 1, 3, 2))
    logo = D.finish('FRONT_PS_LOGO', bm, ps_cols, recalc=False)
    for o in lid_objs:
        bake_into(o, lid)
    for o in (banner, wordmark, logo):
        bake_into(o, lid_prints)
    return root


def main():
    C.reset_scene()
    root = build()
    print(f'PS2-Case triangles: {C.triangle_count(C.descendants(root))}')
    C.export_usdz(root, ASSET_DIR / 'exports/PS2-Case.usdz')

    # .blend: the disc sits on the hub anchor (not part of the export)
    disc = D.build()
    C.set_parent(disc, bpy.data.objects['CASE_DISC_ANCHOR'], keep_world=False)
    disc.location, disc.rotation_euler = (0, 0, 0), (0, 0, 0)

    cam = D.setup_render(res=(1024, 768), samples=32)
    D.area_light('KeyLight', (-0.2, 0.45, 0.55), (0, 0.095, 0), 0.4, 5)
    D.area_light('FillLight', (0.45, 0.25, 0.35), (0, 0.095, 0), 0.5, 2)
    D.look_at(cam, (-0.26, 0.19, 0.38), (0.0, 0.094, 0.0))
    D.render(ASSET_DIR / 'renders/case_closed.png')

    lid = bpy.data.objects['CASE_LID']
    lid.rotation_euler[1] = math.pi
    D.area_light('KeyLight', (0.05, 0.3, 0.6), (-0.0675, 0.095, 0), 0.5, 5)
    D.look_at(cam, (-0.06, 0.02, 0.52), (-0.0675, 0.093, -0.005))
    D.render(ASSET_DIR / 'renders/case_open.png')
    lid.rotation_euler[1] = 0.0
    C.save_blend(ASSET_DIR / 'PS2_Disc_Case.blend')


if __name__ == '__main__':
    main()
