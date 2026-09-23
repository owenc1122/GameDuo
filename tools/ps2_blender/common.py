"""Shared Blender helpers for the PS2 runtime assets (Blender 5.2, run headless).

Usage from a modelling script::

    sys.path.insert(0, str(<repo>/'tools/ps2_blender'))
    import common as C
    C.reset_scene()
    root = C.empty('PS2_CONSOLE')
    ...
    C.export_usdz(root, C.REPO / 'PS2_Model/exports/PS2-Console.usdz')

Conventions (verified by tests/test_common.py and a SceneKit load):

* Units are metres, 1 Blender unit = 1 m, exported with metersPerUnit = 1.
* Asset axes: X right, Y up, Z toward the object's front.
* We MODEL DIRECTLY IN THOSE AXES inside Blender: Blender X = asset X,
  Blender Y = asset Y (up), Blender Z = asset Z (front). Ignore Blender's
  "Z is up" viewport convention; these assets are scripted, not hand-edited.
  Consequently primitives whose default axis is Blender Z (cylinder()) point
  toward the front.
* export_usdz() writes the transforms unchanged (convert_orientation=False) and
  then stamps the stage upAxis = "Y". We do NOT use Blender's
  convert_orientation: it only adds a -90 deg X rotation on the top prim, leaving
  every child's local transform in Blender Z-up space, so SceneKit code such as
  "slide DISC_TRAY along local Z" would move the wrong way. SceneKit ignores the
  stage upAxis (it only reports it as SCNScene.Attribute.upAxis), so node
  positions in SceneKit equal the Blender values exactly; upAxis "Y" keeps other
  USD readers (Quick Look, Blender re-import) consistent.
* The root object becomes the USD defaultPrim and the top SceneKit node (no
  extra "/root" wrapper). Keep the root an EMPTY at the world origin with an
  identity transform so the asset origin is where the contract says it is.
* Node names: use [A-Za-z0-9_] (other characters are replaced by "_" in USD).
  Mesh objects are merged with their Xform (merge_parent_xform), so a mesh
  object "BTN_RESET" is ONE SceneKit node named "BTN_RESET" carrying the
  geometry. A mesh object that has children cannot be merged: it becomes an
  Xform "NAME" with a child Mesh prim named after its mesh data (we name the
  data "NAME_mesh"), plus its child nodes.
* Pivots / animated nodes: their local transform (location/rotation relative
  to the parent) IS the runtime pivot. set_parent() leaves the parent-inverse
  matrix at identity so obj.location is really the offset in the parent's
  space, and apply_all() never bakes location/rotation, only scale.
"""
import json
import math
import shutil
import tempfile
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CONTRACT_DIR = HERE  # tests may point this elsewhere


# ---------------------------------------------------------------- contract
def _deep_merge(base, extra):
    out = dict(base)
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load_contract(asset_name):
    """Contract entry for `asset_name` (e.g. 'PS2-Console').

    Returns contract.json's global keys (tolerance_mm, ...) merged with
    assets[asset_name], then deep-merged with contract_parts/<asset_name>.json
    when that file exists (parts win). 'name' is set to asset_name.
    """
    data = json.loads((CONTRACT_DIR / 'contract.json').read_text())
    assets = data.get('assets', {})
    if asset_name not in assets:
        raise KeyError(f'{asset_name!r} not in contract.json assets {sorted(assets)}')
    merged = {k: v for k, v in data.items() if k != 'assets'}
    merged = _deep_merge(merged, assets[asset_name])
    part = CONTRACT_DIR / 'contract_parts' / f'{asset_name}.json'
    if part.exists():
        merged = _deep_merge(merged, json.loads(part.read_text()))
    merged['name'] = asset_name
    return merged


