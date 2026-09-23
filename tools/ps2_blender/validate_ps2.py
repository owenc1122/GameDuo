"""Validate exported PS2 runtime USDZ files against the contract (background Blender).

    Blender -b --factory-startup --python-exit-code 1 --python validate_ps2.py -- \
        [--contract tools/ps2_blender/contract.json] [--only AssetName ...]

Each asset entry is common.load_contract(name): contract.json deep-merged with
contract_parts/<name>.json next to it (so --contract must be a contract.json).
Per asset: file present, Y-up metre stage, required nodes (exactly one match each),
size in root space, triangle budget, and at both ends of every motion range a
collision test (crossing triangles, or one mesh fully inside the other). Rotating
pivots must rest at zero rotation. Results go to <asset dir>/validation.json;
exit code 1 when anything fails, 2 for a bad command line / contract.

Assets follow common.py: modelled Y-up, exported unchanged with upAxis "Y". On
re-import Blender rotates the root +90 deg about X, so sizes are measured in the
root's own space and motions write the node's local location / rotation_euler.
A mesh object with children arrives as Empty NAME + Mesh NAME_mesh; name clashes
get '.001' suffixes. Nodes match 'NAME' or 'NAME.*' (outermost), else 'NAME_mesh'.
"""
import argparse
import json
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from pxr import Usd, UsdGeom

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
# Two skewed directions; a point is inside a mesh only when both ray parities agree.
RAY_DIRS = [Vector((0.2673, 0.5345, 0.8018)), Vector((-0.6247, 0.3123, -0.7158))]


def parse_args():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser(prog='validate_ps2.py')
    parser.add_argument('--contract', default='tools/ps2_blender/contract.json')
    parser.add_argument('--only', action='append', default=[])
    return parser.parse_args(argv)


def resolve(path):
    path = Path(path)
    return path if path.is_absolute() or path.exists() else ROOT / path


def lookup(name):
    """All outermost objects matching `name` / `name.NNN`, else `name_mesh` / `name_mesh.NNN`."""
    for wanted in (name, name + '_mesh'):
        matches = [o for o in bpy.data.objects
                   if o.name == wanted or o.name.startswith(wanted + '.')]
        outer = [o for o in matches if o.parent not in matches]
        if outer:
            return sorted(outer, key=lambda o: (o.name != wanted, o.name))
    return []


def find_node(name):
    found = lookup(name)
    return found[0] if found else None


def subtree(obj):
    return [obj, *obj.children_recursive]


def own_geometry(name):
    """Names of the meshes that belong to node `name` itself: the node (if a mesh)
    and its NAME_mesh child. Its child nodes are not included."""
    node = find_node(name)
    if node is None:
        return set()
    stem = name + '_mesh'
    own = {c.name for c in node.children if c.name == stem or c.name.startswith(stem + '.')}
    return own | ({node.name} if node.type == 'MESH' else set())


def world_mesh(obj, depsgraph):
    """World-space vertices (N x 3) and triangles (M x 3) of the evaluated mesh."""
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    mesh.calc_loop_triangles()
    co = np.empty(len(mesh.vertices) * 3, dtype=np.float64)
    mesh.vertices.foreach_get('co', co)
    tris = np.empty(len(mesh.loop_triangles) * 3, dtype=np.int64)
    mesh.loop_triangles.foreach_get('vertices', tris)
    evaluated.to_mesh_clear()
    co = co.reshape(-1, 3)
    matrix = np.array(obj.matrix_world)
    co = co @ matrix[:3, :3].T + matrix[:3, 3]
    return co, tris.reshape(-1, 3)


class Shapes:
    """Cache of world-space meshes keyed by object name; call refresh() after posing."""

    def __init__(self, objects):
        self.objects = [o for o in objects if o.type == 'MESH']
        self.data = {}
        self.refresh(self.objects)

    def refresh(self, objects):
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        for obj in objects:
            co, tris = world_mesh(obj, depsgraph)
            self.data[obj.name] = (co, tris, None)

    def bvh(self, name):
        co, tris, tree = self.data[name]
        if tree is None and len(tris):
            tree = BVHTree.FromPolygons(co.tolist(), tris.tolist(), all_triangles=True)
            self.data[name] = (co, tris, tree)
        return tree

    def box(self, name):
        co = self.data[name][0]
        return (co.min(axis=0), co.max(axis=0)) if len(co) else None

    def point(self, name):
        return Vector(self.data[name][0][0])


