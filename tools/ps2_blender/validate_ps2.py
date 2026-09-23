"""Validate exported PS2 runtime USDZ files against the contract (background Blender).

    Blender -b --factory-startup --python-exit-code 1 --python validate_ps2.py -- \
        [--contract tools/ps2_blender/contract.json] [--only AssetName ...]

Per asset: file present, Y-up stage, required nodes, size in root space, triangle
budget and a BVH collision test at both ends of every motion range. Results are
merged into <asset dir>/validation.json; exit code 1 when anything fails.

Assets follow common.py: modelled Y-up, exported unchanged with upAxis "Y". On
re-import Blender rotates the root +90 deg about X, so sizes are measured in the
root's own space and motions write the node's local location / rotation_euler.
A mesh object with children arrives as Empty NAME + Mesh NAME_mesh; name clashes
get '.001' suffixes. Nodes match 'NAME' or 'NAME.*' (outermost first), falling
back to 'NAME_mesh' when no such object exists.
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import bpy
import numpy as np
from mathutils.bvhtree import BVHTree
from pxr import Usd, UsdGeom

ROOT = Path(__file__).resolve().parents[2]


def parse_args():
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    parser = argparse.ArgumentParser(prog='validate_ps2.py')
    parser.add_argument('--contract', default='tools/ps2_blender/contract.json')
    parser.add_argument('--only', action='append', default=[])
    return parser.parse_args(argv)


def resolve(path):
    path = Path(path)
    return path if path.is_absolute() or path.exists() else ROOT / path


def find_node(name):
    """Outermost imported object called `name` or `name.NNN` (exact preferred),
    else the merged `name_mesh` object."""
    for wanted in (name, name + '_mesh'):
        matches = [o for o in bpy.data.objects
                   if o.name == wanted or o.name.startswith(wanted + '.')]
        outer = [o for o in matches if o.parent not in matches] or matches
        outer.sort(key=lambda o: (o.name != wanted, o.name))
        if outer:
            return outer[0]
    return None


def subtree(obj):
    return [obj, *obj.children_recursive]


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
        self.refresh()

    def refresh(self, only=None):
        bpy.context.view_layer.update()
        depsgraph = bpy.context.evaluated_depsgraph_get()
        if only is None:
            self.data = {}
        for obj in self.objects if only is None else only:
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


def check_motion(motion, shapes, root_meshes):
    node = find_node(motion['node'])
    if node is None:
        return {'motion': motion, 'passed': False, 'error': 'node not found'}
    kind, axis = motion['axis'].split('_')
    index = 'xyz'.index(axis)
    values = motion.get('range_m', motion.get('range_rad'))
    ignored = set()
    for name in motion.get('allow_touch', []):
        allowed = find_node(name)
        ignored |= {o.name for o in subtree(allowed)} if allowed else set()
    moving = [o for o in subtree(node) if o.type == 'MESH' and o.name not in ignored]
    moving_names = {o.name for o in moving} | {o.name for o in subtree(node)}
    static = [o.name for o in root_meshes if o.name not in moving_names | ignored]

    base_mode, base_loc = node.rotation_mode, node.location.copy()
    node.rotation_mode = 'XYZ'
    base_rot = node.rotation_euler.copy()
    ends = []
    try:
        for value in values:
            if kind == 'loc':
                node.location[index] = base_loc[index] + value
            else:
                node.rotation_euler[index] = base_rot[index] + value
            shapes.refresh(moving)
            hits = []
            for mover in moving:
                a_box = shapes.box(mover.name)
                for other in static:
                    b_box = shapes.box(other)
                    if a_box is None or b_box is None:
                        continue
                    if np.any(a_box[0] > b_box[1]) or np.any(b_box[0] > a_box[1]):
                        continue
                    a_tree, b_tree = shapes.bvh(mover.name), shapes.bvh(other)
                    pairs = a_tree.overlap(b_tree) if a_tree and b_tree else []
                    if pairs:
                        hits.append({'moving': mover.name, 'other': other, 'triangle_pairs': len(pairs)})
            ends.append({'value': value, 'overlaps': hits})
    finally:
        node.location, node.rotation_euler = base_loc, base_rot
        node.rotation_mode = base_mode
        shapes.refresh(moving)
    passed = all(not end['overlaps'] for end in ends)
    return {'motion': motion, 'passed': passed, 'ends': ends}


def validate(name, spec, tolerance):
    path = resolve(spec['file'])
    result = {'passed': False, 'file': spec['file'], 'reasons': []}
    if not path.is_file():
        result['reasons'].append(f'file not found: {spec["file"]}')
        return path, result

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=str(path))
    stage = Usd.Stage.Open(str(path))
    up_axis, meters = UsdGeom.GetStageUpAxis(stage), UsdGeom.GetStageMetersPerUnit(stage)
    reasons = result['reasons']
    if up_axis != 'Y':
        reasons.append(f'stage upAxis is {up_axis}, contract expects Y')
    if meters != 1.0:
        reasons.append(f'stage metersPerUnit is {meters}, contract expects 1')

    root = find_node(spec['root'])
    missing = [n for n in [spec['root'], *spec.get('nodes', [])] if find_node(n) is None]
    result['missing_nodes'] = missing
    if missing:
        reasons.append('missing nodes: ' + ', '.join(missing))
    if root is None:
        return path, result

    root_objects = subtree(root)
    shapes = Shapes(root_objects)
    excluded = set()
    for excluded_name in spec.get('size_excludes', []):
        node = find_node(excluded_name)
        excluded |= {o.name for o in subtree(node)} if node else set()
    sized = [shapes.data[o.name][0] for o in shapes.objects if o.name not in excluded]
    sized = [co for co in sized if len(co)]
    if sized:
        to_root = np.array(root.matrix_world.inverted())
        co = np.concatenate(sized) @ to_root[:3, :3].T + to_root[:3, 3]
        measured = [round(float(v) * 1000, 3) for v in co.max(axis=0) - co.min(axis=0)]
    else:
        measured = [0.0, 0.0, 0.0]
    result['size_mm_measured'] = measured
    result['size_mm_target'] = spec.get('size_mm')
    if spec.get('size_mm'):
        off = [round(m - t, 3) for m, t in zip(measured, spec['size_mm'])]
        if any(abs(d) > tolerance for d in off):
            reasons.append(f'size {measured} mm vs target {spec["size_mm"]} (diff {off})')

    tris = sum(len(shapes.data[o.name][1]) for o in shapes.objects)
    result['tris'], result['max_tris'] = tris, spec.get('max_tris')
    if spec.get('max_tris') is not None and tris > spec['max_tris']:
        reasons.append(f'{tris} triangles > max {spec["max_tris"]}')

    motions = [check_motion(m, shapes, shapes.objects) for m in spec.get('motions', [])]
    result['motion_results'] = motions
    for m in motions:
        if m.get('error'):
            reasons.append(f'motion {m["motion"]["node"]} {m["motion"]["axis"]}: {m["error"]}')
        for end in m.get('ends', []):
            for hit in end['overlaps']:
                reasons.append(
                    f'motion {m["motion"]["node"]} {m["motion"]["axis"]}={end["value"]}: '
                    f'{hit["moving"]} intersects {hit["other"]} ({hit["triangle_pairs"]} tri pairs)')
    return path, result


def asset_dir(path):
    exports = next((p for p in path.parents if p.name == 'exports'), None)
    return exports.parent if exports else path.parent


def record(path, name, result):
    folder = asset_dir(path)
    if not folder.is_dir():
        return
    report = folder / 'validation.json'
    try:
        data = json.loads(report.read_text())
    except (OSError, ValueError):
        data = {}
    data[name] = result
    report.write_text(json.dumps(data, indent=2) + '\n')


def main():
    args = parse_args()
    contract_path = resolve(args.contract)
    if not contract_path.is_file():
        print(f'ERROR contract not found: {args.contract}')
        sys.exit(2)
    contract = json.loads(contract_path.read_text())
    assets = contract['assets']
    unknown = [n for n in args.only if n not in assets]
    if unknown:
        print('ERROR unknown asset(s): ' + ', '.join(unknown))
        sys.exit(2)
    tolerance = contract.get('tolerance_mm', 0.5)
    failed = 0
    for name, spec in assets.items():
        if args.only and name not in args.only:
            continue
        path, result = validate(name, spec, tolerance)
        result['passed'] = not result['reasons']
        result['checked_at'] = datetime.now(timezone.utc).isoformat(timespec='seconds')
        record(path, name, result)
        if result['passed']:
            print(f'OK {name}  size_mm={result["size_mm_measured"]} tris={result["tris"]}')
        else:
            failed += 1
            print(f'FAIL {name}: ' + '; '.join(result['reasons']))
    sys.exit(1 if failed else 0)


main()