# ---------------------------------------------------------------- scene
def reset_scene():
    """Empty scene, metric units, unit scale 1.0."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    units = bpy.context.scene.unit_settings
    units.system = 'METRIC'
    units.scale_length = 1.0
    units.length_unit = 'MILLIMETERS'  # display only; data stays in metres


def _link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def descendants(root):
    """root and every object below it."""
    return [root, *root.children_recursive]


# ---------------------------------------------------------------- materials
def hex_rgba(hex_str, a=1.0):
    """'#RRGGBB' (sRGB) -> linear RGBA tuple for Blender colour inputs."""
    h = hex_str.lstrip('#')
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (lin(int(h[0:2], 16)), lin(int(h[2:4], 16)), lin(int(h[4:6], 16)), float(a))


def mat(name, rgba, rough=0.5, metal=0.0, alpha=1.0, emit=None, emit_strength=1.0):
    """Principled BSDF material using only UsdPreviewSurface-expressible inputs
    (base colour, metallic, roughness, alpha -> opacity, emission).
    `rgba` is linear (use hex_rgba for sRGB hex). Reuses/updates a same-named material."""
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    if m.node_tree is None:
        m.use_nodes = True
    nodes = m.node_tree.nodes
    nodes.clear()
    bsdf = nodes.new('ShaderNodeBsdfPrincipled')
    out = nodes.new('ShaderNodeOutputMaterial')
    m.node_tree.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])
    rgba = tuple(rgba) + (1.0,) * (4 - len(rgba))
    bsdf.inputs['Base Color'].default_value = rgba
    bsdf.inputs['Metallic'].default_value = metal
    bsdf.inputs['Roughness'].default_value = rough
    bsdf.inputs['Alpha'].default_value = alpha
    if emit is not None:
        emit = tuple(emit) + (1.0,) * (4 - len(emit))
        bsdf.inputs['Emission Color'].default_value = emit
        bsdf.inputs['Emission Strength'].default_value = emit_strength
    m.diffuse_color = (*rgba[:3], alpha)
    m.metallic, m.roughness = metal, rough
    m.surface_render_method = 'BLENDED' if alpha < 1.0 else 'DITHERED'
    return m


def assign(obj, material):
    """Make `material` the only material of obj's mesh data."""
    obj.data.materials.clear()
    obj.data.materials.append(material)
    return obj


# ---------------------------------------------------------------- geometry
def _mesh_object(name, bm, location=(0, 0, 0), rotation=(0, 0, 0)):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = _link(bpy.data.objects.new(name, me))
    obj.location, obj.rotation_euler = location, rotation
    return obj


def _smooth_by_angle(bm, angle_deg=35.0):
    for f in bm.faces:
        f.smooth = True
    limit = math.radians(angle_deg)
    for e in bm.edges:
        if not e.is_manifold or e.calc_face_angle(0.0) > limit:
            e.smooth = False


def rounded_box(name, size_m, radius_m, segments=3, location=(0, 0, 0)):
    """Box of exact outer size (x, y, z) metres centred on its origin, all 12
    edges rounded with `radius_m` (bevel already applied, smooth-shaded)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size_m, verts=bm.verts)
    if radius_m > 0:
        bmesh.ops.bevel(bm, geom=list(bm.verts) + list(bm.edges), offset=radius_m,
                        offset_type='OFFSET', segments=segments, profile=0.5,
                        affect='EDGES', clamp_overlap=True)
    _smooth_by_angle(bm)
    return _mesh_object(name, bm, location)


def cylinder(name, radius, depth, verts=48, location=(0, 0, 0), rotation=(0, 0, 0)):
    """Capped cylinder centred on its origin; axis = local Z (asset front).
    `rotation` is an XYZ Euler in radians."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=verts,
                          radius1=radius, radius2=radius, depth=depth)
    _smooth_by_angle(bm)
    return _mesh_object(name, bm, location, rotation)


def _apply_modifier(obj, mod):
    with bpy.context.temp_override(object=obj, active_object=obj,
                                   selected_objects=[obj]):
        bpy.ops.object.modifier_apply(modifier=mod.name)


def bevel(obj, width, segments=3, angle_deg=30.0):
    """Add (not apply) a bevel modifier on edges sharper than angle_deg.
    It is evaluated at export, or baked by apply_all()."""
    mod = obj.modifiers.new('Bevel', 'BEVEL')
    mod.width, mod.segments = width, segments
    mod.limit_method = 'ANGLE'
    mod.angle_limit = math.radians(angle_deg)
    mod.harden_normals = False
    return mod


def boolean(obj, cutter, op='DIFFERENCE', apply=True, delete_cutter=True):
    """Boolean `obj` with `cutter` (op: DIFFERENCE / UNION / INTERSECT, EXACT solver).
    With apply=False the modifier stays live and the cutter is hidden from render."""
    mod = obj.modifiers.new(f'Bool_{cutter.name}', 'BOOLEAN')
    mod.operation, mod.solver, mod.object = op, 'EXACT', cutter
    cutter.hide_render = True
    cutter.display_type = 'WIRE'
    if apply:
        _apply_modifier(obj, mod)
        if delete_cutter:
            bpy.data.objects.remove(cutter, do_unlink=True)
    return obj


