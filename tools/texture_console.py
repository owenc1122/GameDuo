"""Apply exportable PBR textures to the existing 3DS XL rig; keep all geometry and pivots.
Visual reference: https://www.nintendo.co.jp/hardware/3dsseries/lineup/3dsll_black.html
Procedural microstructure is an approximation, not a surface scan.
Run against ReferenceModels/3DSXL-drag-insertion.blend after building the slot rig.
"""
import bpy
import random
import math
from pathlib import Path

root=Path(__file__).resolve().parents[1]
out=root/'ReferenceModels/ConsoleTextures'
out.mkdir(exist_ok=True)

def image(name, pixels, width, height, extension='png'):
    img=bpy.data.images.new(name,width=width,height=height,float_buffer=extension=='hdr')
    img.colorspace_settings.name='Non-Color'
    img.pixels.foreach_set(pixels)
    img.filepath_raw=str(out/(name+'.'+extension))
    img.file_format='HDR' if extension=='hdr' else 'PNG'
    img.save()
    img.pack()
    return img

rng=random.Random(305)
pixels=[]
for _ in range(1024*1024):
    pixels.extend((.5+rng.uniform(-.004,.004),.5+rng.uniform(-.004,.004),1,1))
normal_image=image('Molded-ABS-normal',pixels,1024,1024)

profiles={
    'Graphite · fine matte inner face': (.48, (.012,.014,.013)),
    'Graphite · satin molded ABS': (.36, (.018,.020,.019)),
    'Buttons · black resin': (.30, (.016,.019,.018)),
    'Rubber · charcoal': (.78, (.018,.020,.019)),
    'Circle pad · soft grey': (.70, (.34,.36,.345)),
}
for name,(rough,color) in profiles.items():
    material=bpy.data.materials[name]
    nodes=material.node_tree.nodes
    p=nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Roughness'].default_value=rough
    for link in list(material.node_tree.links):
        if link.to_socket==p.inputs['Normal']: material.node_tree.links.remove(link)
    tex=nodes.new('ShaderNodeTexImage')
    tex.image=normal_image
    n=nodes.new('ShaderNodeNormalMap')
    material.node_tree.links.new(tex.outputs['Color'],n.inputs['Color'])
    material.node_tree.links.new(n.outputs['Normal'],p.inputs['Normal'])
    rough_pixels=[]
    for _ in range(512*512):
        v=rough+rng.uniform(-.018,.018)
        rough_pixels.extend((v,v,v,1))
    rough_image=image('Roughness-'+str(len(bpy.data.images)),rough_pixels,512,512)
    r=nodes.new('ShaderNodeTexImage')
    r.image=rough_image
    material.node_tree.links.new(r.outputs['Color'],p.inputs['Roughness'])

glass=bpy.data.materials['LCD · inactive grey glass'].node_tree.nodes.get('Principled BSDF')
glass.inputs['Base Color'].default_value=(.003,.004,.005,1)
glass.inputs['Roughness'].default_value=.16
glass.inputs['Coat Weight'].default_value=.25
for obj in bpy.data.objects:
    if obj.type!='MESH' or not any(m and m.name in profiles for m in obj.data.materials): continue
    uv=obj.data.uv_layers.active or obj.data.uv_layers.new(name='Surface microtexture UV')
    for face in obj.data.polygons:
        normal=face.normal
        axis=max(range(3),key=lambda i: abs(normal[i]))
        a,b=[i for i in range(3) if i!=axis]
        for i in face.loop_indices:
            point=obj.data.vertices[obj.data.loops[i].vertex_index].co
            uv.data[i].uv=(point[a]/16+.5,point[b]/16+.5)

# Neutral photographic softboxes: reflection environment only, never a visible background.
env=[]
for y in range(256):
    v=y/255
    for x in range(512):
        u=x/511
        key=2.4*math.exp(-((u-.27)/.075)**8-((v-.58)/.22)**8)
        fill=.8*math.exp(-((u-.74)/.13)**8-((v-.62)/.27)**8)
        radiance=.035+key+fill
        env.extend((radiance,radiance,radiance,1))
studio=image('Neutral-Softboxes',env,512,256,'hdr')
studio.filepath_raw=str(root/'DuoDS/Resources/Console-Studio.hdr')
studio.save()
bpy.context.scene['Materials']='PBR matte ABS, satin edge, resin keys, soft rubber, dark glass and plated ports. No universal material override.'
bpy.ops.wm.save_as_mainfile(filepath=str(root/'ReferenceModels/3DSXL-textured-insertion.blend'))
bpy.ops.wm.usd_export(filepath=str(root/'DuoDS/Resources/3DSXL-Cartridge-Open-Transition.usdz'),export_animation=False,export_materials=True,export_lights=False,export_cameras=False)
print('CONSOLE_TEXTURES_EXPORTED')
