"""Tests for tools/ps2_blender/common.py.

Run:  $B --python tools/ps2_blender/tests/test_common.py
Exit code 1 on any failure. Outputs go to tools/ps2_blender/tests/out/.
"""
import json
import math
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import common as C  # noqa: E402

OUT = HERE / 'out'
OUT.mkdir(parents=True, exist_ok=True)
FAILS = []


def close(a, b, tol=1e-5):
    return all(abs(x - y) <= tol for x, y in zip(a, b)) and len(a) == len(b)


def bbox_size(obj):
    vs = [v.co for v in obj.data.vertices]
    return [max(v[i] for v in vs) - min(v[i] for v in vs) for i in range(3)]


def test(fn):
    try:
        fn()
        print('PASS', fn.__name__)
    except Exception:
        FAILS.append(fn.__name__)
        print('FAIL', fn.__name__)
        traceback.print_exc()
    return fn


@test
def hex_rgba_converts_srgb_to_linear():
    assert close(C.hex_rgba('#000000'), (0, 0, 0, 1))
    assert close(C.hex_rgba('#FFFFFF', 0.5), (1, 1, 1, 0.5))
    assert close(C.hex_rgba('#808080'), (0.215861, 0.215861, 0.215861, 1))
    assert close(C.hex_rgba('0A1B2C'), (0.003035, 0.010960, 0.025187, 1))


@test
def reset_scene_is_empty_metric():
    C.reset_scene()
    u = bpy.context.scene.unit_settings
    assert len(bpy.data.objects) == 0
    assert u.system == 'METRIC' and u.scale_length == 1.0


@test
def rounded_box_has_exact_size():
    C.reset_scene()
    box = C.rounded_box('BOX', (0.301, 0.078, 0.182), 0.004, segments=3, location=(0.1, 0, 0))
    assert close(bbox_size(box), (0.301, 0.078, 0.182)), bbox_size(box)
    assert len(box.data.vertices) > 8, 'bevel not applied'
    assert not box.modifiers and close(box.location, (0.1, 0, 0))


@test
def cylinder_axis_is_z_front():
    C.reset_scene()
    cyl = C.cylinder('CYL', 0.06, 0.0012, verts=64)
    assert close(bbox_size(cyl), (0.12, 0.12, 0.0012), 1e-4), bbox_size(cyl)


@test
def mat_sets_preview_surface_inputs():
    m = C.mat('M_Test', C.hex_rgba('#336699'), rough=0.3, metal=0.8, alpha=0.4,
              emit=(1, 0, 0, 1), emit_strength=2.0)
    p = m.node_tree.nodes['Principled BSDF'].inputs
    assert close(p['Base Color'].default_value, C.hex_rgba('#336699'))
    assert close([p['Roughness'].default_value, p['Metallic'].default_value,
                  p['Alpha'].default_value, p['Emission Strength'].default_value],
                 [0.3, 0.8, 0.4, 2.0])
    assert C.mat('M_Test', (1, 1, 1, 1)) is m  # same name -> reused


@test
def set_parent_keeps_world_position():
    C.reset_scene()
    parent = C.empty('PARENT', location=(0.1, 0.2, 0.3), rotation=(0.3, 0.5, 0.7))
    child = C.empty('CHILD', location=(0.5, -0.1, 0.25))
    C.set_parent(child, parent, keep_world=True)
    bpy.context.view_layer.update()
    assert close(child.matrix_world.translation, (0.5, -0.1, 0.25))
    assert child.matrix_parent_inverse == Matrix.Identity(4)
    local = parent.matrix_world.inverted() @ Vector((0.5, -0.1, 0.25))
    assert close(child.location, local)
    other = C.empty('OTHER', location=(0.01, 0.02, 0.03))
    C.set_parent(other, parent, keep_world=False)
    assert close(other.location, (0.01, 0.02, 0.03))
    nested = C.empty('NESTED', parent, (0, 0.01, 0))
    bpy.context.view_layer.update()
    assert close(nested.matrix_world.translation, parent.matrix_world @ Vector((0, 0.01, 0)))


@test
def apply_all_bakes_scale_and_modifiers_keeps_pivot():
    C.reset_scene()
    box = C.rounded_box('BOX', (0.1, 0.1, 0.1), 0)
    box.location, box.rotation_euler, box.scale = (0.1, 0.2, 0.3), (0, 0.4, 0), (2, 1, 0.5)
    C.bevel(box, 0.005, 2)
    kid = C.empty('KID', box, (0.05, 0, 0))
    bpy.context.view_layer.update()
    kid_world = kid.matrix_world.copy()
    tris_before = C.triangle_count(box)
    C.apply_all(box)
    bpy.context.view_layer.update()
    assert not box.modifiers and tuple(box.scale) == (1, 1, 1)
    assert close(box.location, (0.1, 0.2, 0.3)) and close(box.rotation_euler, (0, 0.4, 0))
    assert close(bbox_size(box), (0.2, 0.1, 0.05)), bbox_size(box)
    assert all(close(a, b) for a, b in zip(kid.matrix_world, kid_world))
    assert C.triangle_count(box) == tris_before > 12


