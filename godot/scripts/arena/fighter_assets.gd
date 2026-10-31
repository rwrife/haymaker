class_name FighterAssets
extends RefCounted
## Loads the shared Haymaker binary assets (ports of FighterRig.swift / FighterClips.swift):
##   .fighter (HMR2 skinned rig), .fighteruv (HMT1 textured topology), fighter.clips (HMC1 motion library).

const BONE_COUNT := 22
const BONE_NAMES := ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
	"LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand",
	"RightShoulder", "RightArm", "RightForeArm", "RightHand",
	"LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase",
	"RightUpLeg", "RightLeg", "RightFoot", "RightToeBase"]
const PARENTS := [-1, 0, 1, 2, 3, 4, 3, 6, 7, 8, 3, 10, 11, 12, 0, 14, 15, 16, 0, 18, 19, 20]
const LIMB_BONES := [6, 7, 8, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21]
const CORRECTION_SOURCE := {9: 8, 13: 12}
const MODELS := "res://assets/models/"

static var _rig_cache := {}
static var _library = null
static var _motion_cache := {}


class Rig:
	var name: String
	var heads: Array = [] # Vector3 per bone
	var aims: Array = []
	var mesh: ArrayMesh
	var min_y := 0.0
	var height := 1.8


class Clip:
	var id: String
	var fps := 30.0
	var frame_count := 1
	var loops := false
	var period := 1.0
	var markers := {}
	var local: Array = [] # frame-major Quaternion list (frame * BONE_COUNT + bone)
	var hips: Array = [] # Vector3 per frame

	func marker(name: String, fallback: float) -> float:
		return markers.get(name, fallback)

	func last_frame() -> float:
		return float(frame_count - 1)

	func wrap_frame(frame: float) -> float:
		if loops and period > 0.0:
			return fposmod(frame, period)
		return clampf(frame, 0.0, last_frame())

	func sample(frame: float, rotations: Array) -> Vector3:
		var f := wrap_frame(frame)
		var i0 := mini(int(f), frame_count - 1)
		var i1 := (i0 + 1) % frame_count if loops else mini(i0 + 1, frame_count - 1)
		var t := f - float(i0)
		var b0 := i0 * BONE_COUNT
		var b1 := i1 * BONE_COUNT
		for bone in BONE_COUNT:
			rotations[bone] = FighterAssets.nlerp(local[b0 + bone], local[b1 + bone], t)
		return hips[i0].lerp(hips[i1], t)

	func sample_into(frame: float, pose) -> void:
		pose.hips = sample(frame, pose.rot)

	func _frames(frame: float) -> Array:
		var f := wrap_frame(frame)
		var i0 := mini(int(f), frame_count - 1)
		var i1 := (i0 + 1) % frame_count if loops else mini(i0 + 1, frame_count - 1)
		return [i0, i1, f - float(i0)]

	func rotation(bone: int, frame: float) -> Quaternion:
		var s := _frames(frame)
		return FighterAssets.nlerp(local[s[0] * BONE_COUNT + bone], local[s[1] * BONE_COUNT + bone], s[2])

	func hips_at(frame: float) -> Vector3:
		var s := _frames(frame)
		return (hips[s[0]] as Vector3).lerp(hips[s[1]], s[2])


