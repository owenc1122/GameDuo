"""Editable visual reconstructions; not factory CAD. Coordinates are millimetres.
Back reference: Kungfuman, https://commons.wikimedia.org/wiki/File:Nintendo-3ds-ds-cartridge.jpg
The photograph is a visual reference only, not a texture embedded in the asset.
"""
import bpy
import math
import random
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

def material(name, color, roughness=.48, metal=0):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    p = m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value = (*color, 1)
    p.inputs['Roughness'].default_value = roughness
    p.inputs['Metallic'].default_value = metal
    return m

gold = material('Gold plated contact', (.43,.22,.035), .40, .75)
pcb = material('Green PCB', (.022,.085,.034), .65)
dark = material('Recess shadow', (.014,.016,.018), .75)

def finish(obj, mat, bevel=0, parent=None):
    obj.data.materials.append(mat)
    if bevel:
        mod = obj.modifiers.new('Six segment physical edge radius','BEVEL')
        mod.width, mod.segments = bevel, 6
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
    if obj.type == 'MESH':
        for p in obj.data.polygons: p.use_smooth = True
    obj.parent = parent
    return obj

def box(name, dims, loc, mat, bevel=.08, parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.object
    o.name, o.dimensions = name, dims
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(o,mat,bevel,parent)

def cut(obj, dims, loc, radius=.1):
    cutter = box('Temporary cutter', dims, loc, dark, radius)
    mod = obj.modifiers.new('Actual recessed cavity','BOOLEAN')
    mod.operation, mod.object = 'DIFFERENCE', cutter
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter,do_unlink=True)

def contour(three):
    points = [(-15.9,17.5)]
    points += [(12.2,17.5),(12.2,14.8),(17.5,14.8),(17.5,12.1),(16.5,11.2)] if three else [(15.9,17.5),(16.5,16.9)]
    points += [(16.5,-16.7),(15.7,-17.5),(-13.5,-17.5),(-16.5,-14.5),(-16.5,-4.1),(-15.3,-4.1),(-15.3,-1.2),(-16.5,-1.2),(-16.5,16.9)]
    return points

