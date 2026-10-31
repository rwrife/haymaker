class_name Boxer
extends Node3D
## One fighter on screen: skinned rig driven by the director + animator
## (port of BoxerModel, without IK aim / foot planting).

var rig: FighterAssets.Rig
var is_rival := false
var fighter_scale := 1.0
var motions: Dictionary
var animator: FighterAnimator
var director: FighterDirector
var skeleton: Skeleton3D
var animated: FighterPose
var last_motion = null
var _title_time = null
var _victory_time = null
var _floor := 0.0


func setup(rig_name: String, rival: bool) -> void:
	is_rival = rival
	name = rig_name
	rig = FighterAssets.rig(rig_name)
	motions = FighterAssets.motions(rig)
	animator = FighterAnimator.new(motions, rig.heads)
	director = FighterDirector.new(motions, rig.heads, animator.punching_hands)
	director.idle_rate = 0.93 if rival else 1.0
	director.idle_phase = 0.47 if rival else 0.0
	fighter_scale = 1.05 if rival else 1.0
	scale = Vector3.ONE * fighter_scale
	animator.neck_flex = 0.6 if rig_name == "atlas" else 0.75
	skeleton = FighterAssets.instantiate(rig)
	add_child(skeleton)
	var rest := FighterPose.make(rig.heads[0])
	var j := rest.joints(rig.heads)
	_floor = minf(minf(j[17].y, j[21].y), minf(j[16].y, j[20].y))
	animated = animator.pose
	_apply(animated)


func reset_motion() -> void:
	director.reset()
	animator.reset()
	_title_time = null
	_victory_time = null


func update(status, total_ticks: int, frac: float, now: float, dt: float, reduced: bool, cue: Dictionary = {"type": "none"}) -> void:
	var m := director.update({"status": status, "total_ticks": total_ticks, "frac": frac, "now": now, "dt": dt,
		"reduced": reduced, "cue": cue})
	if director.entered_action:
		animator.release_reactions()
	last_motion = m
	animated = animator.update(m, dt, now, reduced)
	_apply(animated)


func pose_title(time: float, reduced: bool) -> void:
	var dt := 0.0 if _title_time == null else minf(0.1, maxf(0.0, time - _title_time))
	_title_time = time
	var id := "warmup" if motions.has("warmup") else "idle"
	var clip = motions[id]
	var frame: float = 0.0 if reduced else fmod(time, 3600.0) * clip.fps
	var m := FighterAnimator.Motion.make(id, frame, 0.0 if reduced else clip.fps, -1, 0.3)
	animated = animator.update(m, dt, time, reduced)
	_apply(animated)


func pose_victory(time: float, reduced: bool) -> void:
	var dt := 0.0 if _victory_time == null else minf(0.1, maxf(0.0, time - _victory_time))
	_victory_time = time
	var clip = motions["victory"]
	var duration: float = maxf(1.0, clip.last_frame()) / clip.fps
	var frame: float = clip.marker("armsUp", 0.0) if reduced else fmod(time, duration) * clip.fps
	var m := FighterAnimator.Motion.make("victory", frame, 0.0 if reduced else clip.fps, -2, FighterAnimator.VICTORY_FADE)
	last_motion = m
	animated = animator.update(m, dt, time, reduced)
	_apply(animated)


func _apply(p: FighterPose) -> void:
	var hips := p.hips
	var j := p.joints(rig.heads)
	var lowest := INF
	for b in FighterAssets.BONE_COUNT:
		lowest = minf(lowest, (j[b] as Vector3).y)
	if lowest < _floor * 0.6:
		hips.y += _floor * 0.6 - lowest
	skeleton.set_bone_pose_position(0, hips)
	for b in FighterAssets.BONE_COUNT:
		skeleton.set_bone_pose_rotation(b, p.rot[b])


## World-space joint position (bone head).
func joint_world(bone: int) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin


func head_world() -> Vector3:
	var head := joint_world(5)
	var neck := joint_world(4)
	return head + (head - neck).normalized() * 0.12 * fighter_scale