def inside(tree, point):
    """Ray-parity test; needs a closed mesh, so both directions must agree."""
    for direction in RAY_DIRS:
        hits, origin = 0, point
        for _ in range(100000):
            location = tree.ray_cast(origin, direction)[0]
            if location is None:
                break
            hits += 1
            origin = location + direction * 1e-6
        if hits % 2 == 0:
            return False
    return True


def collide(shapes, a, b):
    """None, or a description of how meshes `a` and `b` interpenetrate."""
    box_a, box_b = shapes.box(a), shapes.box(b)
    if box_a is None or box_b is None:
        return None
    if np.any(box_a[0] > box_b[1]) or np.any(box_b[0] > box_a[1]):
        return None
    tree_a, tree_b = shapes.bvh(a), shapes.bvh(b)
    if tree_a is None or tree_b is None:
        return None
    pairs = tree_a.overlap(tree_b)
    if pairs:
        return f'{a} intersects {b} ({len(pairs)} tri pairs)'
    if inside(tree_b, shapes.point(a)):
        return f'{a} is inside {b}'
    if inside(tree_a, shapes.point(b)):
        return f'{b} is inside {a}'
    return None


def check_motion(motion, shapes, root_meshes):
    """Pose the node at both range ends; returns {'errors': [...], 'ends': [...]}."""
    result = {'motion': motion, 'errors': [], 'ends': []}
    node = find_node(motion['node'])
    kind, _, axis = motion.get('axis', '').partition('_')
    values = motion.get('range_m', motion.get('range_rad'))
    if node is None:
        result['errors'].append('node not found')
    if kind not in ('loc', 'rot') or axis not in ('x', 'y', 'z') or not values:
        result['errors'].append(f'bad axis/range {motion}')
    if result['errors']:
        return result
    index = 'xyz'.index(axis)

    moving_names = {o.name for o in subtree(node)}
    ignored = set().union(*map(own_geometry, motion.get('allow_touch', []))) - moving_names
    moving = [o for o in subtree(node) if o.type == 'MESH']
    static = [o.name for o in root_meshes if o.name not in moving_names | ignored]

    base_mode, base_loc = node.rotation_mode, node.location.copy()
    node.rotation_mode = 'XYZ'
    base_rot = node.rotation_euler.copy()
    if kind == 'rot' and any(abs(v) > 1e-6 for v in base_rot):
        result['errors'].append(
            f'rest rotation {tuple(round(v, 4) for v in base_rot)} must be zero for a rot_* '
            'pivot (Blender XYZ and SceneKit Euler orders differ); add a parent pivot instead')
    try:
        for value in values:
            if kind == 'loc':
                node.location[index] = base_loc[index] + value
            else:
                node.rotation_euler[index] = base_rot[index] + value
            shapes.refresh(moving)
            hits = [hit for mover in moving for other in static
                    if (hit := collide(shapes, mover.name, other))]
            result['ends'].append({'value': value, 'collisions': hits})
    finally:
        node.location, node.rotation_euler = base_loc, base_rot
        node.rotation_mode = base_mode
        shapes.refresh(moving)
    return result


