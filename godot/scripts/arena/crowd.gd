class_name Crowd
extends RefCounted
## CRW1 spectator assets (port of CrowdModel.swift): four rigged bodies, ten
## looks, four looping clips. Each spectator gets its own AnimationPlayer
## sharing the body's AnimationLibrary.

const BONE_COUNT := 23
const HIPS := 1
const CLIPS := ["sit", "sit_clap", "sit_yell", "cheer"]
const BODIES := {
	"casual-man": ["tee-gray", "polo-red", "tee-green"],
	"suit-man": ["suit-charcoal", "suit-navy", "suit-brown"],
	"casual-woman": ["tee-teal", "tee-yellow"],
	"business-woman": ["blazer-navy", "blazer-burgundy"],
}
const BODY_ORDER := ["casual-man", "suit-man", "casual-woman", "business-woman"]

static var _cache := {}


class BodyAssets:
	var body: String
	var height := 1.0
	var seat := 0.5
	var parents := []
	var translations := []
	var rotations := []
	var binds := []
	var meshes := [] # one ArrayMesh per look
	var library: AnimationLibrary
	var durations := {}

	func instantiate(look: int) -> Skeleton3D:
		var skel := Skeleton3D.new()
		skel.name = "Skeleton"
		var skin := Skin.new()
		for b in BONE_COUNT:
			skel.add_bone("b%d" % b)
			if parents[b] >= 0:
				skel.set_bone_parent(b, parents[b])
			var rest := Transform3D(Basis(rotations[b]), translations[b])
			skel.set_bone_rest(b, rest)
			skel.set_bone_pose_position(b, translations[b])
			skel.set_bone_pose_rotation(b, rotations[b])
			skin.add_bind(b, binds[b])
		var mi := MeshInstance3D.new()
		mi.name = "Body"
		mi.mesh = meshes[look % meshes.size()]
		mi.skin = skin
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = AABB(Vector3(-0.6, -0.1, -0.6), Vector3(1.2, 1.5, 1.2))
		skel.add_child(mi)
		mi.skeleton = NodePath("..")
		return skel


static func body(name: String) -> BodyAssets:
	if _cache.has(name):
		return _cache[name]
	var data := FileAccess.get_file_as_bytes("res://assets/models/" + name + ".crowd")
	if data.size() < 28 or data.slice(0, 4).get_string_from_ascii() != "CRW1":
		push_error("Haymaker: bad crowd asset " + name)
		return null
	var a := BodyAssets.new()
	a.body = name
	var vcount := data.decode_u32(4)
	var icount := data.decode_u32(8)
	var clip_count := data.decode_u32(16)
	a.height = data.decode_float(20)
	a.seat = data.decode_float(24)
	for b in BONE_COUNT:
		var o := 28 + b * 96
		a.parents.append(data.decode_s32(o))
		a.translations.append(Vector3(data.decode_float(o + 4), data.decode_float(o + 8), data.decode_float(o + 12)))
		a.rotations.append(Quaternion(data.decode_float(o + 16), data.decode_float(o + 20), data.decode_float(o + 24), data.decode_float(o + 28)).normalized())
		var m := data.slice(o + 32, o + 96).to_float32_array()
		a.binds.append(Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])),
			Vector3(m[12], m[13], m[14])))
	var vstart := 28 + BONE_COUNT * 96
	var istart := vstart + vcount * 56
	var vf := data.slice(vstart, istart).to_float32_array()
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	positions.resize(vcount)
	normals.resize(vcount)
	uvs.resize(vcount)
	bones.resize(vcount * 4)
	weights.resize(vcount * 4)
	for v in vcount:
		var f := v * 14
		positions[v] = Vector3(vf[f], vf[f + 1], vf[f + 2])
		normals[v] = Vector3(vf[f + 3], vf[f + 4], vf[f + 5])
		uvs[v] = Vector2(vf[f + 6], vf[f + 7])
		for k in 4:
			weights[v * 4 + k] = vf[f + 8 + k]
			bones[v * 4 + k] = data.decode_u16(vstart + v * 56 + 48 + k * 2)
	var indices := PackedInt32Array()
	indices.resize(icount)
	for t in range(0, icount - 2, 3):
		indices[t] = data.decode_u16(istart + t * 2)
		indices[t + 1] = data.decode_u16(istart + (t + 2) * 2)
		indices[t + 2] = data.decode_u16(istart + (t + 1) * 2)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	for look in BODIES[name]:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := StandardMaterial3D.new()
		var tex: Texture2D = load("res://assets/models/crowd-%s.jpg" % look)
		mat.albedo_texture = tex
		mat.roughness = 0.85
		mat.emission_enabled = true
		mat.emission_texture = tex
		mat.emission_energy_multiplier = 0.08
		mesh.surface_set_material(0, mat)
		a.meshes.append(mesh)
	# Clips -> Animation resources.
	var off := istart + icount * 2
	off += (4 - off % 4) % 4
	a.library = AnimationLibrary.new()
	for c in clip_count:
		var id := data.slice(off, off + 16).get_string_from_ascii()
		var fps := data.decode_float(off + 16)
		var frames := data.decode_u32(off + 20)
		off += 24
		var rots := data.slice(off, off + frames * BONE_COUNT * 16).to_float32_array()
		off += frames * BONE_COUNT * 16
		var hips := data.slice(off, off + frames * 12).to_float32_array()
		off += frames * 12
		var anim := Animation.new()
		var duration := float(maxi(1, frames - 1)) / fps
		anim.length = duration
		anim.loop_mode = Animation.LOOP_LINEAR
		for b in range(1, BONE_COUNT):
			var tr := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(tr, NodePath("Skeleton:b%d" % b))
			for fr in frames:
				var q := (fr * BONE_COUNT + b) * 4
				anim.rotation_track_insert_key(tr, float(fr) / fps, Quaternion(rots[q], rots[q + 1], rots[q + 2], rots[q + 3]).normalized())
		var pt := anim.add_track(Animation.TYPE_POSITION_3D)
		anim.track_set_path(pt, NodePath("Skeleton:b%d" % HIPS))
		for fr in frames:
			anim.position_track_insert_key(pt, float(fr) / fps, Vector3(hips[fr * 3], hips[fr * 3 + 1], hips[fr * 3 + 2]))
		a.library.add_animation(id, anim)
		a.durations[id] = duration
	_cache[name] = a
	return a