def extrusion(name, points, bottom, top, mat, parent):
    n = len(points)
    verts = [(x,y,z) for z in (bottom,top) for x,y in points]
    faces = [tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
    faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(verts,[],faces)
    mesh.update()
    obj=bpy.data.objects.new(name,mesh)
    bpy.context.collection.objects.link(obj)
    # Normalize winding before bevels / cavity booleans.
    bpy.context.view_layer.objects.active=obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.select_set(False)
    return finish(obj,mat,.14,parent)

def text(name, value, size, loc, mat, parent, back=False):
    curve=bpy.data.curves.new(name,'FONT')
    curve.body,curve.size,curve.align_x=value,size,'CENTER'
    curve.extrude=.018
    curve.bevel_depth=.007
    curve.bevel_resolution=3
    obj=bpy.data.objects.new(name,curve)
    bpy.context.collection.objects.link(obj)
    obj.location=loc
    if back: obj.rotation_euler.y=math.pi
    obj.data.materials.append(mat)
    obj.parent=parent
    bpy.context.view_layer.objects.active=obj
    obj.select_set(True)
    bpy.ops.object.convert(target='MESH')
    obj.select_set(False)
    return obj

kinds=['ndsStandard','ndsInfrared','dsiEnhanced','dsiExclusive','threeDS']
for index,kind in enumerate(kinds):
    rig=bpy.data.objects.new(kind,None)
    bpy.context.collection.objects.link(rig)
    light = kind in ('threeDS','dsiExclusive')
    color=(.70,.69,.65) if light else ((.019,.027,.026) if kind=='ndsInfrared' else (.083,.087,.092))
    plastic=material(kind+' molded plastic',color,.48)
    inset=material(kind+' inset plastic',tuple(c*.78 for c in color),.56)
    outline=contour(kind=='threeDS')
    front=extrusion('Front cover',outline,-1.86,0,plastic,rig)
    back=extrusion('Back cover',outline,-3.8,-1.95,plastic,rig)
    # A narrow dark physical seam, not a painted outline.
    extrusion('Shell joint',[(x*.994,y*.994) for x,y in outline],-1.96,-1.85,inset,rig)
    cut(front,(27.2,23.4,.7),(0,1.1,.12),.7)
    box('Label recess bed',(26.9,23.1,.10),(0,1.1,-.20),inset,.5,rig)
    cut(back,(27.8,11.5,1.25),(0,-12,-3.65),.35)
    box('Visible PCB',(27.2,10.9,.18),(0,-11.9,-3.03),pcb,.12,rig)
    for pin in range(17):
        x=(pin-8)*1.5
        box('Gold contact %02d'%pin,(1.07,6.7,.10),(x,-12,-3.17),gold,.055,rig)
        for stripe in range(3):
            # Fine plating lines catch the light without painting fake scratches.
            box('Contact finish line',(1.0,.017,.012),(x,-10.5-stripe*1.4,-3.23),gold,.006,rig)
    for rib in range(18):
        box('Protective divider %02d'%rib,(.32,10.8,.59),((rib-8.5)*1.5,-12.0,-3.47),plastic,.07,rig)
    box('Back molded panel',(27.0,19.3,.075),(0,6.7,-3.82),inset,.6,rig)
    text('Back maker mark','Nintendo',2.7,(0,8.5,-3.89),plastic,rig,True)
    code='CTR-005' if kind=='threeDS' else ('NTR-031' if kind=='ndsInfrared' else 'NTR-005')
    text('Molded model number',code,1.55,(0,5,-3.89),plastic,rig,True)
    text('Front platform', 'NINTENDO 3DS' if kind=='threeDS' else ('NINTENDO DSi' if kind=='dsiExclusive' else 'NINTENDO DS'),1.15,(0,14.5,.018),inset,rig)
    if kind=='ndsInfrared':
        box('IR transmitting window',(9,1.0,.32),(0,16.5,-1.7),inset,.1,rig)
    rig.location.x=index*42

scene=bpy.context.scene
texture_dir=ROOT/'ReferenceModels/CartridgeTextures'
texture_dir.mkdir(exist_ok=True)
grain=bpy.data.images.new('Molded ABS micro normal',width=512,height=512)
grain.colorspace_settings.name='Non-Color'
rng=random.Random(5105)
pixels=[]
for _ in range(512*512):
    # Bake the amplitude into the map: USD importers can ignore Normal Map strength.
    pixels.extend((.5+rng.uniform(-.006,.006),.5+rng.uniform(-.006,.006),1,1))
grain.pixels.foreach_set(pixels)
grain.filepath_raw=str(texture_dir/'abs-micro-normal.png')
grain.file_format='PNG'
grain.save()
grain.pack()
for material in bpy.data.materials:
    if 'plastic' not in material.name: continue
    nodes=material.node_tree.nodes
    image=nodes.new('ShaderNodeTexImage')
    image.image=grain
    image.extension='REPEAT'
    normal=nodes.new('ShaderNodeNormalMap')
    normal.inputs['Strength'].default_value=.025
    material.node_tree.links.new(image.outputs['Color'],normal.inputs['Color'])
    material.node_tree.links.new(normal.outputs['Normal'],nodes.get('Principled BSDF').inputs['Normal'])
for obj in bpy.data.objects:
    if obj.type == 'MESH':
        # Boolean-generated coplanar faces must not inherit interpolated bevel normals.
        for face in obj.data.polygons: face.use_smooth = False
        uv=obj.data.uv_layers.new(name='Mold texture coordinates')
        for face in obj.data.polygons:
            for loop_index in face.loop_indices:
                vertex=obj.data.vertices[obj.data.loops[loop_index].vertex_index].co
                uv.data[loop_index].uv=((vertex.x+17.5)/35,(vertex.y+17.5)/35)
scene['Asset scope']='All five currently recognized card variants; visual reconstructions, no invented serial numbers.'
scene['Reference']='https://commons.wikimedia.org/wiki/File:Nintendo-3ds-ds-cartridge.jpg'
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'ReferenceModels/Detailed-Cartridges.blend'))
bpy.ops.wm.usd_export(filepath=str(ROOT/'DuoDS/Resources/Detailed-Cartridges.usdz'),export_animation=False,export_materials=True,export_cameras=False,export_lights=False)
print('DETAILED_CARDS_EXPORTED',len(kinds),sum(len(o.data.polygons) for o in bpy.data.objects if o.type=='MESH'))