def validate(name, spec, tolerance):
    path = resolve(spec['file'])
    result = {'file': spec['file'], 'reasons': []}
    reasons = result['reasons']
    if not path.is_file():
        reasons.append(f'file not found: {spec["file"]}')
        return path, result

    bpy.ops.wm.read_factory_settings(use_empty=True)
    # Keep every USD Xform as its own object so single-child groups keep their names.
    bpy.ops.wm.usd_import(filepath=str(path), merge_parent_xform=False)
    stage = Usd.Stage.Open(str(path))
    up_axis, meters = UsdGeom.GetStageUpAxis(stage), UsdGeom.GetStageMetersPerUnit(stage)
    if up_axis != 'Y':
        reasons.append(f'stage upAxis is {up_axis}, contract expects Y')
    if meters != 1.0:
        reasons.append(f'stage metersPerUnit is {meters}, contract expects 1')

    required = [spec['root'], *spec.get('nodes', [])]
    missing = [n for n in required if not lookup(n)]
    result['missing_nodes'] = missing
    if missing:
        reasons.append('missing nodes: ' + ', '.join(missing))
    referenced = required + spec.get('size_excludes', []) + [
        n for m in spec.get('motions', []) for n in [m.get('node', '?'), *m.get('allow_touch', [])]]
    for ref in dict.fromkeys(referenced):
        if len(lookup(ref)) > 1:
            reasons.append(f'ambiguous name {ref}: ' + ', '.join(o.name for o in lookup(ref)))
    root = find_node(spec['root'])
    if root is None:
        return path, result

    shapes = Shapes(subtree(root))
    excluded = set()
    for excluded_name in spec.get('size_excludes', []):
        node = find_node(excluded_name)
        excluded |= {o.name for o in subtree(node)} if node else set()
    sized = [shapes.data[o.name][0] for o in shapes.objects if o.name not in excluded]
    sized = [co for co in sized if len(co)]
    measured = None
    if sized:
        to_root = np.array(root.matrix_world.inverted())
        co = np.concatenate(sized) @ to_root[:3, :3].T + to_root[:3, 3]
        measured = [round(float(v) * 1000, 3) for v in co.max(axis=0) - co.min(axis=0)]
    result['size_mm_measured'], result['size_mm_target'] = measured, spec.get('size_mm')
    if spec.get('size_mm'):
        if measured is None:
            reasons.append('no geometry to measure')
        else:
            off = [round(m - t, 3) for m, t in zip(measured, spec['size_mm'])]
            if any(abs(d) > tolerance for d in off):
                reasons.append(f'size {measured} mm vs target {spec["size_mm"]} (diff {off})')

    tris = sum(len(shapes.data[o.name][1]) for o in shapes.objects)
    result['tris'], result['max_tris'] = tris, spec.get('max_tris')
    if spec.get('max_tris') is not None and tris > spec['max_tris']:
        reasons.append(f'{tris} triangles > max {spec["max_tris"]}')

    result['motion_results'] = []
    for motion in spec.get('motions', []):
        checked = check_motion(motion, shapes, shapes.objects)
        checked['passed'] = not checked['errors'] and not any(e['collisions'] for e in checked['ends'])
        result['motion_results'].append(checked)
        label = f'motion {motion.get("node")} {motion.get("axis")}'
        reasons += [f'{label}: {error}' for error in checked['errors']]
        reasons += [f'{label}={end["value"]}: {hit}' for end in checked['ends'] for hit in end['collisions']]
    return path, result


def asset_dir(path):
    exports = next((p for p in path.parents if p.name == 'exports'), None)
    return exports.parent if exports else path.parent


def record(path, name, result, known):
    """Merge `result` into <asset dir>/validation.json, dropping assets not in the contract."""
    folder = asset_dir(path)
    if not folder.is_dir():
        return
    report = folder / 'validation.json'
    try:
        data = json.loads(report.read_text())
    except (OSError, ValueError):
        data = {}
    data = {k: v for k, v in data.items() if k in known}
    data[name] = result
    report.write_text(json.dumps(data, indent=2) + '\n')


def main():
    args = parse_args()
    contract_path = resolve(args.contract)
    if not contract_path.is_file():
        print(f'ERROR contract not found: {args.contract}')
        sys.exit(2)
    if contract_path.name != 'contract.json':
        print(f'ERROR --contract must point at a contract.json (parts merge from its '
              f'contract_parts/): {args.contract}')
        sys.exit(2)
    common.CONTRACT_DIR = contract_path.parent
    contract = json.loads(contract_path.read_text())
    assets = list(contract.get('assets', {}))
    unknown = [n for n in args.only if n not in assets]
    if unknown:
        print('ERROR unknown asset(s): ' + ', '.join(unknown))
        sys.exit(2)
    tolerance = contract.get('tolerance_mm', 0.5)
    failed = 0
    for name in assets:
        if args.only and name not in args.only:
            continue
        path = None
        try:
            spec = common.load_contract(name)
            path, result = validate(name, spec, tolerance)
        except Exception as error:  # report, keep validating the other assets
            traceback.print_exc()
            result = {'reasons': [f'validator error: {type(error).__name__}: {error}']}
        result['passed'] = not result['reasons']
        result['checked_at'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
        if path is not None:
            record(path, name, result, set(assets))
        if result['passed']:
            print(f'OK {name}  size_mm={result["size_mm_measured"]} tris={result["tris"]}')
        else:
            failed += 1
            print(f'FAIL {name}: ' + '; '.join(result['reasons']))
    sys.exit(1 if failed else 0)


main()