@test
def boolean_cuts_and_removes_cutter():
    C.reset_scene()
    box = C.rounded_box('BOX', (0.1, 0.1, 0.1), 0.002)
    before = len(box.data.polygons)
    hole = C.cylinder('HOLE', 0.02, 0.2)
    C.boolean(box, hole)
    assert 'HOLE' not in bpy.data.objects and not box.modifiers
    assert len(box.data.polygons) > before
    assert close(bbox_size(box), (0.1, 0.1, 0.1))


@test
def load_contract_merges_parts():
    import tempfile
    d = Path(tempfile.mkdtemp())
    (d / 'contract_parts').mkdir()
    (d / 'contract.json').write_text(json.dumps({'tolerance_mm': 0.5, 'assets': {
        'PS2-X': {'root': 'PS2_X', 'size_mm': [0, 0, 0], 'layout': {'a': 1, 'b': 2}}}}))
    (d / 'contract_parts' / 'PS2-X.json').write_text(json.dumps(
        {'size_mm': [10, 20, 30], 'layout': {'b': 3}, 'tray_travel_m': 0.1}))
    saved, C.CONTRACT_DIR = C.CONTRACT_DIR, d
    try:
        c = C.load_contract('PS2-X')
    finally:
        C.CONTRACT_DIR = saved
    assert c == {'tolerance_mm': 0.5, 'root': 'PS2_X', 'size_mm': [10, 20, 30],
                 'layout': {'a': 1, 'b': 3}, 'tray_travel_m': 0.1, 'name': 'PS2-X'}, c


@test
def apply_all_copies_shared_data_and_fixes_negative_scale():
    C.reset_scene()
    a = C.rounded_box('A', (0.1, 0.1, 0.1), 0)
    b = bpy.data.objects.new('B', a.data)
    bpy.context.scene.collection.objects.link(b)
    a.scale = (-2, 1, 1)
    C.apply_all(a)
    assert a.data is not b.data
    assert close(bbox_size(b), (0.1, 0.1, 0.1)) and close(bbox_size(a), (0.2, 0.1, 0.1))
    assert all(p.normal.dot(p.center) > 0 for p in a.data.polygons), 'normals flipped inward'


@test
def subdivision_is_baked_at_render_level():
    from pxr import Usd, UsdGeom
    C.reset_scene()
    root = C.empty('SUB_ROOT')
    cube = C.rounded_box('SUB_CUBE', (0.1, 0.1, 0.1), 0)
    C.set_parent(cube, root)
    sub = cube.modifiers.new('Subsurf', 'SUBSURF')
    sub.levels, sub.render_levels = 0, 2
    assert C.triangle_count(cube) == 6 * 16 * 2 == 192
    # A live boolean cutter parented under the root is skipped, not exported.
    cutter = C.cylinder('SUB_CUTTER', 0.01, 0.3)
    C.set_parent(cutter, root)
    C.boolean(cube, cutter, apply=False)
    tris = C.triangle_count(cube)
    path = C.export_usdz(root, OUT / 'test_subsurf.usdz')
    stage = Usd.Stage.Open(str(path))
    mesh = UsdGeom.Mesh(stage.GetPrimAtPath('/SUB_ROOT/SUB_CUBE'))
    counts = mesh.GetFaceVertexCountsAttr().Get()
    assert set(counts) == {3} and len(counts) == tris > 192, (len(counts), tris)
    assert mesh.GetSubdivisionSchemeAttr().Get() == 'none'
    assert not stage.GetPrimAtPath('/SUB_ROOT/SUB_CUTTER')


@test
def export_rejects_bad_roots_and_unhides():
    C.reset_scene()
    root = C.empty('R', location=(0.01, 0, 0))
    try:
        C.export_usdz(root, OUT / 'bad.usdz')
        raise AssertionError('root off origin accepted')
    except ValueError:
        pass
    root.location = (0, 0, 0)
    hidden = C.rounded_box('HIDDEN', (0.01, 0.01, 0.01), 0)
    C.set_parent(hidden, root)
    hidden.hide_viewport = True
    hidden.hide_set(True)
    from pxr import Usd
    stage = Usd.Stage.Open(str(C.export_usdz(root, OUT / 'test_hidden.usdz')))
    assert stage.GetPrimAtPath('/R/HIDDEN'), 'viewport-hidden object dropped'
    hidden.hide_render = True
    try:
        C.export_usdz(root, OUT / 'bad.usdz')
        raise AssertionError('hide_render descendant accepted')
    except ValueError:
        pass


@test
def opacity_fix_raises_for_missing_material():
    from pxr import Usd
    C.reset_scene()
    obj = C.assign(C.rounded_box('GLASSY', (0.01, 0.01, 0.01), 0), C.mat('Glassy', (1, 1, 1, 1), alpha=0.5))
    try:
        C._fix_opacity(Usd.Stage.CreateInMemory(), [obj])
        raise AssertionError('missing translucent material not reported')
    except RuntimeError:
        pass


