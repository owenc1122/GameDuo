"""Build tiny USDZ fixtures for the PS2 validators (run in background Blender).

Modelled Y-up like the real assets (X right, Y up, Z front) and exported with
common.export_usdz:

FIX_ROOT > FIX_BODY (100 x 50 x 100 mm box, top at y = 50 mm)
           > FIX_LID  (10 mm plate, pivot on the hinge line at the body's back top
                       edge, local +Z toward the front) > FIX_LATCH (on the lid)
           > FIX_KNOB (10 x 10 x 4 mm, 0.5 mm in front of the body, rest rotation
                       0.3 rad about Z: must be rejected as a rot_* pivot)

Both FIX_BODY and FIX_LID have children, so they export as Xform NAME + NAME_mesh.
fixture.usdz leaves a 1 mm gap under the lid; fixture_bad.usdz 0.5 mm, and its
contract entry slides the lid down into the body so the motion check must fail.
fixture_dupe.usdz copies FIX_LATCH to a second prim path (ambiguous name).
"""
import sys
from pathlib import Path

from mathutils import Matrix

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import common as C  # noqa: E402

OUT = HERE / 'out'


def build(path, lid_gap):
    C.reset_scene()
    root = C.empty('FIX_ROOT')
    body = C.rounded_box('FIX_BODY', (0.1, 0.05, 0.1), 0, location=(0, 0.025, 0))
    C.set_parent(body, root)
    lid = C.rounded_box('FIX_LID', (0.1, 0.01, 0.1), 0)
    lid.data.transform(Matrix.Translation((0, 0.005, 0.05)))  # hinge at back-bottom edge
    lid.location = (0, 0.025 + lid_gap, -0.05)  # in FIX_BODY space
    C.set_parent(lid, body, keep_world=False)
    latch = C.rounded_box('FIX_LATCH', (0.02, 0.004, 0.006), 0, location=(0, 0.012, 0.095))
    C.set_parent(latch, lid, keep_world=False)
    knob = C.rounded_box('FIX_KNOB', (0.01, 0.01, 0.004), 0, location=(0, 0, 0.0525))
    knob.rotation_euler = (0, 0, 0.3)
    C.set_parent(knob, body, keep_world=False)
    grey = C.mat('Fixture_Grey', C.hex_rgba('#808080'))
    for obj in (body, lid, latch, knob):
        C.assign(obj, grey)
    print('WROTE', C.export_usdz(root, path))


def duplicate_latch(source, path):
    """Copy of `source` with FIX_LATCH also under FIX_BODY (same name, two prims)."""
    import tempfile
    from pxr import Sdf, Usd, UsdUtils
    usdc = Path(tempfile.mkdtemp()) / 'dupe.usdc'
    Usd.Stage.Open(str(source)).Export(str(usdc))
    layer = Sdf.Layer.FindOrOpen(str(usdc))
    Sdf.CopySpec(layer, '/FIX_ROOT/FIX_BODY/FIX_LID/FIX_LATCH', layer, '/FIX_ROOT/FIX_BODY/FIX_LATCH')
    layer.Save()
    UsdUtils.CreateNewUsdzPackage(str(usdc), str(path))
    print('WROTE', path)


build(OUT / 'fixture.usdz', 0.001)
build(OUT / 'fixture_bad.usdz', 0.0005)
duplicate_latch(OUT / 'fixture.usdz', OUT / 'fixture_dupe.usdz')
