class_name Arena
extends Node3D
## The 3D arena (port of MatchScene.swift). Presentation reads the
## deterministic engine; animation never changes the rules.

const POST_BOUT_RENDER_SECONDS := 6.0
const RESULTS_DELAY := 2.2
const LIGHT_SCALE := 0.0042

var camera: Camera3D
var hero: Boxer
var rival: Boxer
var choreographer: Choreographer
var stage: Node3D
var mist: Node3D
var title_screen := false
var career_victory := false
var portrait := true
var shake := 0.0
var excitement := 0.0
var spectators: Array = []
var flash_nodes: Array = []
var _effects: Array = []
var _camera_follow := Vector3.ZERO
var _last_crowd_time = null
var _puff: Texture2D


func _init(p_title_screen: bool = false) -> void:
	title_screen = p_title_screen


func _ready() -> void:
	stage = Node3D.new()
	stage.name = "Stage"
	add_child(stage)
	_puff = _make_puff()
	_build_environment()
	_build_ring()
	_build_stadium()
	_build_lighting()
	_build_mist()
	hero = Boxer.new()
	hero.setup("mack", false)
	rival = Boxer.new()
	rival.setup("bruiser", true)
	stage.add_child(rival)
	stage.add_child(hero)
	camera = Camera3D.new()
	camera.near = 0.1
	camera.far = 60.0
	camera.fov = 48.0
	add_child(camera)
	camera.current = true
	choreographer = Choreographer.new(hero, rival)
	choreographer.reset()
	choreographer.rest_pose()
	layout(portrait)
	if title_screen:
		render_title(0.0, true)


# MARK: - Materials / helpers