static func nlerp(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	if t <= 0.0:
		return a
	if a.dot(b) < 0.0:
		b = -b
	if t >= 1.0:
		return b
	return (a * (1.0 - t) + b * t).normalized()


static func shortest_arc(a: Vector3, b: Vector3) -> Quaternion:
	var d := a.dot(b)
	if d > 0.999999:
		return Quaternion()
	if d < -0.999999:
		var axis := Vector3(1, 0, 0).cross(a)
		if axis.length() < 1e-4:
			axis = Vector3(0, 1, 0).cross(a)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(a, b)


static func _read(path: String) -> PackedByteArray:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("Haymaker: missing asset " + path)
	return bytes


static func _vec(f: PackedFloat32Array, i: int) -> Vector3:
	return Vector3(f[i], f[i + 1], f[i + 2])


## Parses `<name>.fighter` + `<name>.fighteruv` into a skinned, textured ArrayMesh.
static func rig(name: String) -> Rig:
	if _rig_cache.has(name):
		return _rig_cache[name]
	var data := _read(MODELS + name + ".fighter")
	assert(data.slice(0, 4).get_string_from_ascii() == "HMR2")
	var vertex_count := data.decode_u32(4)
	var index_count := data.decode_u32(8)
	var bone_count := data.decode_u32(12)
	assert(bone_count == BONE_COUNT)
	var r := Rig.new()
	r.name = name
	var off := 16
	for b in BONE_COUNT:
		var f := data.slice(off + 4, off + 28).to_float32_array()
		r.heads.append(_vec(f, 0))
		r.aims.append(_vec(f, 3))
		off += 28
	var vbytes := data.slice(off, off + vertex_count * 60)
	var vf := vbytes.to_float32_array()
	off += vertex_count * 60
	# Textured topology
	var uvdata := _read(MODELS + name + ".fighteruv")
	assert(uvdata.slice(0, 4).get_string_from_ascii() == "HMT1")
	var uv_count := uvdata.decode_u32(4)
	var uv_index_count := uvdata.decode_u32(8)
	var uvf := uvdata.slice(12, 12 + uv_count * 12).to_float32_array()
	var src := uvdata.slice(12, 12 + uv_count * 12).to_int32_array()
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	positions.resize(uv_count)
	normals.resize(uv_count)
	uvs.resize(uv_count)
	bones.resize(uv_count * 4)
	weights.resize(uv_count * 4)
	var min_y := INF
	var max_y := -INF
	for i in uv_count:
		var s: int = src[i * 3]
		var base := s * 15
		var p := _vec(vf, base)
		positions[i] = p
		normals[i] = _vec(vf, base + 3)
		uvs[i] = Vector2(uvf[i * 3 + 1], uvf[i * 3 + 2])
		var wsum := 0.0
		for k in 4:
			wsum += vf[base + 9 + k]
		for k in 4:
			weights[i * 4 + k] = vf[base + 9 + k] / wsum if wsum > 0.0 else (1.0 if k == 0 else 0.0)
			bones[i * 4 + k] = vbytes.decode_u16(s * 60 + 52 + k * 2)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	var ioff := 12 + uv_count * 12
	var raw_idx := uvdata.slice(ioff, ioff + uv_index_count * 4).to_int32_array()
	# SceneKit is counter-clockwise front-facing; Godot expects clockwise.
	var indices := PackedInt32Array()
	indices.resize(raw_idx.size())
	for t in range(0, raw_idx.size() - 2, 3):
		indices[t] = raw_idx[t]
		indices[t + 1] = raw_idx[t + 2]
		indices[t + 2] = raw_idx[t + 1]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	var tex_path := MODELS + name + "-basecolor.jpg"
	if ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)
	mat.roughness = 0.65
	mat.metallic = 0.0
	mesh.surface_set_material(0, mat)
	r.mesh = mesh
	r.min_y = min_y
	r.height = max_y - min_y
	_rig_cache[name] = r
	return r


## Builds a Skeleton3D + skinned MeshInstance3D for a rig.
static func instantiate(r: Rig) -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "Skeleton"
	var skin := Skin.new()
	for b in BONE_COUNT:
		skel.add_bone(BONE_NAMES[b])
		var parent: int = PARENTS[b]
		if parent >= 0:
			skel.set_bone_parent(b, parent)
		var offset: Vector3 = r.heads[b] - (r.heads[parent] if parent >= 0 else Vector3.ZERO)
		skel.set_bone_rest(b, Transform3D(Basis(), offset))
		skel.set_bone_pose_position(b, offset)
		skel.set_bone_pose_rotation(b, Quaternion())
		skin.add_bind(b, Transform3D(Basis(), -r.heads[b]))
	var mi := MeshInstance3D.new()
	mi.name = "Body"
	mi.mesh = r.mesh
	mi.skin = skin
	skel.add_child(mi)
	mi.skeleton = NodePath("..")
	return skel


# MARK: - Motion library (HMC1)

class Library:
	var source_heads: Array = []
	var source_aims: Array = []
	var clips := {} # name -> {fps, frames, loops, markers, hips: Array, deltas: Array[Quaternion]}