static func all_bodies() -> Array:
	var out := []
	for n in BODY_ORDER:
		var b := body(n)
		if b == null:
			return []
		out.append(b)
	return out


## SplitMix64 step: returns [next_state, value in 0..1).
static func splitmix(state: int) -> Array:
	state = state + SeededRNG.DEFAULT_SEED
	var z := state
	z = (z ^ SeededRNG.lsr(z, 30)) * -4658895280553007687 # 0xBF58476D1CE4E5B9
	z = (z ^ SeededRNG.lsr(z, 27)) * -7723592293110705685 # 0x94D049BB133111EB
	z = z ^ SeededRNG.lsr(z, 31)
	return [state, float(SeededRNG.lsr(z, 40)) / float(1 << 24)]


## One spectator: crossfades between looping clips on its own random schedule.
class Member:
	extends Node3D

	var assets: BodyAssets
	var player: AnimationPlayer
	var clip := "sit"
	var remaining := 0.0
	var cheer_soon := false
	var rng := 0

	func setup(p_assets: BodyAssets, look: int, seed: int) -> void:
		assets = p_assets
		rng = seed
		add_child(assets.instantiate(look))
		player = AnimationPlayer.new()
		add_child(player)
		player.add_animation_library("", assets.library)
		remaining = random() * 6.0
		_play("sit" if random() < 0.7 else "sit_clap", 0.0)

	func random() -> float:
		var r := Crowd.splitmix(rng)
		rng = r[0]
		return r[1]

	func tick(dt: float, excitement: float) -> void:
		remaining -= dt
		if remaining > 0.0:
			return
		var pick: String
		if cheer_soon:
			pick = "cheer"
			cheer_soon = false
		elif clip == "cheer":
			pick = "sit" if random() < 0.7 else "sit_clap"
		else:
			var roll := random()
			var calm := 0.45 * (1.0 - excitement)
			if roll < calm:
				pick = "sit"
			elif roll < calm + 0.28:
				pick = "sit_clap"
			elif roll < calm + 0.45:
				pick = "sit_yell"
			else:
				pick = "cheer"
		remaining = 2.5 + random() * 3.0 if pick == "cheer" else 3.0 + random() * 7.0
		if pick != clip:
			_play(pick, 0.8 if pick == "cheer" or clip == "cheer" else 0.5)

	func erupt() -> void:
		if clip == "cheer" or random() >= 0.6:
			return
		cheer_soon = true
		remaining = random() * 0.8

	func _play(id: String, blend: float) -> void:
		var phase := random() * 20.0
		var speed := 0.9 + random() * 0.2
		player.play(id, blend, speed)
		player.seek(fmod(phase, assets.durations[id]), true)
		clip = id