# ---------------------------------------------------------------- hierarchy
def set_parent(child, parent, keep_world=True):
    """Parent with an identity parent-inverse, so child.location/rotation are the
    real local transform (what SceneKit sees). keep_world=True keeps the child's
    current world placement; False reinterprets its current location as local."""
    bpy.context.view_layer.update()
    world = child.matrix_world.copy()
    child.parent = parent
    child.matrix_parent_inverse = Matrix.Identity(4)
    if keep_world and parent is not None:
        child.matrix_basis = parent.matrix_world.inverted() @ world
    elif keep_world:
        child.matrix_basis = world
    return child


def empty(name, parent=None, location=(0, 0, 0), rotation=(0, 0, 0), size=0.01):
    """Empty node (pivot / anchor). `location`/`rotation` are LOCAL to `parent`."""
    obj = _link(bpy.data.objects.new(name, None))
    obj.empty_display_type, obj.empty_display_size = 'PLAIN_AXES', size
    if parent is not None:
        obj.parent = parent
    obj.location, obj.rotation_euler = location, rotation
    return obj


def apply_all(obj):
    """Bake a mesh object's modifier stack and its scale into the mesh data.

    Location and rotation are never touched: for pivots/animated nodes the local
    transform is the runtime pivot and must survive. Children keep their world
    placement (their local transform is recomputed when the scale is removed).
    Modifiers are baked at their RENDER result (same as export_usdz). Shared
    mesh data is copied first; a negative scale also flips the face winding.
    Non-mesh objects are left unchanged."""
    if obj.type != 'MESH':
        return obj
    _match_render(obj)
    bpy.context.view_layer.update()
    kids = {c: c.matrix_world.copy() for c in obj.children}
    if obj.modifiers:
        dg = bpy.context.evaluated_depsgraph_get()
        old = obj.data
        new = bpy.data.meshes.new_from_object(obj.evaluated_get(dg), depsgraph=dg,
                                              preserve_all_data_layers=True)
        obj.modifiers.clear()
        obj.data = new
        new.name = old.name
        if old.users == 0:
            bpy.data.meshes.remove(old)
    if any(abs(s - 1.0) > 1e-9 for s in obj.scale):
        if obj.data.users > 1:
            obj.data = obj.data.copy()
        obj.data.transform(Matrix.Diagonal((*obj.scale, 1.0)))
        if obj.scale[0] * obj.scale[1] * obj.scale[2] < 0:
            bm = bmesh.new()
            bm.from_mesh(obj.data)
            bmesh.ops.reverse_faces(bm, faces=bm.faces)
            bm.to_mesh(obj.data)
            bm.free()
        obj.scale = (1.0, 1.0, 1.0)
    bpy.context.view_layer.update()
    for c, world in kids.items():
        c.matrix_basis = (obj.matrix_world @ c.matrix_parent_inverse).inverted() @ world
    return obj


def _match_render(*objs):
    """Make viewport evaluation equal RENDER evaluation (what export_usdz writes):
    viewport subdivision levels = render levels, modifier viewport toggle =
    render toggle. Persistent side effect on the modifiers."""
    for o in objs:
        for mod in getattr(o, 'modifiers', ()):
            if mod.type in {'SUBSURF', 'MULTIRES'}:
                mod.levels = mod.render_levels
            mod.show_viewport = mod.show_render


def triangle_count(objs):
    """Triangles of the evaluated meshes exactly as export_usdz writes them
    (modifiers at render settings, see _match_render). Accepts one object or an
    iterable; non-mesh objects count 0. Use descendants(root) for a tree."""
    if isinstance(objs, bpy.types.Object):
        objs = [objs]
    objs = [o for o in objs if o.type == 'MESH']
    _match_render(*objs)
    dg = bpy.context.evaluated_depsgraph_get()
    total = 0
    for o in objs:
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        total += len(me.loop_triangles)
        ev.to_mesh_clear()
    return total