static func mat(color: Color, metal: float = 0.0, roughness: float = 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = roughness
	return m


static func glow(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color * energy
	return m


func _node(mesh: Mesh, at: Vector3, material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if material != null:
		mi.material_override = material
	mi.position = at
	stage.add_child(mi)
	return mi


func _box(size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return _node(b, at, material)


func _torus(ring: float, pipe: float, at: Vector3, material: Material) -> MeshInstance3D:
	var t := TorusMesh.new()
	t.inner_radius = ring - pipe
	t.outer_radius = ring + pipe
	t.rings = 64
	t.ring_segments = 12
	return _node(t, at, material)


func _segment(a: Vector3, b: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = a.distance_to(b)
	c.radial_segments = 12
	c.rings = 1
	var mi := _node(c, (a + b) / 2.0, material)
	var dir := (b - a).normalized()
	var up := Vector3.UP
	var axis := up.cross(dir)
	if axis.length() > 1e-5:
		mi.quaternion = Quaternion(axis.normalized(), acos(clampf(up.dot(dir), -1.0, 1.0)))
	return mi


func _letter(text: String, size: float, at: Vector3, material: Material, depth: float) -> MeshInstance3D:
	var t := TextMesh.new()
	t.text = text
	t.font_size = 64
	t.pixel_size = size / 64.0
	t.depth = depth
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	t.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Avenir Next", "Segoe UI", "Roboto", "Arial"])
	f.font_weight = 900
	f.font_italic = true
	t.font = f
	return _node(t, at, material)


static func _make_puff() -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 128
	t.height = 128
	return t


# MARK: - Build

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.014, 0.023, 0.047)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.36, 0.45)
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.9
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.05, 0.07, 0.11)
	env.fog_depth_begin = 9.0
	env.fog_depth_end = 30.0
	env.fog_depth_curve = 1.4
	env.fog_density = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _build_ring() -> void:
	var ivory := mat(Color(0.6, 0.56, 0.45), 0.0, 0.95)
	_box(Vector3(9.5, 0.16, 9.5), Vector3(0, -0.08, 0), ivory)
	_box(Vector3(9.7, 0.7, 9.7), Vector3(0, -0.52, 0), mat(Color(0.025, 0.055, 0.13)))
	var navy := mat(Color(0.04, 0.11, 0.24), 0.0, 0.8)
	var gold := mat(Color(0.75, 0.49, 0.12), 0.5, 0.45)
	_torus(1.8, 0.035, Vector3(0, 0.016, 0), navy)
	_torus(1.67, 0.024, Vector3(0, 0.019, 0), gold)
	var logo := _letter("H", 1.9, Vector3(-0.72, 0.025, 0.68), navy, 0.002)
	logo.rotation.x = -PI / 2
	var post_mat := mat(Color(0.33, 0.33, 0.33), 0.9, 0.25)
	for x in [-4.5, 4.5]:
		for z in [-4.5, 4.5]:
			var pad := mat(Color(0.62, 0.025, 0.045) if x > 0 else Color(0.04, 0.18, 0.55), 0.0, 0.4)
			_box(Vector3(0.28, 2.35, 0.28), Vector3(x, 1.1, z), post_mat)
			for y in [0.6, 1.15, 1.7]:
				_box(Vector3(0.38, 0.32, 0.38), Vector3(x, y, z), pad)
	var colors := [Color(0.045, 0.16, 0.43), Color(0.78, 0.78, 0.78), Color(0.64, 0.02, 0.03), Color(0.78, 0.78, 0.78)]
	var heights := [0.58, 1.08, 1.58, 2.08]
	for i in 4:
		var rope := mat(colors[i], 0.0, 0.6)
		var y: float = heights[i]
		for x in [-4.5, 4.5]:
			_segment(Vector3(x, y, -4.5), Vector3(x, y, 4.5), 0.038, rope)
		_segment(Vector3(-4.5, y, -4.5), Vector3(4.5, y, -4.5), 0.038, rope)


func _build_stadium() -> void:
	var wall := CylinderMesh.new()
	wall.top_radius = 14.1
	wall.bottom_radius = 14.1
	wall.height = 12.0
	wall.cap_top = false
	wall.cap_bottom = false
	wall.radial_segments = 64
	var wall_mat := mat(Color(0.045, 0.075, 0.13), 0.0, 1.0)
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_node(wall, Vector3(0, 4, -2), wall_mat)
	var seating := mat(Color(0.018, 0.028, 0.052), 0.0, 1.0)
	var bench_mat := mat(Color(0.05, 0.06, 0.09), 0.0, 0.9)
	var crowd := Crowd.all_bodies()
	var row_rise := 0.62
	var row_depth := 1.18
	var bench_height := 0.55
	var pitch := 0.82
	var index := 0
	var flash_mat := StandardMaterial3D.new()
	flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash_mat.albedo_texture = _puff
	flash_mat.albedo_color = Color(0.72 * 2.0, 0.85 * 2.0, 2.0)
	flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_mat.no_depth_test = false
	flash_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var flash_quad := QuadMesh.new()
	flash_quad.size = Vector2(0.42, 0.42)
	for row in 6:
		var z := -6.3 - float(row) * row_depth
		var ground := float(row) * row_rise - 0.1
		_box(Vector3(29, 0.45, row_depth), Vector3(0, ground - 0.225, z), seating)
		_box(Vector3(29, bench_height, 0.72), Vector3(0, ground + bench_height / 2.0, z - 0.42), bench_mat)
		if row >= 5 or crowd.is_empty():
			continue
		var depth := z + 2.0
		var wall_reach := sqrt(196.0 - depth * depth) - 0.7
		var half := minf(9.0 + float(row) * 0.7, wall_reach)
		var seats := int(half * 2.0 / pitch)
		for column in seats:
			var hash := index * SeededRNG.DEFAULT_SEED + SeededRNG.MULTIPLIER
			hash ^= SeededRNG.lsr(hash, 29)
			var this_index := index
			index += 1
			if SeededRNG.umod(hash, 9) == 0:
				continue
			var assets: Crowd.BodyAssets = crowd[SeededRNG.umod(SeededRNG.lsr(hash, 8), crowd.size())]
			var look := SeededRNG.umod(SeededRNG.lsr(hash, 16), Crowd.BODIES[assets.body].size())
			var person := Crowd.Member.new()
			person.setup(assets, look, hash)
			var jitter := (float(SeededRNG.umod(SeededRNG.lsr(hash, 24), 100)) / 100.0 - 0.5) * 0.12
			var x := -half + (float(column) + 0.5) * pitch + jitter
			var stature := 0.97 + float(SeededRNG.umod(SeededRNG.lsr(hash, 32), 7)) * 0.01
			var s := bench_height / assets.seat * stature
			var turn := (float(SeededRNG.umod(SeededRNG.lsr(hash, 40), 100)) / 100.0 - 0.5) * 0.2
			person.scale = Vector3.ONE * s
			person.position = Vector3(x, ground + bench_height - assets.seat * s, z - 0.25)
			person.rotation.y = atan2(-x, -z) * 0.45 + turn
			stage.add_child(person)
			spectators.append(person)
			if this_index % 11 == 0:
				var flash := _node(flash_quad, Vector3(x + 0.2, ground + 1.25, z + 0.1), flash_mat.duplicate())
				flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				flash.visible = false
				flash_nodes.append(flash)
	for x in [-7.0, 7.0]:
		_box(Vector3(1.2, 4, 0.04), Vector3(x, 5.8, -13.3), mat(Color(0.025, 0.065, 0.13)))
		_letter("H", 1.1, Vector3(x - 0.43, 5.4, -13.24), mat(Color(0.83, 0.57, 0.2), 0.8), 0.01)
	var truss := mat(Color(0.16, 0.16, 0.16), 0.8)
	var sphere := SphereMesh.new()
	sphere.radius = 0.14
	sphere.height = 0.28
	var fixture := glow(Color(0.65, 0.8, 1.0), 3.0)
	for z in [-5.0, -9.0]:
		_segment(Vector3(-12, 4.9, z), Vector3(12, 4.9, z), 0.1, truss)
		for x in [-8.0, -4.0, 0.0, 4.0, 8.0]:
			_node(sphere, Vector3(x, 4.75, z), fixture)
	_animate_crowd(0.0, true)


func _spotlight(at: Vector3, color: Color, intensity: float, shadows: bool) -> void:
	var l := SpotLight3D.new()
	l.light_color = color
	l.light_energy = intensity * LIGHT_SCALE
	l.spot_angle = 68.0 / 2.0 + 10.0
	l.spot_angle_attenuation = 0.6
	l.spot_range = 24.0
	l.spot_attenuation = 0.6
	l.shadow_enabled = shadows
	l.shadow_opacity = 0.6
	add_child(l)
	l.look_at_from_position(at, Vector3(0, 1, 0))


func _build_lighting() -> void:
	_spotlight(Vector3(-3, 6, 4), Color(1, 0.87, 0.68), 780, true)
	_spotlight(Vector3(4, 5, -3), Color(0.38, 0.62, 1), 620, false)
	_spotlight(Vector3(0, 7, 1), Color(0.85, 0.85, 0.85), 180, false)
	_build_beams()


# MARK: - Moving show lights

# The Mobile renderer has no volumetric fog, so each beam is a cone whose
# brightness fades toward its silhouette, along its length and where it meets
# the scene, with scrolling haze for drifting smoke.
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 beam_color : source_color = vec4(0.7, 0.82, 1.0, 1.0);
uniform float intensity = 0.5;
uniform float beam_length = 18.0;
uniform float edge_power = 1.6;
uniform float soft_distance = 0.8;
uniform sampler2D haze_noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying float along;

void vertex() {
	along = clamp((beam_length * 0.5 - VERTEX.y) / beam_length, 0.0, 1.0);
}

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(facing, edge_power);
	float falloff = pow(1.0 - along, 1.7) * smoothstep(0.0, 0.08, along);
	vec2 drift_a = vec2(UV.x * 3.0, along * 1.4 - TIME * 0.03);
	vec2 drift_b = vec2(UV.x * 5.0 + 0.37, along * 2.6 + TIME * 0.045);
	float haze = texture(haze_noise, drift_a).r * 0.7 + texture(haze_noise, drift_b).r * 0.5;
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((VERTEX.z - scene.z / scene.w) / soft_distance, 0.0, 1.0);
	ALBEDO = beam_color.rgb * intensity * core * falloff * (0.35 + haze) * soft;
}
"""
const BEAM_LENGTH := 18.0
const BEAM_HALF_ANGLE := 6.0
## Show lights sweep at half the title-screen pace during a bout.
const FIGHT_BEAM_SPEED := 0.5
## Only the overhead pair (the first two rigs) stays lit during a bout.
const FIGHT_BEAM_COUNT := 2

## source, colour, resting aim (used in bouts and with Reduced Motion), sweep
## centre, sweep extents and phase for each fixture.
const BEAM_RIGS := [
	[Vector3(-6.0, 8.6, -7.5), Color(0.62, 0.78, 1.0), Vector3(-4.6, 0.0, -5.6), Vector3(-1.5, 0.4, -3.5), Vector2(6.5, 4.5), 0.0],
	[Vector3(6.0, 8.6, -7.5), Color(0.62, 0.78, 1.0), Vector3(4.6, 0.0, -5.6), Vector3(1.5, 0.4, -3.5), Vector2(6.5, 4.5), 2.1],
	[Vector3(-10.5, 7.8, 2.0), Color(1.0, 0.9, 0.74), Vector3(-7.0, 0.6, -8.5), Vector3(0.5, 0.4, -4.0), Vector2(7.5, 4.0), 4.0],
	[Vector3(10.5, 7.8, 2.0), Color(1.0, 0.9, 0.74), Vector3(7.0, 0.6, -8.5), Vector3(-0.5, 0.4, -4.0), Vector2(7.5, 4.0), 5.3],
]

var beams: Array = []


func _build_beams() -> void:
	var fnl := FastNoiseLite.new()
	fnl.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	fnl.frequency = 0.012
	fnl.fractal_octaves = 3
	var noise := NoiseTexture2D.new()
	noise.width = 256
	noise.height = 256
	noise.seamless = true
	noise.noise = fnl
	var cone := CylinderMesh.new()
	cone.top_radius = 0.05
	cone.bottom_radius = BEAM_LENGTH * tan(deg_to_rad(BEAM_HALF_ANGLE))
	cone.height = BEAM_LENGTH
	cone.radial_segments = 32
	cone.rings = 4
	cone.cap_top = false
	cone.cap_bottom = false
	var shader := Shader.new()
	shader.code = BEAM_SHADER
	for rig in BEAM_RIGS:
		var pivot := Node3D.new()
		pivot.name = "ShowBeam"
		add_child(pivot)
		var light := SpotLight3D.new()
		light.light_color = rig[1]
		light.light_energy = 7.0
		light.spot_angle = BEAM_HALF_ANGLE + 0.5
		light.spot_angle_attenuation = 0.35
		light.spot_range = 26.0
		light.spot_attenuation = 0.3
		light.shadow_enabled = false
		pivot.add_child(light)
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("beam_color", rig[1])
		material.set_shader_parameter("beam_length", BEAM_LENGTH)
		material.set_shader_parameter("haze_noise", noise)
		var beam := MeshInstance3D.new()
		beam.mesh = cone
		beam.material_override = material
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Apex at the fixture, cone opening along the pivot's -Z.
		beam.rotation.x = PI / 2.0
		beam.position = Vector3(0, 0, -BEAM_LENGTH / 2.0)
		pivot.add_child(beam)
		beams.append(pivot)
	_animate_beams(0.0, false)


static func beam_target(rig: Array, t: float, sweeping: bool, focus: Vector3) -> Vector3:
	if not sweeping:
		return rig[2]
	var centre: Vector3 = rig[3]
	var reach: Vector2 = rig[4]
	var phase: float = rig[5]
	var roam := centre + Vector3(
		sin(t * 0.47 + phase) * reach.x + sin(t * 1.13 + phase * 1.7) * 0.6,
		0.0,
		cos(t * 0.31 + phase * 0.8) * reach.y)
	# Every so often all fixtures converge on the fighter, then fan out again.
	var gather := smoothstep(0.55, 0.95, sin(t * 0.16 + 1.2))
	return roam.lerp(focus, gather)


func _animate_beams(t: float, sweeping: bool, focus_at = null, count: int = BEAM_RIGS.size()) -> void:
	var focus: Vector3 = focus_at if focus_at != null else \
		(Vector3(hero.position.x, 1.0, hero.position.z) if hero != null else Vector3(0, 1, 0))
	for i in beams.size():
		var pivot := beams[i] as Node3D
		pivot.visible = i < count
		if not pivot.visible:
			continue
		var rig: Array = BEAM_RIGS[i]
		var source: Vector3 = rig[0]
		var dir := beam_target(rig, t, sweeping, focus) - source
		var up := Vector3.BACK if absf(dir.normalized().y) > 0.99 else Vector3.UP
		pivot.look_at_from_position(source, source + dir, up)


func _mist_system(extents: Vector3, at: Vector3, rate: float, life: float, size: float, alpha: float, tint: Color, drift: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(4, int(rate * life))
	p.lifetime = life
	p.preprocess = life
	p.position = at
	p.visibility_aabb = AABB(-extents - Vector3.ONE * size, (extents + Vector3.ONE * size) * 2.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents / 2.0
	pm.direction = drift.normalized()
	pm.spread = 25.0
	pm.initial_velocity_min = 0.1
	pm.initial_velocity_max = 0.4
	pm.gravity = Vector3.ZERO
	pm.angular_velocity_min = -6.0
	pm.angular_velocity_max = 10.0
	pm.lifetime_randomness = 0.3
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	var sc := Curve.new()
	sc.add_point(Vector2(0, 0.8))
	sc.add_point(Vector2(0.5, 1.0))
	sc.add_point(Vector2(1, 1.35))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
	g.colors = PackedColorArray([Color(tint, 0), Color(tint, alpha), Color(tint, alpha), Color(tint, 0)])
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = _puff
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	quad.material = m
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _build_mist() -> void:
	mist = Node3D.new()
	mist.name = "Mist"
	mist.add_child(_mist_system(Vector3(20, 0.5, 16), Vector3(0, 0.45, -1.5), 3.2, 16.0, 4.2, 0.025,
		Color(0.62, 0.7, 0.82), Vector3(1, 0, 0.25)))
	mist.add_child(_mist_system(Vector3(24, 4, 8), Vector3(0, 3.6, -7), 2.4, 20.0, 7.0, 0.025,
		Color(0.5, 0.62, 0.82), Vector3(-1, 0.05, 0.1)))
	stage.add_child(mist)


func _set_mist_paused(paused: bool) -> void:
	for p in mist.get_children():
		(p as GPUParticles3D).speed_scale = 0.0 if paused else 1.0


# MARK: - Scene states

func reset_for_next_bout(asset: String, reduced: bool = true) -> void:
	if asset != "" and rival.rig.name != asset:
		rival.queue_free()
		stage.remove_child(rival)
		rival = Boxer.new()
		rival.setup(asset, true)
		stage.add_child(rival)
		choreographer.replace_rival(rival)
	_clear_effects()
	title_screen = false
	career_victory = false
	rival.visible = true
	hero.rotation.y = PI - 0.16
	layout(portrait)
	shake = 0.0
	_camera_follow = Vector3.ZERO
	excitement = 0.15
	_last_crowd_time = null
	_animate_crowd(0.0, true)
	choreographer.reset()
	choreographer.rest_pose()
	_animate_beams(0.0, not reduced, _beam_focus(), FIGHT_BEAM_COUNT)


func _beam_focus() -> Vector3:
	return Vector3(choreographer.ring_center.x, 1.0, choreographer.ring_center.z)


func _clear_effects() -> void:
	for e in _effects:
		(e.node as Node).queue_free()
	_effects.clear()


func _look(pos: Vector3, target: Vector3) -> void:
	camera.look_at_from_position(pos, target)


func layout(p_portrait: bool) -> void:
	portrait = p_portrait
	if camera == null:
		return
	camera.fov = 43.0 if portrait else 38.0
	if career_victory:
		hero.position = Vector3(0, 0, 0.5) if portrait else Vector3(-1.9, 0, 0.5)
		_look(Vector3(0, 2.5, 8.4) if portrait else Vector3(0, 2.7, 7.5), Vector3(0, 0.6 if portrait else 1.55, 0))
		return
	if title_screen:
		_look(Vector3(0, 2.9, 8.8) if portrait else Vector3(0, 2.7, 7.5), Vector3(0, 1.55, 0))
		return
	_look(Vector3(0, 2.95, 7.9) if portrait else Vector3(0, 2.55, 4.8), Vector3(0, 1.5 if portrait else 2.1, 0))


func set_title_screen() -> void:
	title_screen = true
	career_victory = false
	_clear_effects()
	layout(portrait)


func render_title(time: float, reduced: bool) -> void:
	if not title_screen:
		return
	_set_mist_paused(reduced)
	rival.visible = false
	hero.pose_title(time, reduced)
	hero.position = Vector3(0, 0, 0.85 if portrait else 0.55)
	hero.rotation = Vector3(0, PI / 9.0, 0)
	_animate_crowd(time, reduced)
	_animate_beams(time, not reduced)


func begin_career_victory(reduced: bool) -> void:
	career_victory = true
	title_screen = false
	rival.visible = false
	_clear_effects()
	hero.reset_motion()
	hero.rotation = Vector3(0, PI / 9.0, 0)
	layout(portrait)
	excitement = 1.0
	_last_crowd_time = null
	for person in spectators:
		person.erupt()
	render_career_victory(0.0, reduced)


func render_career_victory(time: float, reduced: bool) -> void:
	if not career_victory:
		return
	_set_mist_paused(reduced)
	hero.pose_victory(time, reduced)
	_animate_crowd(time, reduced)
	_animate_beams(time, not reduced)


## Render one frame of a bout. `frame_delta` advances the presentation clock.
func render(fight: FightEngine, reduced: bool, frame_delta: float, tick_fraction: float = 0.0) -> void:
	_set_mist_paused(reduced)
	var dt := clampf(frame_delta, 0.0, 0.1)
	shake *= pow(0.86, dt * 60.0)
	var cues := choreographer.update(fight, dt, clampf(tick_fraction, 0.0, 1.0), reduced)
	var now := choreographer.clock
	_update_effects(now)
	if not reduced:
		for cue in cues:
			var pos: Vector3 = cue.position
			match cue.kind:
				"impact":
					shake = maxf(shake, 0.085 if cue.counter else 0.045)
					_impact(pos, cue.strong)
					if cue.strong or cue.counter:
						excitement = minf(1.0, excitement + (0.2 if cue.counter else 0.12))
				"knockdown":
					shake = maxf(shake, 0.07)
					excitement = 1.0
					for person in spectators:
						person.erupt()
				"dodge", "parry":
					_trail(pos)
	_update_camera(now, dt, reduced)
	_animate_crowd(now, reduced)
	_animate_beams(now * FIGHT_BEAM_SPEED, not reduced, _beam_focus(), FIGHT_BEAM_COUNT)


func _update_camera(t: float, elapsed: float, reduced: bool) -> void:
	if reduced:
		_camera_follow = Vector3.ZERO
		layout(portrait)
		return
	var blend := 1.0 - exp(-elapsed * 2.4)
	_camera_follow += (choreographer.ring_center - _camera_follow) * blend
	var settle := minf(t / 2.0, 1.0)
	var drift := sin(t * 0.23) * 0.09 + sin(t * 0.53) * 0.025
	var pos := Vector3(
		_camera_follow.x * 0.55 + drift * settle + sin(t * 91.0) * shake,
		(2.95 if portrait else 2.55) + sin(t * 0.31) * 0.035 * settle + cos(t * 77.0) * shake * 0.5,
		(7.9 if portrait else 4.8) + sin(t * 0.19) * 0.10 * settle)
	camera.fov = 43.0 if portrait else 38.0
	_look(pos, Vector3(_camera_follow.x * 0.8, (1.5 if portrait else 2.1) + sin(t * 0.27) * 0.015 * settle, _camera_follow.z * 0.5))


func _animate_crowd(t: float, reduced: bool) -> void:
	var dt := 0.0
	if _last_crowd_time != null and t >= _last_crowd_time:
		dt = minf(0.25, t - _last_crowd_time)
	_last_crowd_time = t
	excitement = maxf(0.15, excitement - dt * 0.05)
	for person in spectators:
		person.player.speed_scale = 0.0 if reduced else 1.0
		if not reduced:
			person.tick(dt, excitement)
	for f in flash_nodes:
		f.visible = false
	if reduced or flash_nodes.is_empty():
		return
	var window := int(t / 4.0)
	var hash := window + SeededRNG.DEFAULT_SEED
	hash = (hash ^ SeededRNG.lsr(hash, 30)) * -4658895280553007687
	hash = (hash ^ SeededRNG.lsr(hash, 27)) * -7723592293110705685
	hash ^= SeededRNG.lsr(hash, 31)
	var onset := float(SeededRNG.umod(hash, 1600)) / 1000.0 + 0.4
	var age := t - float(window) * 4.0 - onset
	if age >= 0.0 and age < 0.10:
		var flash: MeshInstance3D = flash_nodes[SeededRNG.umod(SeededRNG.lsr(hash, 8), flash_nodes.size())]
		flash.visible = true
		var m: StandardMaterial3D = flash.material_override
		m.albedo_color.a = (1.0 - age / 0.10) * 0.85


# MARK: - Effects

func _impact(pos: Vector3, strong: bool) -> void:
	var p := CPUParticles3D.new()
	p.amount = 18 if strong else 11
	p.one_shot = true
	p.explosiveness = 1.0
	p.lifetime = 0.22
	p.lifetime_randomness = 0.45
	p.direction = Vector3(0, 0, 1)
	p.spread = 180.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 5.1
	p.gravity = Vector3.ZERO
	var s := SphereMesh.new()
	s.radius = 0.0125
	s.height = 0.025
	s.radial_segments = 6
	s.rings = 3
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0 * 3.0, 0.76 * 3.0, 0.24 * 3.0)
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	s.material = m
	p.mesh = s
	p.position = pos
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stage.add_child(p)
	p.emitting = true
	_effects.append({"node": p, "start": choreographer.clock, "expires": choreographer.clock + 0.7, "kind": "impact"})


func _trail(pos: Vector3) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 1)
	var streak := _torus(0.62, 0.015, pos, m)
	streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	streak.scale = Vector3(1.3, 0.35, 1)
	_effects.append({"node": streak, "start": choreographer.clock, "expires": choreographer.clock + 0.24, "kind": "trail"})


func _update_effects(now: float) -> void:
	var keep := []
	for e in _effects:
		if e.expires <= now:
			(e.node as Node).queue_free()
			continue
		if e.kind == "trail":
			var u := clampf((now - e.start) / 0.22, 0.0, 1.0)
			var node: MeshInstance3D = e.node
			node.scale = Vector3(1.3, 0.35, 1).lerp(Vector3.ONE * 1.9, u)
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - u
		keep.append(e)
	_effects = keep
