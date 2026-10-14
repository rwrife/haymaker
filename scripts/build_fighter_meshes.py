"""Offline art build: sculpt and export native mesh assets (Blender 4+).
The shipped game has no Blender dependency. Coordinates are Y-up, meters.
"""
import bpy
import math
from pathlib import Path
OUT = Path(__file__).resolve().parents[1] / 'Haymaker' / 'Models'

def clear():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

def oval(position, scale):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=24, location=position)
    obj = bpy.context.object
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return obj

def loft(rings):
    verts=[]; faces=[]; count=48
    for y, rx, rz in rings:
        for i in range(count):
            a=i*2*math.pi/count
            verts.append((math.cos(a)*rx, y, math.sin(a)*rz))
    for j in range(len(rings)-1):
        for i in range(count):
            a=j*count+i; b=j*count+(i+1)%count; c=(j+1)*count+i; d=(j+1)*count+(i+1)%count
            faces.append((a,c,d,b))
    faces.append(tuple(reversed(range(count))))
    faces.append(tuple((len(rings)-1)*count+i for i in range(count)))
    mesh=bpy.data.meshes.new('sculpt'); mesh.from_pydata(verts,[],faces); mesh.update()
    obj=bpy.data.objects.new('sculpt',mesh); bpy.context.collection.objects.link(obj)
    return obj

def fuse(name, resolution):
    bpy.ops.object.select_all(action='SELECT')
    bpy.context.view_layer.objects.active=bpy.context.selected_objects[0]
    bpy.ops.object.join()
    obj=bpy.context.object; obj.name=name
    remesh=obj.modifiers.new('Continuous sculpt surface','REMESH'); remesh.mode='VOXEL'; remesh.voxel_size=resolution; remesh.use_smooth_shade=True
    bpy.ops.object.modifier_apply(modifier=remesh.name)
    smooth=obj.modifiers.new('Sculpt polish','SMOOTH'); smooth.factor=0.85; smooth.iterations=5
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    sub=obj.modifiers.new('Surface refinement','SUBSURF'); sub.levels=1
    bpy.ops.object.modifier_apply(modifier=sub.name)
    decimate=obj.modifiers.new('Mobile mesh budget','DECIMATE'); decimate.ratio=0.35
    bpy.ops.object.modifier_apply(modifier=decimate.name)
    for p in obj.data.polygons: p.use_smooth=True
    # Preserve authored Y-up coordinates. OBJ exporter is explicitly Y-up too.
    bpy.ops.wm.obj_export(filepath=str(OUT/(name+'.obj')), export_selected_objects=True, forward_axis='Y', up_axis='Z', export_materials=False)

clear()
loft([(0,.32,.19),(.13,.34,.20),(.3,.39,.22),(.50,.47,.245),(.68,.53,.26),(.80,.52,.24),(.90,.38,.20),(.96,.19,.16)])
for side in [-1,1]:
    oval((side*.235,.65,.15),(.26,.17,.145))
    for i in range(3): oval((side*.125,.4-i*.13,.18),(.125,.083,.065))
    oval((side*.31,.4,-.035),(.09,.30,.15))
    oval((side*.41,.79,-.06),(.19,.15,.17))
oval((0,1.01,0),(.145,.18,.145))
fuse('baxter-torso',.015)
clear()
# Jaw, temples, cheekbones, brow ridge and nose blend into one continuous face.
loft([(-.18,.12,.12),(-.13,.17,.14),(-.02,.205,.17),(.12,.215,.178),(.25,.20,.17),(.34,.13,.12)])
for side in [-1,1]:
    oval((side*.203,.03,-.015),(.04,.066,.04))
    oval((side*.127,.025,.15),(.071,.044,.046))
    oval((side*.099,.166,.145),(.091,.033,.062))
    oval((side*.093,-.08,.115),(.075,.065,.048))
oval((0,.073,.171),(.034,.073,.046))
oval((0,.019,.194),(.041,.027,.031))
oval((0,-.135,.104),(.099,.044,.048))
fuse('boxer-head',.006)