# ---------------------------------------------------------------- export
def _fix_opacity(stage, objs):
    # Blender 5.2 writes UsdPreviewSurface opacity = 1 even when the Principled
    # Alpha is < 1, so author it from the Blender material.
    from pxr import Sdf, Tf, UsdShade
    alpha = {}
    for o in objs:
        for m in (o.data.materials if o.type == 'MESH' else ()):
            bsdf = m and m.node_tree and m.node_tree.nodes.get('Principled BSDF')
            if bsdf and bsdf.inputs['Alpha'].default_value < 1.0:
                alpha[Tf.MakeValidIdentifier(m.name)] = bsdf.inputs['Alpha'].default_value
    done = set()
    for prim in stage.Traverse():
        if prim.GetTypeName() != 'Shader' or prim.GetParent().GetName() not in alpha:
            continue
        shader = UsdShade.Shader(prim)
        if shader.GetIdAttr().Get() == 'UsdPreviewSurface':
            name = prim.GetParent().GetName()
            shader.CreateInput('opacity', Sdf.ValueTypeNames.Float).Set(alpha[name])
            done.add(name)
    missing = sorted(set(alpha) - done)
    if missing:
        raise RuntimeError(f'translucent materials without a UsdPreviewSurface in the stage: {missing}')


def export_usdz(root, path):
    """Export `root` and all its descendants to a USDZ at `path` (dirs created).

    Y-up stage, metersPerUnit 1, root = defaultPrim, triangulated meshes,
    UsdPreviewSurface materials (opacity = Principled Alpha, emissiveColor =
    Emission Color x Strength), RENDER-evaluated modifiers with subdivision
    baked (export_subdivision='TESSELLATE'). Materials live in the sibling scope
    /_materials. Raises ValueError if the root is not at the origin with an
    identity transform, or if a descendant is hide_render / not in the view
    layer (hide_viewport and hide_set are cleared). Boolean cutters referenced by
    live modifiers are skipped. Side effects: _match_render() on the modifiers;
    a mesh object that has children and whose data is named like the object gets
    its data renamed NAME_mesh. Returns Path."""
    from pxr import Usd, UsdGeom, UsdUtils

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.context.view_layer.update()
    if any(abs(a - b) > 1e-9 for ra, rb in zip(root.matrix_world, Matrix.Identity(4))
           for a, b in zip(ra, rb)):
        raise ValueError(f'export_usdz: root {root.name} must sit at the world origin '
                         f'with an identity transform')
    objs = descendants(root)
    cutters = {m.object for o in objs for m in getattr(o, 'modifiers', ())
               if m.type == 'BOOLEAN' and m.object}
    objs = [o for o in objs if o not in cutters]  # live boolean cutters are never geometry
    hidden = [o.name for o in objs if o.hide_render]
    if hidden:
        raise ValueError(f'export_usdz: hide_render objects would be dropped: {hidden}')
    _match_render(*objs)
    for o in objs:
        if o.type == 'MESH' and o.children and o.data.name == o.name:
            o.data.name = o.name + '_mesh'  # avoid NAME/NAME nodes in SceneKit
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.hide_viewport = False
        o.hide_set(False)
        o.select_set(True)
    unselectable = [o.name for o in objs if not o.select_get()]
    if unselectable:  # e.g. in an excluded/hidden collection
        raise ValueError(f'export_usdz: objects not exportable (not in view layer): {unselectable}')
    bpy.context.view_layer.objects.active = root
    tmp = Path(tempfile.mkdtemp(prefix='ps2usd_'))
    try:
        usdc = tmp / (path.stem + '.usdc')
        bpy.ops.wm.usd_export(
            filepath=str(usdc), selected_objects_only=True, export_materials=True,
            generate_preview_surface=True, generate_materialx_network=False,
            evaluation_mode='RENDER', export_animation=False, export_lights=False,
            export_cameras=False, export_custom_properties=False,
            author_blender_name=False, triangulate_meshes=True,
            export_subdivision='TESSELLATE',  # bake subsurf; BEST_MATCH writes the cage
            convert_orientation=False, convert_scene_units='METERS', meters_per_unit=1.0,
            root_prim_path='', merge_parent_xform=True, use_instancing=False,
            relative_paths=True)
        stage = Usd.Stage.Open(str(usdc))
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        if stage.GetDefaultPrim().GetName() != root.name:
            raise RuntimeError(f'defaultPrim {stage.GetDefaultPrim().GetName()} != {root.name}')
        _fix_opacity(stage, objs)
        stage.GetRootLayer().Save()
        if path.exists():
            path.unlink()
        if not UsdUtils.CreateNewUsdzPackage(str(usdc), str(path)):
            raise RuntimeError(f'USDZ packaging failed for {path}')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return path


def save_blend(path):
    """Save the current file (dirs created, no .blend1 backup relied upon)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(path), compress=True)
    return path