static func library() -> Library:
	if _library != null:
		return _library
	var data := _read(MODELS + "fighter.clips")
	assert(data.slice(0, 4).get_string_from_ascii() == "HMC1")
	var lib := Library.new()
	var bone_count := data.decode_u32(4)
	var clip_count := data.decode_u32(8)
	assert(bone_count == BONE_COUNT)
	var off := 16
	for b in BONE_COUNT:
		var f := data.slice(off, off + 24).to_float32_array()
		lib.source_heads.append(_vec(f, 0))
		lib.source_aims.append(_vec(f, 3))
		off += 24
	for c in clip_count:
		var cname := data.slice(off, off + 24).get_string_from_ascii()
		var fps := data.decode_float(off + 24)
		var frames := data.decode_u32(off + 28)
		var flags := data.decode_u32(off + 32)
		var marker_count := data.decode_u32(off + 36)
		off += 40
		var markers := {}
		for m in marker_count:
			var mname := data.slice(off, off + 16).get_string_from_ascii()
			markers[mname] = clampf(data.decode_float(off + 16), 0.0, float(frames - 1))
			off += 20
		var hips := []
		var deltas := []
		var stride := 12 + BONE_COUNT * 16
		var ff := data.slice(off, off + frames * stride).to_float32_array()
		for fr in frames:
			var base := fr * (stride / 4)
			hips.append(_vec(ff, base))
			for b in BONE_COUNT:
				var q := base + 3 + b * 4
				deltas.append(Quaternion(ff[q], ff[q + 1], ff[q + 2], ff[q + 3]).normalized())
		off += frames * stride
		lib.clips[cname] = {"fps": fps, "frames": frames, "loops": (flags & 1) != 0, "markers": markers, "hips": hips, "deltas": deltas}
	_library = lib
	return lib


## All clips retargeted onto a rig (FighterMotionSet).
static func motions(r: Rig) -> Dictionary:
	if _motion_cache.has(r.name):
		return _motion_cache[r.name]
	var lib := library()
	var correction := []
	correction.resize(BONE_COUNT)
	correction.fill(Quaternion())
	for bone in LIMB_BONES:
		var target: Vector3 = (r.aims[bone] - r.heads[bone]).normalized()
		var source: Vector3 = (lib.source_aims[bone] - lib.source_heads[bone]).normalized()
		correction[bone] = shortest_arc(target, source)
	for bone in CORRECTION_SOURCE:
		correction[bone] = correction[CORRECTION_SOURCE[bone]]
	var source_hips: Vector3 = lib.source_heads[0]
	var scale: float = r.heads[0].y / source_hips.y if source_hips.y > 1e-5 else 1.0
	var result := {}
	for cname in lib.clips:
		var src: Dictionary = lib.clips[cname]
		var clip := Clip.new()
		clip.id = cname
		clip.fps = src.fps
		clip.frame_count = src.frames
		clip.loops = src.loops
		clip.markers = src.markers
		var global := []
		global.resize(BONE_COUNT)
		for frame in clip.frame_count:
			for bone in BONE_COUNT:
				global[bone] = src.deltas[frame * BONE_COUNT + bone] * correction[bone]
			for bone in BONE_COUNT:
				var parent: int = PARENTS[bone]
				var q: Quaternion = (global[parent].inverse() * global[bone] if parent >= 0 else global[bone]).normalized()
				if frame > 0 and q.dot(clip.local[(frame - 1) * BONE_COUNT + bone]) < 0.0:
					q = -q
				clip.local.append(q)
			clip.hips.append(r.heads[0] + (src.hips[frame] - source_hips) * scale)
		clip.period = float(clip.frame_count)
		if clip.loops and clip.frame_count > 2:
			var last := (clip.frame_count - 1) * BONE_COUNT
			var duplicate: bool = clip.hips[0].distance_to(clip.hips[clip.frame_count - 1]) < 0.002
			for b in BONE_COUNT:
				if absf(clip.local[b].dot(clip.local[last + b])) <= 0.99995:
					duplicate = false
					break
			if duplicate:
				clip.period = float(clip.frame_count - 1)
		result[cname] = clip
	_motion_cache[r.name] = result
	return result