def build_export_scene():
    """ASSET_ROOT (origin) > BODY (mesh w/ children) > LID_PIVOT (empty) > LID;
    FRONT_MARKER sits 5 cm in front (+Z) and 1 cm above the origin."""
    C.reset_scene()
    root = C.empty('ASSET_ROOT')
    body = C.rounded_box('BODY', (0.1, 0.04, 0.08), 0.003)
    C.set_parent(body, root)
    C.assign(body, C.mat('Body_Grey', C.hex_rgba('#8A8D91'), rough=0.45))
    pivot = C.empty('LID_PIVOT', body, (0, 0.02, -0.04), (math.radians(-20), 0, 0))
    lid = C.rounded_box('LID', (0.1, 0.004, 0.08), 0.001, location=(0, 0.002, 0.04))
    C.set_parent(lid, pivot, keep_world=False)
    C.assign(lid, C.mat('Lid_Clear', (0.9, 0.95, 1.0, 1), rough=0.1, alpha=0.3))
    marker = C.rounded_box('FRONT_MARKER', (0.01, 0.01, 0.01), 0.001, location=(0, 0.01, 0.05))
    C.set_parent(marker, root)
    C.assign(marker, C.mat('Marker_Red', C.hex_rgba('#FF0000'), emit=(1, 0, 0, 1)))
    return root


@test
def export_usdz_and_reimport():
    from pxr import Usd, UsdGeom, UsdShade
    root = build_export_scene()
    tris = C.triangle_count(C.descendants(root))
    assert tris > 0
    path = C.export_usdz(root, OUT / 'test_common.usdz')
    assert path.exists() and path.stat().st_size > 0
    C.save_blend(OUT / 'test_common.blend')

    stage = Usd.Stage.Open(str(path))
    assert UsdGeom.GetStageUpAxis(stage) == 'Y'
    assert UsdGeom.GetStageMetersPerUnit(stage) == 1.0
    assert stage.GetDefaultPrim().GetPath() == '/ASSET_ROOT'
    prims = {str(p.GetPath()): p.GetTypeName() for p in stage.Traverse()}
    for p, t in {'/ASSET_ROOT': 'Xform', '/ASSET_ROOT/BODY': 'Xform',
                 '/ASSET_ROOT/BODY/BODY_mesh': 'Mesh', '/ASSET_ROOT/BODY/LID_PIVOT': 'Xform',
                 '/ASSET_ROOT/BODY/LID_PIVOT/LID': 'Mesh', '/ASSET_ROOT/FRONT_MARKER': 'Mesh'}.items():
        assert prims.get(p) == t, (p, prims)
    cache = UsdGeom.XformCache()
    at = lambda p: tuple(cache.GetLocalToWorldTransform(stage.GetPrimAtPath(p)).ExtractTranslation())
    assert close(at('/ASSET_ROOT/FRONT_MARKER'), (0, 0.01, 0.05)), at('/ASSET_ROOT/FRONT_MARKER')
    assert close(at('/ASSET_ROOT/BODY/LID_PIVOT'), (0, 0.02, -0.04))
    usd_tris = 0
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            counts = UsdGeom.Mesh(prim).GetFaceVertexCountsAttr().Get()
            assert set(counts) == {3}, f'{prim.GetPath()} not triangulated'
            usd_tris += len(counts)
    assert usd_tris == tris, (usd_tris, tris)
    shader = UsdShade.Shader(stage.GetPrimAtPath('/_materials/Lid_Clear/Principled_BSDF'))
    assert abs(shader.GetInput('opacity').Get() - 0.3) < 1e-6
    bound = UsdGeom.BBoxCache(Usd.TimeCode.Default(), ['default']).ComputeWorldBound(
        stage.GetPrimAtPath('/ASSET_ROOT/FRONT_MARKER')).ComputeAlignedRange()
    assert close(bound.GetMin(), (-0.005, 0.005, 0.045)) and close(bound.GetMax(), (0.005, 0.015, 0.055))
    print(f'  usd: upAxis=Y mpu=1 prims={sorted(prims)} tris={usd_tris}')

    # Blender re-import. The importer converts the Y-up stage back to Blender's
    # Z-up by rotating the top object +90 deg about X; transforms relative to
    # ASSET_ROOT are unchanged.
    C.reset_scene()
    bpy.ops.wm.usd_import(filepath=str(path))
    names = sorted(o.name for o in bpy.data.objects)
    print('  reimport objects:', names)
    for n in ('ASSET_ROOT', 'BODY', 'LID_PIVOT', 'LID', 'FRONT_MARKER'):
        assert n in bpy.data.objects, (n, names)
    r, m = bpy.data.objects['ASSET_ROOT'], bpy.data.objects['FRONT_MARKER']
    print('  reimport ASSET_ROOT rot', tuple(round(a, 4) for a in r.rotation_euler),
          'FRONT_MARKER world', tuple(round(a, 4) for a in m.matrix_world.translation))
    local = (r.matrix_world.inverted() @ m.matrix_world).translation
    assert close(local, (0, 0.01, 0.05)), local
    lid = bpy.data.objects['LID']
    assert lid.parent and lid.parent.name == 'LID_PIVOT'


print('\n%d failure(s): %s' % (len(FAILS), FAILS))
sys.exit(1 if FAILS else 0)
