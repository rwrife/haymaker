class_name FighterPose
extends RefCounted
## Local bone rotations + Hips position in rig space (port of FighterPose).

const LOWER_BONES := [14, 15, 16, 17, 18, 19, 20, 21]

var rot: Array = []
var hips := Vector3.ZERO


static func make(hips_at: Vector3) -> FighterPose:
	var p := FighterPose.new()
	p.rot.resize(FighterAssets.BONE_COUNT)
	p.rot.fill(Quaternion())
	p.hips = hips_at
	return p


func copy() -> FighterPose:
	var p := FighterPose.new()
	p.rot = rot.duplicate()
	p.hips = hips
	return p


static func blend(a: FighterPose, b: FighterPose, t: float) -> FighterPose:
	var p := FighterPose.new()
	p.rot.resize(FighterAssets.BONE_COUNT)
	for i in FighterAssets.BONE_COUNT:
		p.rot[i] = slerp_short(a.rot[i], b.rot[i], t)
	p.hips = a.hips.lerp(b.hips, t)
	return p


static func slerp_short(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	if a.dot(b) < 0.0:
		b = -b
	return a.slerp(b, clampf(t, 0.0, 1.0)).normalized()


## Scales a rotation's angle by `amount` (0 = identity).
static func scaled(q: Quaternion, amount: float) -> Quaternion:
	if q.w < 0.0:
		q = -q
	return Quaternion().slerp(q, amount).normalized() if amount <= 1.0 else _pow(q, amount)


static func _pow(q: Quaternion, amount: float) -> Quaternion:
	var angle := q.get_angle()
	if angle < 1e-5:
		return Quaternion()
	return Quaternion(q.get_axis().normalized(), angle * amount)


func globals() -> Array:
	var g := []
	g.resize(FighterAssets.BONE_COUNT)
	for b in FighterAssets.BONE_COUNT:
		var parent: int = FighterAssets.PARENTS[b]
		g[b] = (g[parent] * rot[b]).normalized() if parent >= 0 else rot[b]
	return g


## Joint (bone head) positions in rig space.
func joints(heads: Array) -> Array:
	var g := globals()
	var j := []
	j.resize(FighterAssets.BONE_COUNT)
	for b in FighterAssets.BONE_COUNT:
		var parent: int = FighterAssets.PARENTS[b]
		if parent < 0:
			j[b] = hips
		else:
			j[b] = j[parent] + (g[parent] as Quaternion) * (heads[b] - heads[parent])
	return j


## Hips travel + leg orientation from `lower` (port of mergeLower).
func merge_lower(lower: FighterPose) -> void:
	hips = lower.hips
	var reframe: Quaternion = (rot[0] as Quaternion).inverse() * lower.rot[0]
	for bone in LOWER_BONES:
		rot[bone] = (reframe * lower.rot[bone]).normalized() if FighterAssets.PARENTS[bone] == 0 else lower.rot[bone]
